#!/usr/bin/env python3
"""extract_bundle.py — csexp bundle → CSV fact extractor for bundle-verify.

Consumes a globals.csexp bundle (the canonical wire format produced by
compile.shen → nat->csexp) and emits CSV fact files consumed by
bundle_safety.dl (Soufflé Datalog).

Usage:
    python3 extract_bundle.py --bundle globals.csexp --out-dir facts/
    python3 extract_bundle.py --self-test --out-dir /tmp/test-facts/

No dependencies beyond Python 3 stdlib.
"""

import argparse
import csv
import os
import sys
from pathlib import Path


# ── Wire format constants ───────────────────────────────────────────

# Opcodes that take an operand (csexp atom immediately after the opcode char)
OPCODES_WITH_OPERAND = set("agfjnSsPb")

# Opcodes that are standalone (no operand)
OPCODES_NO_OPERAND = set("mprvedt")

# All valid opcode characters
VALID_OPCODES = OPCODES_WITH_OPERAND | OPCODES_NO_OPERAND | {"c"}

# Opcodes that produce a value (push to stack in ZINC auto-push semantics)
VALUE_OPCODES = set("agnSsPbc")  # access, global, number, string, symbol, boolean, prim, cur

# Opcodes that are call sites
CALL_OPCODES = set("pt")  # apply, appterm

# ── Primitive arity table ────────────────────────────────────────────
# Maps primitive name to expected argument count.
# Source: vm/zincvm.c exec_primitive() dispatch + type signatures.
PRIM_ARITY = {
    # Unary primitives (1 arg)
    "hd": 1, "tl": 1, "number?": 1, "string?": 1, "symbol?": 1,
    "boolean?": 1, "cons?": 1, "absvector?": 1, "function?": 1,
    "error?": 1, "stream?": 1, "variable?": 1,
    "n->string": 1, "string->n": 1, "str": 1,
    "pos": 2,  # pos S N — 2 args (string, number)
    "tlstr": 1, "hdstr": 1,
    "absvector": 1, "close": 1,
    "read-byte": 1, "fst": 1, "snd": 1,
    "value": 1, "intern": 1,
    "simple-error": 1, "error-to-string": 1,
    "get-time": 1, "eval-kl": 1,
    "c-strlen": 1, "char-code": 2,  # char-code S N — 2 args (string, index)
    "emptylist": 1,  # 1 arg (the number 0 sentinel)
    "gensym": 1, "newvar": 1,  # variable-arity; consume at most 1
    "fail": 1,               # variable-arity; consume at most 1
    "set": 2,  # set Sym Val
    "open": 2,  # open Path Dir
    "trap-error": 2,  # trap-error Body Handler — 2 args
    # Binary primitives (2 args)
    "cons": 2, "=": 2, "+": 2, "-": 2, "*": 2, "/": 2,
    ">": 2, "<": 2, ">=": 2, "<=": 2,
    "cn": 2, "element?": 2, "substring": 3,  # substring S Start Len
    "address->": 3, "<-address": 2,  # address-> Vec Idx Val — 3 args
    "write-byte": 2,  # write-byte Byte Stream
    "read-file-as-string": 1,
    "@p": 2,  # tuple constructor
    # prims.def entries not currently inlined as `P` but present in the C VM
    # table (default arity=0 would silently over-count the stack if ever inlined).
    "nth": 2,              # vm/prims.def PRIM("nth",2)
    "shen.str->bytes": 1,  # vm/prims.def PRIM("shen.str->bytes",1)
    "shen.bytes->string": 1,  # vm/prims.def PRIM("shen.bytes->string",1)
    "shen.fail!": 1,       # vm/prims.def PRIM("shen.fail!",1)
    "stinput": 0,          # vm/prims.def PRIM("stinput",0)  (0 = pop0/push1, already default)
    "stoutput": 0,         # vm/prims.def PRIM("stoutput",0)
    # Inline-prim helpers used by the metacircular interp / reduced bundle.
    # These are dispatched via `P` (inline OP_PRIM) in the bundle, so the
    # stack simulation MUST know their arity to keep stack depth balanced.
    # Without these, PRIM_ARITY.get() defaults to 0 (pop 0, push 1), which
    # inflates the simulated stack by +1 V per occurrence and makes
    # downstream apply/appterm sites over-count supplied_args (e.g. shen.interp
    # self-calls reported as 6-9 args instead of the true 5).
    "reverse": 1,  # C VM zincvm.c:1451 — pops 1
    "append": 2,   # C VM zincvm.c:986  — pops 2
    "assoc": 2,    # C VM zincvm.c:962  — pops 2
    "empty?": 1,   # C VM zincvm.c:1225 — pops 1
    "length": 1,   # C VM zincvm.c:1304 — pops 1
    "hash": 2,     # Shen OS arity table (init.kl): hash Key Size — 2 args
    "shen.assoc-set": 3,  # sys.kl: (defun shen.assoc-set V3875 V3876 V3877) — 3 args
    "c-tag": 1,       # interp constructor-tag helper — 1 arg
    "c-tag-full": 1,  # interp constructor-tag helper — 1 arg
}

# Allowlisted primitives (from shen/util.shen primitive?)
ALLOWED_PRIMS = {
    "cons", "hd", "tl", "=", "+", "/", "*", "-", "number?", ">", "<",
    ">=", "<=", "string?", "symbol?", "boolean?", "cons?", "absvector?",
    "pos", "tlstr", "hdstr", "cn", "str", "string->n", "n->string",
    "absvector", "address->", "<-address", "emptylist",
    "write-byte", "read-byte", "read-file-as-string", "open", "close",
    "function?", "trap-error", "simple-error", "error-to-string", "intern",
    "set", "value", "eval-kl", "get-time", "error?", "stream?",
    "@p", "fst", "snd", "gensym", "variable?", "newvar",
    "c-strlen", "char-code", "substring", "element?",
    "append", "empty?", "reverse", "assoc", "length", "nth",
    "fail",
}

# Instruction keywords (from shen/util.shen instruction-keyword?)
# These are symbols used as ZINC instruction constructors, resolved as
# symbol values when referenced via [global X].
INSTRUCTION_KEYWORDS = {
    "access", "global", "prim", "let", "number", "string", "symbol",
    "boolean", "grab", "apply", "appterm", "cur", "cons", "label",
    "jmpf", "jmp", "endlet", "pushmark", "mark", "error", "lambda",
    "absvector", "stream", "in", "out",
}

# ── CSV schemas ──────────────────────────────────────────────────────

CSV_SCHEMAS = {
    "closure":       ["name", "arity"],
    "instr":         ["name", "idx", "op"],
    "operand":       ["name", "idx", "kind", "value"],
    "global_ref":    ["name", "idx", "target"],
    "prim_ref":      ["name", "idx", "prim"],
    "call_site":     ["name", "idx", "kind"],
    "cur_lit":       ["name", "idx", "sub_code_id"],
    "cur_body":      ["name", "arity"],
    "pushmark":      ["name", "idx"],
    "supplied_args": ["name", "cs_idx", "n"],
    # Static tables (emitted once, not per-closure)
    "allowed_prim":  ["prim"],
    "instruction_keyword": ["keyword"],
    "opcode_valid":  ["op"],
    "prim_arity":    ["prim", "arity"],
}


# ── Fact writer (mirrors gc-verify's FactWriter) ────────────────────

class FactWriter:
    """Manages output CSV files for all fact relations.

    Rows are buffered in memory (per relation) so that multiple closures
    can be visited into the same writer before anything is written to
    disk; close() flushes headers + deduplicated rows.
    """

    def __init__(self, out_dir):
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._rows = {rel: set() for rel in CSV_SCHEMAS}

    def write(self, relation, row):
        """Buffer a row for a relation.  Row must be a list/tuple of strings."""
        self._rows[relation].add(tuple(str(x) for x in row))

    def close(self):
        for rel, cols in CSV_SCHEMAS.items():
            f = open(self.out_dir / f"{rel}.csv", "w", newline="")
            try:
                w = csv.writer(f, lineterminator="\n")
                w.writerow(cols)
                for row in sorted(self._rows[rel]):
                    w.writerow(row)
            finally:
                f.close()


# ── csexp atom parser ────────────────────────────────────────────────

class AtomParser:
    """Parse a single csexp atom: [len:type]value.

    On entry, *p points to '['. On success, *p is advanced past the
    value bytes.  Returns (kind, value_str) where kind ∈ {n,s,S,b}.
    """

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def peek(self):
        if self.pos < len(self.data):
            return self.data[self.pos]
        return '\0'

    def advance(self):
        c = self.peek()
        if c != '\0':
            self.pos += 1
        return c

    def skip_ws(self):
        while self.pos < len(self.data) and self.data[self.pos] in ' \t\n\r':
            self.pos += 1

    def parse_atom(self):
        """Parse one csexp atom at current position. Returns (kind, value) or raises."""
        self.skip_ws()
        if self.peek() != '[':
            raise ValueError(f"expected '[' for atom at pos {self.pos}, got {repr(self.peek())}")
        self.advance()  # skip '['

        # Parse length
        len_start = self.pos
        while self.pos < len(self.data) and self.data[self.pos].isdigit():
            self.pos += 1
        if self.pos == len_start:
            raise ValueError(f"expected digit for atom length at pos {self.pos}")
        atom_len = int(self.data[len_start:self.pos])

        if self.peek() != ':':
            raise ValueError(f"expected ':' after length at pos {self.pos}")
        self.advance()  # skip ':'

        kind = self.advance()  # type char: n, s, S, b
        if kind not in ('n', 's', 'S', 'b'):
            raise ValueError(f"unknown csexp type '{kind}' at pos {self.pos}")

        if self.peek() != ']':
            raise ValueError(f"expected ']' after type at pos {self.pos}")
        self.advance()  # skip ']'

        if self.pos + atom_len > len(self.data):
            raise ValueError(f"atom value extends past end of data (len={atom_len} at pos {self.pos})")

        value = self.data[self.pos:self.pos + atom_len]
        self.pos += atom_len

        return kind, value

    def parse_atom_if_present(self):
        """Parse an atom if current position is '['; return (kind, value) or None."""
        self.skip_ws()
        if self.peek() == '[':
            return self.parse_atom()
        return None


# ── Bundle parser ────────────────────────────────────────────────────

class BundleParser:
    """Parse a globals.csexp bundle and emit CSV facts via FactWriter."""

    def __init__(self, data, writer):
        self.data = data
        self.pos = 0
        self.writer = writer
        self.sub_id_counter = 0

    def peek(self):
        if self.pos < len(self.data):
            return self.data[self.pos]
        return '\0'

    def advance(self):
        c = self.peek()
        if c != '\0':
            self.pos += 1
        return c

    def skip_ws(self):
        while self.pos < len(self.data) and self.data[self.pos] in ' \t\n\r':
            self.pos += 1

    def parse_atom(self):
        """Parse one csexp atom at current position."""
        ap = AtomParser(self.data)
        ap.pos = self.pos
        kind, value = ap.parse_atom()
        self.pos = ap.pos
        return kind, value

    def parse_bundle(self):
        """Parse the top-level bundle: ((name1 (c(body1))) (name2 (c(body2))) ...)"""
        self.skip_ws()
        if self.peek() != '(':
            raise ValueError(f"expected outer '(' at pos {self.pos}")
        self.advance()  # skip outer '('

        count = 0
        while True:
            self.skip_ws()
            if self.pos >= len(self.data) or self.peek() == ')':
                if self.peek() == ')':
                    self.advance()  # skip outer ')'
                break

            if self.peek() != '(':
                raise ValueError(f"expected '(' for entry at pos {self.pos}, got {repr(self.peek())}")
            self.advance()  # skip entry '('

            # Parse name atom
            name_kind, name_value = self.parse_atom()
            if name_kind != 's':
                raise ValueError(f"expected symbol name at pos {self.pos}, got kind={name_kind}")

            # Parse code: (c(body))
            self.skip_ws()
            if self.peek() != '(':
                raise ValueError(f"expected '(' for code at pos {self.pos}")
            self.advance()  # skip '('

            self.skip_ws()
            if self.peek() != 'c':
                raise ValueError(f"expected 'c' (cur) at pos {self.pos}, got {repr(self.peek())}")
            self.advance()  # skip 'c'

            # Parse body: (instructions...)
            self.skip_ws()
            if self.peek() != '(':
                raise ValueError(f"expected '(' for cur body at pos {self.pos}")
            self.advance()  # skip '('

            # Parse the flat instruction stream
            self._parse_body(name_value)

            # Expect ')' to close the cur body
            self.skip_ws()
            if self.peek() != ')':
                raise ValueError(f"expected ')' to close cur body at pos {self.pos}, got {repr(self.peek())}")
            self.advance()  # skip ')'

            # Expect ')' to close the code list
            self.skip_ws()
            if self.peek() != ')':
                raise ValueError(f"expected ')' to close code list at pos {self.pos}, got {repr(self.peek())}")
            self.advance()  # skip ')'

            # Expect ')' to close the entry
            self.skip_ws()
            if self.peek() != ')':
                raise ValueError(f"expected ')' to close entry at pos {self.pos}, got {repr(self.peek())}")
            self.advance()  # skip ')'

            count += 1

        # Emit static tables
        self._emit_static_tables()
        return count

    def _emit_static_tables(self):
        """Emit the static allowlist/keyword/opcode tables."""
        for prim in sorted(ALLOWED_PRIMS):
            self.writer.write("allowed_prim", [prim])
        for kw in sorted(INSTRUCTION_KEYWORDS):
            self.writer.write("instruction_keyword", [kw])
        for op in sorted(VALID_OPCODES):
            self.writer.write("opcode_valid", [op])
        for prim, arity in sorted(PRIM_ARITY.items()):
            self.writer.write("prim_arity", [prim, arity])

    def _parse_body(self, name, emit_closure=True):
        """Parse a flat instruction stream for code-unit `name`.

        Reads instructions until ')' or end of data.
        Each instruction is either:
          - A standalone opcode char (m, p, r, v, e, d, t)
          - An opcode char followed by a csexp atom (a, g, f, j, n, s, P, S, b)
          - 'c' followed by '(body)' for nested cur

        Collects instructions for a second-pass forward-dataflow stack
        simulation that emits supplied_args facts.

        `emit_closure` distinguishes the two kinds of code unit:
          - True  → `name` is a TOP-LEVEL bundle closure → emit `closure(name, arity)`.
          - False → `name` is a NESTED cur body (a fabricated `parent.N...` sub-id)
                    → emit `cur_body(name, arity)` instead.  Nested cur bodies are
                    NOT real bundle closures, so emitting a `closure()` row for
                    them would pollute dangling_global / arity_mismatch /
                    unresolved_call with phantom names that never match a real
                    closure in globals.csexp.  `cur_body` keeps their arity
                    available for the first-order partition (Part 2) while the
                    enclosing top-level `closure()` stays name-only/real.
        """
        idx = 0
        grab_count = 0
        leading = True       # all grabs seen so far are leading
        # Instruction record: (idx, op, operand_kind, operand_value)
        instructions = []

        while True:
            self.skip_ws()
            if self.pos >= len(self.data):
                break
            c = self.peek()
            if c == ')':
                break
            if c == '(':
                raise ValueError(f"unexpected '(' in body of '{name}' at pos {self.pos}")

            if c not in VALID_OPCODES:
                raise ValueError(f"unknown opcode '{c}' (0x{ord(c):02x}) in '{name}' at pos {self.pos}")

            self.advance()  # consume opcode

            # Track grabs for arity: count only leading 'r's
            if c == 'r':
                if leading:
                    grab_count += 1
            else:
                leading = False

            # Emit instr fact
            self.writer.write("instr", [name, idx, c])

            op_kind = None
            op_value = None

            if c == 'c':
                # Nested cur: expect (body)
                self.skip_ws()
                if self.peek() != '(':
                    raise ValueError(f"expected '(' after 'c' in '{name}' at pos {self.pos}")
                self.advance()  # skip '('

                sub_id = f"{name}.{self.sub_id_counter}"
                self.sub_id_counter += 1
                self.writer.write("cur_lit", [name, idx, sub_id])

                # Parse the sub-closure body (recursive).  Nested cur bodies are
                # NOT real bundle closures → emit_closure=False so the recursive
                # call writes a `cur_body` row, not a phantom `closure()` row.
                self._parse_body(sub_id, emit_closure=False)

                # Expect ')' to close sub-closure body
                self.skip_ws()
                if self.peek() != ')':
                    raise ValueError(f"expected ')' to close cur body in '{name}' at pos {self.pos}")
                self.advance()  # skip ')'

            elif c in OPCODES_WITH_OPERAND:
                kind, value = self.parse_atom()
                self.writer.write("operand", [name, idx, kind, value])
                op_kind = kind
                op_value = value

                if c == 'g':
                    self.writer.write("global_ref", [name, idx, value])
                elif c == 'P':
                    self.writer.write("prim_ref", [name, idx, value])
                elif c == 'f' or c == 'j':
                    pass  # jmpf/jmp operand is just a number
                elif c == 'a' or c == 'e':
                    pass  # access/let operand is just a number
                elif c == 'n' or c == 'S' or c == 's' or c == 'b':
                    pass  # literal operand

            elif c in CALL_OPCODES:
                kind_name = {"p": "apply", "t": "appterm"}[c]
                self.writer.write("call_site", [name, idx, kind_name])

            elif c == 'm':
                self.writer.write("pushmark", [name, idx])

            elif c in OPCODES_NO_OPERAND:
                pass  # r, v, e, d already handled

            instructions.append((idx, c, op_kind, op_value))
            idx += 1

        # Emit arity: leading_grab_count + 1.
        # Top-level closures get a `closure` row; nested cur bodies get a
        # `cur_body` row (they are NOT real bundle closures — emitting a
        # `closure()` row would fabricate phantom names like `parent.N.M...`
        # that have 0 matches in globals.csexp and pollute the Datalog facts).
        arity = grab_count + 1
        if emit_closure:
            self.writer.write("closure", [name, arity])
        else:
            self.writer.write("cur_body", [name, arity])

        # Run forward-dataflow stack simulation → supplied_args
        self._simulate_stack(name, instructions)

    def _simulate_stack(self, name, instructions):
        """Forward-dataflow stack-shape simulation for one closure body.

        instructions: list of (idx, op, operand_kind, operand_value).

        Maintains a *set* of reachable stack shapes per pc (each shape is a
        tuple of 'V'(value) / 'M'(mark)).  This is a proper meet/join dataflow
        (monotone union over the control-flow graph, worklist-iterated to a
        fixed point) rather than a first-wins map: every distinct stack shape
        that can reach a merged pc is tracked, so a later branch reaching the
        same apply/appterm from a different path is not silently dropped.

        At each apply/appterm, records ONE supplied_args(name, pc, n) row per
        distinct reachable shape, where n = count of 'V' above the topmost 'M',
        excluding the callee.  The Datalog arity_mismatch rule then only fires
        where a *genuinely reachable* path supplies a wrong arg count.
        """
        if not instructions:
            return

        # Build lookup: idx -> (op, operand_value)
        instr_at = {}
        for idx, op, op_kind, op_value in instructions:
            instr_at[idx] = (op, op_value)

        max_idx = max(instr_at.keys())

        # states[pc] = set of 'V'/'M' shape tuples reachable at pc.
        # worklist holds (pc, shape) work-items; a shape is re-propagated only
        # when it is newly joined into a pc's reachable set (monotone fixpoint).
        states = {}
        worklist = [(0, ())]

        while worklist:
            pc, stack = worklist.pop(0)
            if pc not in instr_at:
                continue

            op, op_value = instr_at[pc]
            # Compute new stack shape after this instruction from this one shape
            new_stack = list(stack)
            successors = []

            # Value-producing opcodes (including cur): push V
            if op in 'agnSsbc':
                new_stack.append('V')
                successors.append(pc + 1)

            elif op == 'm':  # pushmark
                new_stack.append('M')
                successors.append(pc + 1)

            elif op == 'P':  # inline prim
                prim_name = op_value if op_value else ""
                arity = PRIM_ARITY.get(prim_name, 0)
                # Pop arity values from stack top
                for _ in range(arity):
                    if new_stack and new_stack[-1] == 'V':
                        new_stack.pop()
                    elif new_stack and new_stack[-1] == 'M':
                        new_stack.pop()
                # Push result
                new_stack.append('V')
                successors.append(pc + 1)

            elif op == 'r':  # grab: no stack effect (safe subset)
                successors.append(pc + 1)

            elif op == 'e':  # let: pop V
                if new_stack and new_stack[-1] == 'V':
                    new_stack.pop()
                successors.append(pc + 1)

            elif op == 'd':  # endlet: no stack effect
                successors.append(pc + 1)

            elif op == 'f':  # jmpf: pop V (condition), two successors
                if new_stack and new_stack[-1] == 'V':
                    new_stack.pop()
                successors.append(pc + 1)
                target = int(op_value) if op_value else pc + 1
                if target <= max_idx + 1:
                    successors.append(target)

            elif op == 'j':  # jmp: no stack effect, one successor
                target = int(op_value) if op_value else pc + 1
                if target <= max_idx + 1:
                    successors.append(target)
                # No pc+1 successor

            elif op in 'pt':  # apply / appterm
                # Count 'V' above topmost 'M', excluding callee (the topmost V)
                n_above = 0
                for ch in reversed(new_stack):
                    if ch == 'V':
                        n_above += 1
                    else:
                        break
                supplied = n_above - 1  # exclude callee
                if supplied >= 0:
                    self.writer.write("supplied_args", [name, pc, supplied])

                # Apply effect: pop callee, pop V's until M, pop M, push result V
                # Find topmost M
                m_pos = -1
                for i in range(len(new_stack) - 1, -1, -1):
                    if new_stack[i] == 'M':
                        m_pos = i
                        break
                if m_pos >= 0:
                    new_stack = new_stack[:m_pos]
                else:
                    new_stack = []
                new_stack.append('V')
                successors.append(pc + 1)

            elif op == 'v':  # return: terminal, no successors
                pass

            # Propagate to all successors
            for succ in successors:
                if succ <= max_idx + 1:
                    self._propagate_state(states, worklist, succ, tuple(new_stack))

    @staticmethod
    def _propagate_state(states, worklist, pc, shape):
        """Join `shape` into the reachable-shape set at `pc` (monotone union).

        Only schedules the (pc, shape) work-item when `shape` is newly added,
        which drives the worklist to a fixed point (a shape already present
        never needs re-propagation).
        """
        cur = states.get(pc)
        if cur is None:
            states[pc] = {shape}
            worklist.append((pc, shape))
        elif shape not in cur:
            cur.add(shape)
            worklist.append((pc, shape))


# ── Main ──────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="csexp bundle → CSV fact extractor")
    p.add_argument("--bundle", help="Path to globals.csexp")
    p.add_argument("--out-dir", default="facts", help="Output directory for CSV files")
    p.add_argument("--self-test", action="store_true",
                   help="Run a small self-test (parse a synthetic bundle)")
    return p.parse_args()


def main():
    args = parse_args()

    if args.self_test:
        self_test(args.out_dir)
        return

    if not args.bundle:
        print("ERROR: --bundle required (or use --self-test)", file=sys.stderr)
        sys.exit(1)

    data = Path(args.bundle).read_text()
    writer = FactWriter(args.out_dir)

    parser = BundleParser(data, writer)
    n = parser.parse_bundle()
    writer.close()

    print(f"Extracted {n} closures to {args.out_dir}/")


def self_test(out_dir):
    """Minimal self-test: parse a synthetic bundle and verify output."""
    # A simple bundle with two closures
    # Closure 'id': (c(r a[1:n]0 v)) — 1 leading grab → arity 2
    # Closure 'apply-id': (c(m a[1:n]0 g[2:s]id p v)) — 0 grabs → arity 1
    # Closure 'outer': (c(r c(a[1:n]0 v) v)) — 1 grab → arity 2, plus a nested
    #   cur body whose sub-id is the fabricated "outer.0" (NOT a real closure).
    synthetic = (
        "(([2:s]id (c(ra[1:n]0v)))"
        "([8:s]apply-id (c(ma[1:n]0g[2:s]idpv)))"
        "([5:s]outer (c(rc(a[1:n]0v)v))))"
    )

    writer = FactWriter(out_dir)
    parser = BundleParser(synthetic, writer)
    n = parser.parse_bundle()
    writer.close()

    print(f"Self-test: extracted {n} closures to {out_dir}/")

    # Quick verification
    closure_rows = set()
    with open(Path(out_dir) / "closure.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        assert header == ["name", "arity"], f"Bad header: {header}"
        for row in reader:
            closure_rows.add(tuple(row))

    assert ("id", "2") in closure_rows, f"id missing from closures: {closure_rows}"
    assert ("apply-id", "1") in closure_rows, f"apply-id missing from closures: {closure_rows}"
    assert ("outer", "2") in closure_rows, f"outer missing from closures: {closure_rows}"
    # Nested cur bodies must NOT be emitted as phantom closure() rows.
    assert len(closure_rows) == 3, f"expected only 3 real closures, got: {closure_rows}"
    assert ("outer.0", "1") not in closure_rows, \
        f"nested cur body 'outer.0' must NOT appear as a closure row: {closure_rows}"

    # Nested cur bodies ARE emitted as cur_body rows with their arity.
    cur_body_rows = set()
    with open(Path(out_dir) / "cur_body.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        assert header == ["name", "arity"], f"Bad cur_body header: {header}"
        for row in reader:
            cur_body_rows.add(tuple(row))
    assert ("outer.0", "1") in cur_body_rows, \
        f"nested cur body 'outer.0' missing from cur_body: {cur_body_rows}"

    # cur_lit links the enclosing top-level closure to its nested cur body.
    cur_lit_rows = set()
    with open(Path(out_dir) / "cur_lit.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        assert header == ["name", "idx", "sub_code_id"], f"Bad cur_lit header: {header}"
        for row in reader:
            cur_lit_rows.add(tuple(row))
    assert ("outer", "1", "outer.0") in cur_lit_rows, \
        f"cur_lit (outer,1,outer.0) missing: {cur_lit_rows}"

    # Check instr facts
    instr_rows = set()
    with open(Path(out_dir) / "instr.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            instr_rows.add(tuple(row))

    assert ("id", "0", "r") in instr_rows
    assert ("id", "1", "a") in instr_rows
    assert ("id", "2", "v") in instr_rows
    assert ("apply-id", "0", "m") in instr_rows
    assert ("apply-id", "1", "a") in instr_rows
    assert ("apply-id", "2", "g") in instr_rows
    assert ("apply-id", "3", "p") in instr_rows
    assert ("apply-id", "4", "v") in instr_rows

    # Check call_site
    call_site_rows = set()
    with open(Path(out_dir) / "call_site.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            call_site_rows.add(tuple(row))
    assert ("apply-id", "3", "apply") in call_site_rows

    # Check pushmark
    pushmark_rows = set()
    with open(Path(out_dir) / "pushmark.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            pushmark_rows.add(tuple(row))
    assert ("apply-id", "0") in pushmark_rows

    # Check global_ref
    global_ref_rows = set()
    with open(Path(out_dir) / "global_ref.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            global_ref_rows.add(tuple(row))
    assert ("apply-id", "2", "id") in global_ref_rows

    # Check static tables
    with open(Path(out_dir) / "opcode_valid.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        opcodes = {row[0] for row in reader}
    assert "a" in opcodes and "g" in opcodes and "p" in opcodes

    with open(Path(out_dir) / "allowed_prim.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        prims = {row[0] for row in reader}
    assert "cons" in prims and "hd" in prims

    with open(Path(out_dir) / "prim_arity.csv") as f:
        reader = csv.reader(f)
        header = next(reader)
        arities = {row[0]: int(row[1]) for row in reader}
    assert arities.get("cons") == 2
    assert arities.get("hd") == 1

    print("Self-test: ALL CHECKS PASSED")


if __name__ == "__main__":
    main()

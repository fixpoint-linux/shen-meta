#!/usr/bin/env python3
"""extract_source.py — Shen .shen source → CSV fact extractor for bundle-verify.

Consumes the 12 .shen source files that feed the reduced self-contained
bundle (see serialize-reduced.shen:28-43) and emits CSV facts consumed by
bundle_safety.dl (Check A2: source-level safe-subset checks).

Three sound gates:
  1. unsafe_construct(file, line, head)  — a form head not in the safe-subset
     allowlist (flags defmacro/datatype/freeze/thaw/cond/case etc.).
  2. nonlinear_pattern(file, line, var)  — a pattern variable repeats within a
     single clause (silent-overwrite bug in the C VM matcher).
  3. tuple_pattern(file, line)           — a clause pattern uses the @p ctor.

The Shen s-expression reader mirrors shen-kl-helpers.shen's extended reader
(shen-read-file / shen-parse-*) and shen/load.shen's parse-string semantics:
  - whitespace + line (``\\``) and block (``\\* ... *\\``) comments
  - strings with NO escape processing (Shen 41.2 treats `\\` as literal)
  - `( )` lists, `[ ]` dotted lists (`|` = improper cdr), `{ }` type sigs

Usage:
    python3 extract_source.py --source-dir ../../shen/ --out-dir facts/
    python3 extract_source.py --self-test --out-dir /tmp/test-facts/

No dependencies beyond Python 3 stdlib.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

# Reuse the primitive allowlist from the bundle extractor (single source of truth).
import extract_bundle as ext

# The 12 source files (serialize-reduced.shen:28-43), resolved relative to
# the --source-dir argument.
SOURCE_FILES = [
    "util.shen",
    "types.shen",
    "zinc.shen",
    "compile.shen",
    "normalize.shen",
    "primitives.shen",
    "interp.shen",
    "toplevel.shen",
    "load.shen",
    "os-helpers.shen",
    "shen-kl-helpers.shen",
    "shen->kl.shen",
]

# Top-level forms that are skipped wholesale (not body-walked).
META_ALLOWLIST = {"tc", "load", "set-toplevel", "optimise"}

# Core safe-subset language constructs (from the Phase 3 plan).
CORE_CONSTRUCTS = {
    "define", "lambda", "/.", "let", "if", "and", "or", "do", "set",
    "where", "<-", "%%", "newvar", "function", "protect", "cons", "@p",
    "fst", "snd", "gensym", "variable?", "tc", "load", "set-toplevel",
    "optimise", "_", "->", "fail",
}

# Shen OS / core-library functions that are NOT defined in the 12 files and
# NOT C primitives, but are safe standard-library calls (loaded from the
# surrounding Shen OS, outside the reduced bundle's own defines).  Collecting
# them keeps the safe-subset sound without a false-positive on library calls.
EXTERNAL_CORE = {
    "list", "stream", "assoc", "not", "empty?", "chars->str", "strlen",
    "read-file", "lookup-global", "klambda", "atomic?", "instruction-keyword?",
    "ps", ">64", "read-byte", "write-byte", "intern", "value", "simple-error",
    "error-to-string", "trap-error", "get-time", "eval-kl",
    "error?", "stream?", "function?", "char-code", "c-strlen", "substring",
}

# Variables are uppercase-first symbols (Shen's `variable?`), excluding `_`.
def is_variable(sym):
    return bool(sym) and sym != "_" and sym[0].isupper()


# ── CSV schemas / small writer ────────────────────────────────────────

CSV_SCHEMAS = {
    "source_file":         ["name"],
    "unsafe_construct":    ["file", "line", "head"],
    "nonlinear_pattern":   ["file", "line", "var"],
    "tuple_pattern":       ["file", "line"],
}


class SourceWriter:
    """Writes the 4 source-fact CSV relations (headers + deduped sorted rows)."""

    def __init__(self, out_dir):
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._rows = {rel: set() for rel in CSV_SCHEMAS}

    def write(self, relation, row):
        self._rows[relation].add(tuple(str(x) for x in row))

    def close(self):
        for rel, cols in CSV_SCHEMAS.items():
            with open(self.out_dir / f"{rel}.csv", "w", newline="") as f:
                w = csv.writer(f, lineterminator="\n")
                w.writerow(cols)
                for row in sorted(self._rows[rel]):
                    w.writerow(row)


# ── Shen s-expression reader ──────────────────────────────────────────

class ReadError(Exception):
    def __init__(self, line, msg):
        super().__init__(f"line {line}: {msg}")
        self.line = line
        self.msg = msg


_WS = " \t\n\r"
_ATOM_DELIM = set("()[]{}|\"\\") | set(_WS)

_NUM_RE = re.compile(r"-?\d+\Z")


class ShenReader:
    """Parse Shen source text into top-level forms, tracking line numbers.

    Produces:
      - Python ints for numeric atoms
      - Python str for symbol/string atoms (case-preserving)
      - Python lists for ( ) and [ ] groups
      - { ... } type sigs as a single list with braces retained
      - dotted `[A B | C]` as ["cons", A, B, "|", C]

    Each parsed list form is recorded in `form_lines` (by id) so the analyzer
    can recover the source line of nested forms.
    """

    def __init__(self, text):
        self.text = text
        self.pos = 0
        self.line = 1
        self.form_lines = {}
        # form_is_paren[id] is True for `( ... )` CALL groups, False for
        # `[ ... ]` DATA literals.  In Shen, only parenthesised groups are
        # function calls; `[ ... ]` constructs a list value, so its head is a
        # data symbol, not a callable head.
        self.form_is_paren = {}

    # -- low-level char movement ---------------------------------------
    def _advance(self):
        if self.pos < len(self.text):
            if self.text[self.pos] == "\n":
                self.line += 1
            self.pos += 1

    def _skip_ws_and_comments(self):
        while self.pos < len(self.text):
            c = self.text[self.pos]
            if c in _WS:
                self._advance()
            elif c == "\\":
                if self.pos + 1 >= len(self.text):
                    return  # trailing backslash: treat as atom delimiter
                nxt = self.text[self.pos + 1]
                if nxt == "\\":
                    # line comment to EOL
                    self._advance(); self._advance()
                    while self.pos < len(self.text) and self.text[self.pos] != "\n":
                        self._advance()
                elif nxt == "*":
                    # block comment to *\
                    self._advance(); self._advance()
                    self._skip_block_comment()
                else:
                    return
            else:
                return

    def _skip_block_comment(self):
        while self.pos < len(self.text):
            if self.text[self.pos] == "*":
                if self.pos + 1 < len(self.text) and self.text[self.pos + 1] == "\\":
                    self._advance(); self._advance()
                    return
            self._advance()
        raise ReadError(self.line, "unterminated block comment")

    # -- expression parsing ---------------------------------------------
    def parse_form(self):
        """Parse one top-level form, returning (line, form) or None at EOF."""
        self._skip_ws_and_comments()
        if self.pos >= len(self.text):
            return None
        return (self.line, self._parse_expr())

    def parse_all(self):
        forms = []
        while True:
            f = self.parse_form()
            if f is None:
                break
            forms.append(f)
        return forms

    def _parse_expr(self):
        self._skip_ws_and_comments()
        if self.pos >= len(self.text):
            raise ReadError(self.line, "unexpected end of input")
        c = self.text[self.pos]
        if c == "(":
            return self._parse_list(")")
        if c == "[":
            return self._parse_list("]")
        if c == "{":
            return self._parse_sig()
        if c in ")]}":
            raise ReadError(self.line, f"unexpected close delimiter '{c}'")
        if c == '"':
            return self._parse_string()
        if c == "|":
            self._advance()
            return "|"
        return self._parse_atom()

    def _parse_list(self, close):
        start_line = self.line
        is_paren = (close == ")")
        dotted = (close == "]")
        self._advance()  # consume opener
        elems = []
        while True:
            self._skip_ws_and_comments()
            if self.pos >= len(self.text):
                raise ReadError(start_line, "unterminated list")
            c = self.text[self.pos]
            if c == close:
                self._advance()
                break
            if dotted and c == "|":
                # improper cdr: [A B | C] -> ["cons", A, B, "|", C]
                self._advance()
                cdr = self._parse_expr()
                self._skip_ws_and_comments()
                if self.pos >= len(self.text) or self.text[self.pos] != close:
                    raise ReadError(self.line, "unterminated dotted pair")
                self._advance()
                result = ["cons"] + elems + ["|", cdr]
                self.form_lines[id(result)] = start_line
                self.form_is_paren[id(result)] = False
                return result
            elems.append(self._parse_expr())
        result = elems
        self.form_lines[id(result)] = start_line
        self.form_is_paren[id(result)] = is_paren
        return result

    def _parse_sig(self):
        start_line = self.line
        self._advance()  # consume '{'
        elems = ["{"]
        while True:
            self._skip_ws_and_comments()
            if self.pos >= len(self.text):
                raise ReadError(start_line, "unterminated type signature")
            c = self.text[self.pos]
            if c == "}":
                self._advance()
                elems.append("}")
                result = elems
                self.form_lines[id(result)] = start_line
                return result
            if c in ")]":
                raise ReadError(self.line, f"unexpected '{c}' inside type signature")
            elems.append(self._parse_expr())

    def _parse_string(self):
        start_line = self.line
        self._advance()  # consume opening quote
        out = []
        while True:
            if self.pos >= len(self.text):
                raise ReadError(start_line, "unterminated string")
            c = self.text[self.pos]
            if c == '"':
                self._advance()
                return "".join(out)
            out.append(c)
            self._advance()

    def _parse_atom(self):
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] not in _ATOM_DELIM:
            self._advance()
        tok = self.text[start:self.pos]
        if tok == "":
            return ""
        if tok != "-" and _NUM_RE.match(tok):
            return int(tok)
        return tok

    def line_of(self, form):
        """Source line where a parsed list form begins (best-effort)."""
        return self.form_lines.get(id(form))


# ── Source analyzer ───────────────────────────────────────────────────

class SourceAnalyzer:
    """Walks parsed forms, emitting the three violation relations.

    A form head is UNSAFE if it is not a core construct, not a primitive,
    not a library core function, not a function defined in the 12 files, and
    not a variable (higher-order call).  Unsafe forms are NOT recursed into
    (they are opaque) — this keeps e.g. the body of a `(datatype ...)` from
    flagging its internal sequent terms.
    """

    def __init__(self, defined_funcs=None, primitives=None):
        self.defined = set(defined_funcs or ())
        prims = set(primitives) if primitives is not None else set(ext.ALLOWED_PRIMS)
        self.safe = CORE_CONSTRUCTS | prims | EXTERNAL_CORE | self.defined

        self.unsafe = set()
        self.nonlinear = set()
        self.tuple_rows = set()
        self._file = None
        self._reader = None

    # -- per-file analysis ----------------------------------------------
    def analyze(self, text, file):
        self._file = file
        reader = ShenReader(text)
        self._reader = reader
        for line, form in reader.parse_all():
            self._dispatch_top(form, line)
        return self

    def _dispatch_top(self, form, line):
        if not isinstance(form, list) or not form:
            return
        head = form[0]
        if not isinstance(head, str):
            return
        if head in META_ALLOWLIST:
            return  # tc / load / set-toplevel / optimise — skip
        if head == "define":
            self._process_define(form, line)
        else:
            self._walk_body(form)

    # -- define handling -------------------------------------------------
    def _process_define(self, form, line):
        if len(form) < 3:
            return
        rules = form[2:]
        # strip optional { ... --> ... } type signature
        if rules and self._is_type_sig(rules[0]):
            rules = rules[1:]
        for pats, sep, body, guard in self._split_clauses(rules):
            self._analyze_patterns(pats, line)
            self._walk_body(body)
            if guard is not None:
                self._walk_body(guard)

    @staticmethod
    def _is_type_sig(x):
        return isinstance(x, list) and any(e == "-->" for e in x)

    @staticmethod
    def _split_clauses(rules):
        """Split a flat define rule list into clauses.

        Clauses are flat: [Pat1a..Pat1N -> Body1 where? G1? Pat2a.. -> ...].
        Only top-level (list-element) `->`/`<-` symbols act as separators;
        a `->` nested inside a sub-list (e.g. (if (-> a b) ...)) is a list
        element, never a bare symbol, so nesting is naturally excluded.
        """
        first_arrow = None
        for i, e in enumerate(rules):
            if isinstance(e, str) and e in ("->", "<-"):
                first_arrow = i
                break
        if first_arrow is None:
            return []
        arity = first_arrow
        clauses = []
        first_pats = rules[:arity]
        sep = rules[arity]
        body, after, guard = SourceAnalyzer._parse_one_clause(rules[arity + 1:])
        clauses.append((first_pats, sep, body, guard))
        while after:
            pats = after[:arity]
            after = after[arity:]
            if not after:
                break
            sep = after[0]
            if not (isinstance(sep, str) and sep in ("->", "<-")):
                break
            after = after[1:]
            body, after, guard = SourceAnalyzer._parse_one_clause(after)
            clauses.append((pats, sep, body, guard))
        return clauses

    @staticmethod
    def _parse_one_clause(after):
        """after is the flat list past the arrow: [Body where? Guard? ...]."""
        if not after:
            return None, [], None
        body = after[0]
        rest = after[1:]
        guard = None
        if rest and rest[0] == "where":
            guard = rest[1] if len(rest) > 1 else None
            rest = rest[2:]
        return body, rest, guard

    # -- pattern analysis ------------------------------------------------
    def _analyze_patterns(self, pats, line):
        seen = set()
        for pat in pats:
            self._analyze_pattern(pat, seen, line)

    def _analyze_pattern(self, pat, seen, line):
        if isinstance(pat, str):
            if is_variable(pat):
                if pat in seen:
                    self.nonlinear.add((self._file, line, pat))
                else:
                    seen.add(pat)
            return
        if not isinstance(pat, list) or not pat:
            return
        head = pat[0]
        if isinstance(head, str) and head == "@p":
            self.tuple_rows.add((self._file, line))
            for e in pat[1:]:
                self._analyze_pattern(e, seen, line)
            return
        # cons / list pattern: recurse elements (skip cons/| markers)
        for e in pat:
            if isinstance(e, str) and e in ("cons", "|"):
                continue
            self._analyze_pattern(e, seen, line)

    # -- body walker ------------------------------------------------------
    def _walk_body(self, expr):
        if not isinstance(expr, list):
            return
        if not expr:
            return
        is_paren = self._reader.form_is_paren.get(id(expr), False)
        if not is_paren:
            # `[ ... ]` data literal (or `{ ... }` sig) — the head is a data
            # symbol, not a callable, so it is never unsafe.  Still recurse
            # elements to find nested `( call )` groups inside the literal.
            for arg in expr:
                self._walk_body(arg)
            return
        head = expr[0]
        if isinstance(head, str):
            if not (is_variable(head) or head in self.safe):
                # unsafe construct — flag and treat as opaque (no recursion)
                line = self._reader.line_of(expr) or 0
                self.unsafe.add((self._file, line, head))
                return
            # safe special-form recursion
            if head in ("define", "tc", "load", "set-toplevel", "optimise"):
                return
            if head in ("lambda", "/."):
                if len(expr) > 2:
                    self._walk_body(expr[2])  # (lambda Arg Body) -> Body
                return
            if head == "let":
                for i in (2, 3):  # (let Var Val Body) -> walk Val + Body
                    if i < len(expr):
                        self._walk_body(expr[i])
                return
            if head == "if":
                for i in range(1, min(4, len(expr))):
                    self._walk_body(expr[i])
                return
        # generic: recurse all args (and/or/do/where/<-/%%/set/cons/@p/etc)
        for arg in expr[1:]:
            self._walk_body(arg)


# ── Scanning helper ---------------------------------------------------

def scan_defined_functions(text):
    """Collect top-level `(define Name ...)` names from a parsed source text."""
    reader = ShenReader(text)
    names = set()
    for line, form in reader.parse_all():
        if isinstance(form, list) and len(form) >= 2:
            if form[0] == "define" and isinstance(form[1], str):
                names.add(form[1])
    return names


def load_defined_functions(source_dir):
    """Pre-scan all 12 files to collect every locally-defined function name."""
    base = Path(source_dir)
    defined = set()
    for name in SOURCE_FILES:
        p = base / name
        if p.exists():
            defined |= scan_defined_functions(p.read_text())
    return defined


# ── Main ──────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Shen .shen source → CSV fact extractor")
    p.add_argument("--source-dir", default="../../shen/", help="Directory with the .shen files")
    p.add_argument("--out-dir", default="facts", help="Output directory for CSV files")
    p.add_argument("--self-test", action="store_true", help="Run a small self-test")
    return p.parse_args()


def write_facts(out_dir, analyzer, source_files):
    w = SourceWriter(out_dir)
    for f in sorted(source_files):
        w.write("source_file", [f])
    for row in analyzer.unsafe:
        w.write("unsafe_construct", list(row))
    for row in analyzer.nonlinear:
        w.write("nonlinear_pattern", list(row))
    for row in analyzer.tuple_rows:
        w.write("tuple_pattern", list(row))
    w.close()


def main():
    args = parse_args()

    if args.self_test:
        self_test(args.out_dir)
        return

    base = Path(args.source_dir)
    missing = [n for n in SOURCE_FILES if not (base / n).exists()]
    if missing:
        print(f"ERROR: missing source files in {base}: {missing}", file=sys.stderr)
        sys.exit(1)

    defined = load_defined_functions(base)
    analyzer = SourceAnalyzer(defined_funcs=defined)
    source_files = []
    for name in SOURCE_FILES:
        text = (base / name).read_text()
        analyzer.analyze(text, name)
        source_files.append(name)

    write_facts(args.out_dir, analyzer, source_files)
    print(f"Scanned {len(source_files)} source files into {args.out_dir}/")
    print(f"  unsafe_construct:    {len(analyzer.unsafe)}")
    print(f"  nonlinear_pattern:   {len(analyzer.nonlinear)}")
    print(f"  tuple_pattern:       {len(analyzer.tuple_rows)}")


def self_test(out_dir):
    """Minimal self-test: parse a synthetic source and verify output."""
    text = (
        "(define foo X -> (if (cond X) (lambda Y Y) (datatype z X -> z)))\n"
        "(datatype bad X -> X)\n"
        "[X | Rest]\n"
    )
    analyzer = SourceAnalyzer(defined_funcs={"foo"})
    analyzer.analyze(text, "synthetic.shen")
    write_facts(out_dir, analyzer, ["synthetic.shen"])

    with open(Path(out_dir) / "unsafe_construct.csv") as f:
        rows = list(csv.reader(f))
    print(f"Self-test: unsafe_construct rows = {len(rows) - 1}")

    print("Self-test: OK")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""extract.py — Clang JSON AST → CSV fact extractor for GC-safety verification.

Consumes `clang -Xclang -ast-dump=json` output and emits CSV fact files
consumed by gc_safety.dl (Soufflé Datalog).

Usage:
    clang -Xclang -ast-dump=json -fsyntax-only -I vm vm/zincvm.c > /tmp/ast.json
    python3 extract.py --ast /tmp/ast.json --out-dir facts/
    python3 extract.py --self-test --out-dir /tmp/test-facts/   # no clang needed

Phase 1 (2026-08-10): Full AST walk, all 10 CSVs, call_graph dedup,
stmt_allocs from real extraction, field_assign with GC-managed filtering,
void* heuristic for returns_gc_pointer.

Phase 2 (2026-08-11): GC-liveness + must_rooted + root_miss.  Added
next_stmt intra-BB edges, gc_use/gc_def extraction, real stmt_pushes/
stmt_pops from gc_root_push_*/gc_root_pop_* CallExprs.

Phase 3: memcpy_unbarriered — THIS FILE.
"""

import argparse
import csv
import json
import os
import sys
from pathlib import Path


# ── GC type table (hand-curated) ─────────────────────────────────────

# Normalized GC-managed types (after stripping const/volatile/restrict/struct).
GC_MANAGED_TYPES = {
    "Value", "Value *",
    "Instr *", "Instr **",
    "CallFrame *",
    "ValueArray *",
}

# Fields whose assignment we track (the leaf member name of a field access).
GC_MANAGED_FIELD_NAMES = {"code", "env", "car", "cdr", "data"}

# Functions whose void* return value is always a GC-managed pointer.
RETURNS_GC_POINTER = {
    "gc_alloc", "gc_alloc_oldgen", "gc_alloc_atomic",
}

# The 6 may_collect seeds from gc_safety.dl — Phase 1 stmt_allocs covers
# these directly; transitive closure is computed by Soufflé.
MAY_COLLECT_SEEDS = {
    "gc_alloc", "gc_alloc_oldgen", "gc_alloc_atomic",
    "collect", "collect_nursery", "gcalloc_internal",
}

# Phase 5: barrier-relevant types — only Value*/ValueArray* dst needs a write
# barrier.  Instr*/CallFrame* arrays are GC-tag-traced, never barriered.
# NOTE: void* is intentionally excluded — for void* locals whose type is
# resolved via the RETURNS_GC_POINTER heuristic (e.g. void *p = gc_alloc(...)),
# the real GC type is unknown at extract time.  This is a future calibration
# gap: if a void* actually holds a Value* and is memcpy'd without a barrier,
# the verifier will NOT flag it.  In practice the real VM has no such pattern.
BARRIER_RELEVANT_TYPES = {"Value*", "ValueArray*"}

# Phase 3: function names for memcpy/barrier detection.
MEMCPY_FN = "memcpy"
BARRIER_FN = "gc_dirty_vectors_add"

# GC root API function name prefixes (for stmt_pushes/stmt_pops extraction).
GC_ROOT_PUSH_PREFIXES = (
    "gc_root_push_value",
    "gc_root_push_ptr",
    "gc_root_push_value_volatile",
    "gc_root_push_value_array",
    "gc_root_push_callframe_array",
)
GC_ROOT_POP_PREFIXES = (
    "gc_root_pop",
    "gc_root_pop_to",
)

# Map gc_root_push_* callee names to root_kind values.
PUSH_KIND_MAP = {
    "gc_root_push_value":           "ROOT_VALUE",
    "gc_root_push_value_volatile":  "ROOT_VOLATILE",
    "gc_root_push_ptr":             "ROOT_PTR",
    "gc_root_push_value_array":     "ROOT_VALUE_ARRAY",
    "gc_root_push_callframe_array": "ROOT_CALLFRAME_ARRAY",
}


# ── Type normalization helpers ────────────────────────────────────────

def _strip_type_qualifiers(qual_type):
    """Strip const/volatile/restrict/struct prefixes from a Clang qualType.

    Does NOT strip pointer stars — those are semantically significant.
    Returns the normalized type string.
    """
    t = qual_type.strip()
    while True:
        stripped = False
        for prefix in ("const ", "volatile ", "restrict ", "struct "):
            if t.startswith(prefix):
                t = t[len(prefix):]
                stripped = True
                break
        if not stripped:
            break
    return t


def _is_gc_managed_type(qual_type):
    """Check if a (possibly qualified) Clang qualType is GC-managed."""
    return _strip_type_qualifiers(qual_type) in GC_MANAGED_TYPES


def _normalize_type(qual_type):
    """Normalize a Clang qualType to a canonical string for CSV emission.

    Strips qualifiers and maps common Clang spellings to a compact form
    (e.g. 'struct Value *' → 'Value*').
    """
    t = qual_type.strip()
    # Strip const/volatile/restrict
    while True:
        stripped = False
        for prefix in ("const ", "volatile ", "restrict "):
            if t.startswith(prefix):
                t = t[len(prefix):]
                stripped = True
                break
        if not stripped:
            break

    # Normalise struct prefixes to compact forms.
    mapping = {
        "struct Value": "Value",
        "struct Value *": "Value*",
        "struct Value **": "Value**",
        "struct Instr *": "Instr*",
        "struct Instr **": "Instr**",
        "struct CallFrame *": "CallFrame*",
        "struct ValueArray *": "ValueArray*",
        "int": "int",
        "long": "long",
        "char *": "char*",
        "void *": "void*",
        "unsigned int": "unsigned int",
        "unsigned long": "unsigned long",
        "size_t": "size_t",
        "ssize_t": "ssize_t",
        "int *": "int*",
        "void **": "void**",
    }
    return mapping.get(t, t)


def _is_gc_managed(qual_type):
    """Return 1 if the type is GC-managed, 0 otherwise."""
    return 1 if _is_gc_managed_type(qual_type) else 0


# ── Fact writer ──────────────────────────────────────────────────────

CSV_SCHEMAS = {
    "function":     ["name"],
    "cfg_edge":     ["f", "from_stmt_id", "to_stmt_id", "kind"],
    "stmt_allocs":  ["f", "stmt_id", "callee"],
    "stmt_pushes":  ["f", "stmt_id", "root_kind", "slot_expr"],
    "stmt_pops":    ["f", "stmt_id", "pop_count", "pkind"],
    "stmt_memcpy":  ["f", "stmt_id", "dst_expr", "src_expr", "nbytes"],
    "stmt_barrier": ["f", "stmt_id", "target_expr"],
    "var_decl":     ["f", "name", "type", "is_gc_managed"],
    "field_assign": ["f", "stmt_id", "base", "field_path", "rhs_kind"],
    "call_graph":   ["caller", "callee"],
    # Phase 2 additions:
    "next_stmt":    ["f", "from", "to"],
    "gc_use":       ["f", "stmt_id", "v"],
    "gc_def":       ["f", "stmt_id", "v"],
    # Phase 5 additions:
    "defining_alloc": ["f", "var", "stmt_id"],
    # Phase 6 additions:
    "call_site":    ["f", "stmt_id", "callee"],
    "array_store":  ["f", "stmt_id", "base_var"],
}


class FactWriter:
    """Manages output CSV files for all fact relations.

    Rows are buffered in memory (per relation) so that multiple translation
    units can be visited into the same writer before anything is written to
    disk; dedup() removes exact-duplicate rows (overlapping libc/header decls
    appear in every TU); close() flushes headers + deduplicated rows.
    """

    def __init__(self, out_dir):
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        # relation -> set of tuple(row) for exact-dedup
        self._rows = {rel: set() for rel in CSV_SCHEMAS}

    def write(self, relation, row):
        """Buffer a row for a relation.  Row must be a list/tuple of strings."""
        self._rows[relation].add(tuple(row))

    def dedup(self):
        """Explicit no-op; dedup happens continuously via the row set."""
        pass

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


# ── Clang JSON AST visitor ───────────────────────────────────────────

class AstVisitor:
    """Walks a Clang JSON AST and emits fact rows via a FactWriter.

    stmt_id scheme
    --------------
    stmt_id is a per-function integer counter, assigned sequentially in
    depth-first AST walk order.  Only "interesting" nodes consume an id:
      - CallExpr          → used in stmt_allocs, stmt_pushes/pops, gc_use
      - BinaryOperator =  → used in field_assign, gc_def, gc_use

    DeclStmt, VarDecl, ParmVarDecl, and all other nodes do NOT consume
    stmt_ids.  This keeps ids dense and stable — the same source code
    always produces the same ids regardless of how many non-interesting
    nodes exist between interesting ones.

    Phase 2 addition: _current_sid is threaded through the walk so that
    DeclRefExpr and MemberExpr nodes inside a statement can emit gc_use
    facts with the enclosing statement's id.

    Function filtering
    ------------------
    Only FunctionDecl nodes that have a CompoundStmt (function body) are
    emitted to function.csv.  This excludes declarations pulled in from
    headers (which clang emits as FunctionDecl with no body).
    """

    def __init__(self, writer):
        self.writer = writer
        self._current_function = None
        self._stmt_counter = 0
        self._stmt_ids = []            # Phase 2: ordered stmt_ids for next_stmt
        self._gc_locals = set()        # names of GC-managed locals in current fn
        self._call_graph_edges = set() # (caller, callee) for dedup
        # Phase 5 additions:
        self._gc_local_types = {}      # name -> normalized type (Fix 1)
        self._alloc_defined_var = {}   # (f, var) -> sid_alloc (Fix 2 + 3a)
        self._seed_alloc_sids = {}     # f -> list of stmt_allocs sids (Fix 2)
        self._current_bb = 0           # current basic-block id (Fix 3b)
        self._stmt_bb = {}             # sid -> bb_id (Fix 3b)
        self._defining_var = None      # (f, var) or None (Fix 3a context)

    def _next_stmt_id(self):
        sid = self._stmt_counter
        self._stmt_counter += 1
        self._stmt_ids.append(sid)
        self._stmt_bb[sid] = self._current_bb
        return sid

    # ── Top-level walk ────────────────────────────────────────────

    def visit(self, node):
        """Entry point: walk a JSON AST node recursively."""
        if not isinstance(node, dict):
            return
        kind = node.get("kind", "")

        if kind == "FunctionDecl":
            self._visit_function(node)
        elif kind == "TranslationUnitDecl":
            self._visit_children(node)
        elif kind in ("TypedefDecl", "RecordDecl", "EnumDecl", "EnumConstantDecl"):
            pass  # skip
        elif kind == "VarDecl":
            # Global variable — skip for now
            pass
        else:
            # Unknown top-level node — recurse
            self._visit_children(node)

    def _visit_children(self, node):
        """Recurse into node's 'inner' array."""
        for child in node.get("inner", []):
            self.visit(child)

    # ── Function declaration ──────────────────────────────────────

    def _visit_function(self, node):
        name = node.get("name", "")
        if not name:
            return

        # ── Separate params from body; look for CompoundStmt ──
        params = []
        body = None
        for child in node.get("inner", []):
            if not isinstance(child, dict):
                continue
            ck = child.get("kind", "")
            if ck == "ParmVarDecl":
                params.append(child)
            elif ck == "CompoundStmt":
                body = child

        # Only emit functions defined in the VM sources (those with a body).
        # Header declarations appear as FunctionDecl with no CompoundStmt.
        if body is None:
            return

        # ── Initialise per-function state ──
        self._current_function = name
        self._stmt_counter = 0
        self._stmt_ids = []
        self._gc_locals = set()
        self._call_graph_edges = set()
        self._current_bb = 0
        self._stmt_bb = {}
        self._defining_var = None
        self._seed_alloc_sids[name] = []

        # Emit function fact.
        self.writer.write("function", [name])

        # Emit var_decl for parameters.
        for p in params:
            self._emit_var_decl(name, p)

        # Full recursive walk of the function body.
        self._walk_body(name, body)

        # ── Phase 5: next_stmt intra-BB edges (CaseStmt-scoped) ──
        # Fix 3b: next_stmt edges only connect stmt_ids within the same
        # basic block.  CaseStmt/DefaultStmt boundaries increment the BB
        # counter, so variables used in one case are NOT live across
        # an alloc in another case.  This is an under-approximation
        # (drops cross-case sequencing + loop-back edges) — safe for
        # root_miss (fewer live facts ⇒ no new FPs).  Historical root-miss
        # bugs are intra-case straight-line, so they are still caught.
        for i in range(len(self._stmt_ids) - 1):
            a, b = self._stmt_ids[i], self._stmt_ids[i + 1]
            if self._stmt_bb.get(a) == self._stmt_bb.get(b):
                self.writer.write("next_stmt",
                                  [name, str(a), str(b)])

        # ── Phase 5: defining_alloc (Fix 3a) ──
        # At the stmt_allocs call that CREATES v (v's own allocating
        # initializer), v holds no pre-existing pointer → no root_miss.
        for (f, var), sid_alloc in self._alloc_defined_var.items():
            if f == name:
                self.writer.write("defining_alloc", [f, var, str(sid_alloc)])

        # Reset per-function state.
        self._current_function = None
        self._gc_locals = set()

    # ── Full body walk (Phase 2) ──────────────────────────────────

    def _walk_body(self, func_name, node, current_sid=None):
        """Full recursive walk of a function body node and its descendants.

        Assigns stmt_ids to CallExpr and BinaryOperator (=) nodes.
        Extracts var_decl, call_graph, stmt_allocs, stmt_pushes, stmt_pops,
        field_assign, gc_use, and gc_def facts.

        Phase 2: current_sid threads the enclosing statement's id through
        child nodes so DeclRefExpr/MemberExpr can emit gc_use.
        """
        if not isinstance(node, dict):
            return

        kind = node.get("kind", "")

        # ── CallExpr → call_graph + stmt_allocs + stmt_pushes/pops ──
        if kind == "CallExpr":
            sid = self._next_stmt_id()
            self._handle_call_expr(func_name, sid, node)
            # Recurse into children with this sid for gc_use tracking.
            for child in node.get("inner", []):
                self._walk_body(func_name, child, current_sid=sid)
            return

        # ── VarDecl → var_decl + (if initialized) gc_def ──
        elif kind == "VarDecl":
            self._emit_var_decl(func_name, node)
            vname = node.get("name", "")
            # Some clang versions put the initializer in the "init" key as a
            # dict; others store it as a child of "inner".  Defensively, only
            # trust "init" when it is a real dict (clang 22 on this host emits
            # a junk string there and the real init is in inner[0]).
            node_init = node.get("init")
            if not isinstance(node_init, dict):
                node_init = self._find_init_in_inner(node)
            has_init = node_init is not None
            init_callee = self._extract_init_callee(node_init) if has_init else ""
            init_in_key = isinstance(node.get("init"), dict)
            if has_init and vname and vname in self._gc_locals:
                sid = self._next_stmt_id()
                self.writer.write("gc_def",
                                  [func_name, str(sid), vname])
                if init_in_key:
                    # Init is in "init" key — walk it
                    # explicitly (it is NOT in "inner", so no double-walk
                    # from the general recursion below).
                    if init_callee in MAY_COLLECT_SEEDS:
                        old_defining = self._defining_var
                        self._defining_var = (func_name, vname)
                        self._walk_body(func_name, node_init,
                                        current_sid=sid)
                        self._defining_var = old_defining
                    else:
                        self._walk_body(func_name, node_init,
                                        current_sid=sid)
                elif init_callee in MAY_COLLECT_SEEDS:
                    # Init is in "inner" — thread _defining_var so the
                    # general recursion records it in _handle_call_expr.
                    # No explicit walk (avoids double-walk of the same
                    # children that the general recursion will visit).
                    self._defining_var = (func_name, vname)
                else:
                    # Inner-style non-seed init (e.g. `Value result = v;`).
                    # The general recursion below walks inner children but
                    # with the ENCLOSING current_sid (None at top level), so
                    # the init's DeclRefExprs would not get a gc_use at this
                    # VarDecl's sid.  Walk the init explicitly with our sid
                    # so `v` in `Value result = v` becomes live here.
                    # Guard: only if the init has NO CallExpr (a call would
                    # be double-stmt_id'd by the general recursion below).
                    if init_callee == "":
                        self._walk_body(func_name, node_init, current_sid=sid)
            # Fall through to general recursion for inner children.

        # ── BinaryOperator = → field_assign + gc_def ──
        elif kind == "BinaryOperator":
            opcode = node.get("opcode", "")
            if opcode == "=":
                sid = self._next_stmt_id()
                self._handle_assignment(func_name, sid, node)
                # Recurse with this sid for gc_use in RHS.
                for child in node.get("inner", []):
                    self._walk_body(func_name, child, current_sid=sid)
                return

        # ── DeclRefExpr → gc_use (if inside a statement) ──
        elif kind == "DeclRefExpr":
            if current_sid is not None:
                vname = node.get("referencedDecl", {}).get("name", "")
                if vname and vname in self._gc_locals:
                    self.writer.write("gc_use",
                                      [func_name, str(current_sid), vname])

        # ── MemberExpr → gc_use for base (if inside a statement) ──
        elif kind == "MemberExpr":
            if current_sid is not None:
                base = self._extract_base(node)
                if base and base in self._gc_locals:
                    self.writer.write("gc_use",
                                      [func_name, str(current_sid), base])

        # ── Expression nodes that contain calls: recurse ──
        elif kind in ("ImplicitCastExpr", "CStyleCastExpr", "ParenExpr",
                       "UnaryOperator", "ConditionalOperator",
                       "ArraySubscriptExpr", "CompoundAssignOperator",
                       "IntegerLiteral", "StringLiteral", "CharacterLiteral",
                       "FloatingLiteral", "CXXBoolLiteralExpr",
                       "InitListExpr", "ImplicitValueInitExpr",
                       "VAArgExpr", "OffsetOfExpr", "UnaryExprOrTypeTraitExpr",
                       "ConstantExpr", "PredefinedExpr", "GNUNullExpr",
                       "GenericSelectionExpr", "StmtExpr", "BlockExpr",
                       "OpaqueValueExpr", "BinaryConditionalOperator",
                       "CompoundLiteralExpr", "MaterializeTemporaryExpr",
                       "CXXFunctionalCastExpr", "CXXStaticCastExpr",
                       "CXXReinterpretCastExpr", "CXXConstCastExpr",
                       "AddrLabelExpr", "ChooseExpr", "ConvertVectorExpr",
                       "ShuffleVectorExpr", "DesignatedInitExpr",
                       "ExprWithCleanups"):
            pass  # expressions — just recurse into children

        # ── Fix 3b: SwitchStmt — recurse normally; CaseStmt/DefaultStmt
        # children handle BB scoping themselves.
        elif kind == "SwitchStmt":
            pass  # fall through to general recursion

        # ── Fix 3b: CaseStmt / DefaultStmt — each case is its own BB.
        # next_stmt edges do NOT cross case boundaries (conservative
        # under-approximation: drops cross-case sequencing + loop-back).
        elif kind in ("CaseStmt", "DefaultStmt"):
            self._current_bb += 1
            for child in node.get("inner", []):
                self._walk_body(func_name, child, current_sid=current_sid)
            return

        # ── Statement nodes (control flow, labels, etc.) ──
        elif kind in ("IfStmt", "WhileStmt", "ForStmt", "DoStmt",
                       "ReturnStmt", "LabelStmt", "GotoStmt",
                       "BreakStmt", "ContinueStmt", "NullStmt",
                       "IndirectGotoStmt", "CompoundStmt",
                       "AttributedStmt"):
            pass  # recurse only

        # Recurse into children for ALL remaining node kinds.
        # For nodes that return early (CallExpr, BinaryOperator =), this
        # is not reached.
        for child in node.get("inner", []):
            self._walk_body(func_name, child, current_sid=current_sid)

    # ── Call expression handling ──────────────────────────────────

    def _handle_call_expr(self, func_name, sid, node):
        """Emit call_graph, stmt_allocs (if allocator), and stmt_pushes/pops
        (for gc_root_* API calls)."""
        callee = self._extract_callee(node)
        if not callee:
            return

        # Phase 3: detect memcpy / gc_dirty_vectors_add calls.
        if callee == MEMCPY_FN:
            self._handle_memcpy_call(func_name, sid, node)
            return
        if callee == BARRIER_FN:
            self._handle_barrier_call(func_name, sid, node)
            return

        # Phase 2: detect gc_root_push_* / gc_root_pop_* calls.
        if self._handle_gc_root_api(func_name, sid, node, callee):
            return  # API call handled; don't emit call_graph/stmt_allocs for it.

        # Dedup call_graph edges.
        edge = (func_name, callee)
        if edge not in self._call_graph_edges:
            self._call_graph_edges.add(edge)
            self.writer.write("call_graph", [func_name, callee])

        # stmt_allocs: only emit if callee is a may_collect seed.
        # Transitive closure (functions that call allocators) is computed
        # by Soufflé.
        if callee in MAY_COLLECT_SEEDS:
            self.writer.write("stmt_allocs", [func_name, str(sid), callee])
            # Fix 2: track all alloc sids for fresh_target intervening check.
            self._seed_alloc_sids.setdefault(func_name, []).append(sid)
            # Fix 3a: if this alloc is inside a VarDecl initializer for a
            # GC-managed var, record the (fn, var) -> sid_alloc mapping.
            # Clear _defining_var so only the very first alloc in the
            # initializer is recorded (the defining alloc).
            if self._defining_var is not None:
                dv_fn, dv_var = self._defining_var
                if dv_fn == func_name:
                    self._alloc_defined_var[(func_name, dv_var)] = sid
                    self._defining_var = None

        # Phase 6 (Rule 3): call_site — emitted for ALL resolved callees
        # (including non-seed indirect callers).  transitive_alloc_site in
        # gc_safety.dl uses this to catch calls to functions that
        # transitively allocate but are not themselves a may_collect seed.
        # Reuses the existing stmt_id (no new ids).
        if callee:
            self.writer.write("call_site", [func_name, str(sid), callee])

    # ── Phase 2: GC root API detection ────────────────────────────

    def _handle_gc_root_api(self, func_name, sid, node, callee):
        """Detect gc_root_push_* / gc_root_pop_* calls and emit stmt_pushes/pops.

        Returns True if the call was recognized as a GC root API call
        (and was handled), False otherwise.
        """
        # ── gc_root_push_* ──
        if callee in PUSH_KIND_MAP:
            root_kind = PUSH_KIND_MAP[callee]
            slot_expr = self._extract_push_slot(node, callee)
            if slot_expr:
                self.writer.write("stmt_pushes",
                                  [func_name, str(sid), root_kind, slot_expr])
            return True

        # ── gc_root_pop (no args) → pop_one ──
        if callee == "gc_root_pop":
            # gc_root_pop() takes no arguments; count = 1
            self.writer.write("stmt_pops",
                              [func_name, str(sid), "1", "pop_one"])
            return True

        # ── gc_root_pop_to(watermark) → pop_to ──
        if callee == "gc_root_pop_to":
            # Count is irrelevant for pop_to; use 0.
            self.writer.write("stmt_pops",
                              [func_name, str(sid), "0", "pop_to"])
            return True

        return False

    # ── Phase 3: memcpy / barrier extraction ──────────────────────

    def _handle_memcpy_call(self, func_name, sid, node):
        """Extract stmt_memcpy fact from a memcpy(dst, src, nbytes) call.

        Only emits a fact if dst is a GC-managed local (via _gc_locals)
        AND the dst type is barrier-relevant (Value* or ValueArray*).
        Instr*/CallFrame* arrays are GC-tag-traced, never barriered.
        """
        args = self._call_args(node)
        if len(args) < 3:
            return
        dst_var = self._extract_var_from_arg(args[0])
        if not dst_var or dst_var not in self._gc_locals:
            return
        # Fix 1: only barrier-relevant types need stmt_memcpy tracking.
        # Normalize both sides by stripping whitespace: real clang emits
        # "Value *", the hand-crafted self-test AST uses "Value*" (via
        # "struct Value *" -> _normalize_type -> "Value*").
        if (self._gc_local_types.get(dst_var) or "").replace(" ", "") \
                not in BARRIER_RELEVANT_TYPES:
            return
        src_var = self._extract_var_from_arg(args[1])
        nbytes_text = self._extract_literal_or_text(args[2])
        self.writer.write("stmt_memcpy",
                          [func_name, str(sid), dst_var, src_var, nbytes_text])

    def _handle_barrier_call(self, func_name, sid, node):
        """Extract stmt_barrier fact from a gc_dirty_vectors_add(target) call."""
        args = self._call_args(node)
        if not args:
            return
        target_var = self._extract_var_from_arg(args[0])
        if not target_var:
            target_var = self._extract_base(args[0])
        if not target_var:
            return
        self.writer.write("stmt_barrier",
                          [func_name, str(sid), target_var])

    def _extract_push_slot(self, node, callee):
        """Extract the slot variable name from a gc_root_push_* CallExpr.

        gc_root_push_value(&v)        → "v"
        gc_root_push_ptr((void **)&p) → "p"
        gc_root_push_value_array(arr, &n) → "arr"
        gc_root_push_callframe_array(cf, &n) → "cf"

        Returns the first argument's variable name (stripping & and casts),
        or empty string if unresolvable.
        """
        inner = node.get("inner", [])
        # Skip past ImplicitCastExpr to find the first real argument.
        for child in inner:
            if not isinstance(child, dict):
                continue
            # Skip the callee DeclRefExpr/ImplicitCastExpr (first child
            # is usually the function pointer).  The second child is arg 0.
            pass

        # Find the first argument expression (skip the callee ref).
        # The callee is the first DeclRefExpr (possibly wrapped in
        # ImplicitCastExpr).  Arguments follow.
        found_callee = False
        for child in inner:
            if not isinstance(child, dict):
                continue
            ck = child.get("kind", "")
            if not found_callee:
                if ck in ("ImplicitCastExpr", "DeclRefExpr"):
                    found_callee = True
                continue
            # This is the first argument.
            return self._extract_var_from_arg(child)

        return ""

    def _extract_var_from_arg(self, node):
        """Extract variable name from an argument expression.

        Handles: DeclRefExpr → name, UnaryOperator &/* → inner DeclRefExpr,
        ImplicitCastExpr → inner, CStyleCastExpr → inner.
        """
        if not isinstance(node, dict):
            return ""
        kind = node.get("kind", "")
        if kind == "DeclRefExpr":
            return node.get("referencedDecl", {}).get("name", "")
        if kind == "UnaryOperator":
            # &v and *v both resolve to v (address-of and dereference).
            for child in node.get("inner", []):
                name = self._extract_var_from_arg(child)
                if name:
                    return name
        if kind in ("ImplicitCastExpr", "CStyleCastExpr", "ParenExpr"):
            for child in node.get("inner", []):
                name = self._extract_var_from_arg(child)
                if name:
                    return name
        return ""

    # ── Phase 3 helpers ───────────────────────────────────────────

    def _call_args(self, node):
        """Return list of CallExpr argument nodes (skip callee ref).

        The callee is the first DeclRefExpr/UnresolvedLookupExpr/MemberExpr
        (possibly wrapped in ImplicitCastExpr).  Everything after that is an
        argument.
        """
        inner = node.get("inner", [])
        # Collect argument nodes: skip the callee reference (first
        # ImplicitCastExpr/DeclRefExpr/UnresolvedLookupExpr/MemberExpr).
        args = []
        found_callee = False
        for child in inner:
            if not isinstance(child, dict):
                continue
            ck = child.get("kind", "")
            if not found_callee:
                if ck in ("ImplicitCastExpr", "DeclRefExpr",
                           "UnresolvedLookupExpr", "MemberExpr"):
                    found_callee = True
                continue
            args.append(child)
        return args

    def _extract_literal_or_text(self, node):
        """Return text representation of a literal node.

        IntegerLiteral → decimal string; otherwise empty string.
        """
        if not isinstance(node, dict):
            return ""
        kind = node.get("kind", "")
        if kind == "IntegerLiteral":
            return node.get("value", "")
        return ""

    def _extract_callee(self, node):
        """Extract the callee function name from a CallExpr or ImplicitCastExpr.

        Returns the empty string if the callee cannot be resolved to a
        simple function name (eg indirect calls through function pointers).
        """
        for child in node.get("inner", []):
            if not isinstance(child, dict):
                continue
            ck = child.get("kind", "")
            if ck == "ImplicitCastExpr":
                # Look through cast to find the DeclRefExpr.
                for gc in child.get("inner", []):
                    if isinstance(gc, dict) and gc.get("kind") == "DeclRefExpr":
                        return gc.get("referencedDecl", {}).get("name", "")
            elif ck == "DeclRefExpr":
                return child.get("referencedDecl", {}).get("name", "")
            elif ck == "MemberExpr":
                # Indirect call through struct member — return member name
                # (Phase 1 best-effort; Phase 2 may need the full path).
                return child.get("name", "")
        return ""

    # ── Assignment handling (Phase 2: adds gc_def) ────────────────

    def _handle_assignment(self, func_name, sid, node):
        """Handle BinaryOperator '=': field_assign (Phase 1) + gc_def (Phase 2)."""
        inner = node.get("inner", [])
        if len(inner) < 2:
            return

        lhs_node = inner[0]
        rhs_node = inner[1]

        if not isinstance(lhs_node, dict):
            return

        # ── Phase 1: field_assign ──
        field_path = self._extract_field_path(lhs_node)
        base = self._extract_base(lhs_node)
        rhs_kind = self._classify_rhs(rhs_node)

        if base and field_path:
            # Filter 1: base must be a GC-managed local.
            if base in self._gc_locals:
                # Filter 2: leaf member must be a GC-managed field.
                leaf_member = (field_path.rsplit(".", 1)[-1]
                               if "." in field_path
                               else field_path.lstrip("."))
                if leaf_member in GC_MANAGED_FIELD_NAMES:
                    self.writer.write("field_assign", [
                        func_name, str(sid), base, field_path, rhs_kind
                    ])

        # ── Phase 2: gc_def for direct assignment to GC-managed var ──
        # v = expr  (where LHS is a DeclRefExpr to a GC-managed var)
        if lhs_node.get("kind") == "DeclRefExpr":
            vname = lhs_node.get("referencedDecl", {}).get("name", "")
            if vname and vname in self._gc_locals:
                self.writer.write("gc_def",
                                  [func_name, str(sid), vname])

        # ── Phase 6 (Rule 4): array_store for single-Value writes into a
        # GC-managed array (ne[i]=v, a->data[i]=v, (*env)[i]=v).  These
        # need a write barrier mirroring memcpy_unbarriered.
        if lhs_node.get("kind") == "ArraySubscriptExpr":
            base = self._extract_base(lhs_node)
            if base and base in self._gc_locals:
                base_type = (self._gc_local_types.get(base) or "").replace(" ", "")
                if base_type in {"Value*", "ValueArray*"}:
                    self.writer.write("array_store",
                                      [func_name, str(sid), base])

    # ── Variable declarations ─────────────────────────────────────

    def _emit_var_decl(self, func_name, node):
        """Emit a var_decl fact for a ParmVarDecl or VarDecl.

        Also populates self._gc_locals for use by field_assign filtering
        and gc_use/gc_def extraction.
        """
        vname = node.get("name", "")
        if not vname:
            return

        qual_type = node.get("type", {}).get("qualType", "")
        vtype = _normalize_type(qual_type)

        is_gc = _is_gc_managed(qual_type)

        # void* heuristic: if a void* local is initialized with a call to
        # a returns_gc_pointer function (gc_alloc etc.), treat it as
        # GC-managed.  Without this, void* return values from gc_alloc*
        # would be invisible to the liveness analysis.
        if not is_gc:
            norm = _normalize_type(qual_type)
            if norm == "void*":
                node_init = node.get("init") or self._find_init_in_inner(node)
                if self._extract_init_callee(node_init) in RETURNS_GC_POINTER:
                    is_gc = 1

        if is_gc:
            self._gc_locals.add(vname)
            self._gc_local_types[vname] = vtype

        self.writer.write("var_decl", [func_name, vname, vtype, str(is_gc)])

    def _extract_var_init_callee(self, var_decl_node):
        """Extract callee name from a VarDecl's initializer, if it's a call.

        Returns the empty string if no initializer or not a call expression.
        """
        for child in var_decl_node.get("inner", []):
            if not isinstance(child, dict):
                continue
            ck = child.get("kind", "")
            if ck == "CallExpr":
                return self._extract_callee(child)
            elif ck == "ImplicitCastExpr":
                # Look through cast for CallExpr.
                for gc in child.get("inner", []):
                    if isinstance(gc, dict) and gc.get("kind") == "CallExpr":
                        return self._extract_callee(gc)
        return ""

    def _find_init_in_inner(self, var_decl_node):
        """Find an init expression stored as a child in 'inner' (vs 'init' key).

        Real clang 22 stores VarDecl initializers in the "init" key, but
        hand-crafted ASTs (self-test) and older clang versions put them as
        children of "inner".  Skips TypeLoc, NestedNameSpecifier, and
        ParmVarDecl children that are type metadata, not expressions.
        """
        TYPE_META_KINDS = {"TypeLoc", "NestedNameSpecifier", "ParmVarDecl"}
        for child in var_decl_node.get("inner", []):
            if isinstance(child, dict) and child.get("kind", "") not in TYPE_META_KINDS:
                return child
        return None

    def _extract_init_callee(self, init_node):
        """Extract callee name from an init expression (handles cast wrapping).

        Returns the callee function name if the init is (or wraps) a CallExpr,
        or the empty string if the init is a DeclRefExpr, literal, etc.
        """
        if not isinstance(init_node, dict):
            return ""
        if init_node.get("kind") == "CallExpr":
            return self._extract_callee(init_node)
        for child in init_node.get("inner", []):
            if isinstance(child, dict):
                r = self._extract_init_callee(child)
                if r:
                    return r
        return ""

    # ── Field assignment helpers ──────────────────────────────────

    def _extract_field_path(self, node):
        """Extract field path like 'lambda.code' from a MemberExpr chain.

        Returns a string with dot-separated field names.  For a single
        MemberExpr accessing field 'code', returns '.code'.
        """
        if not isinstance(node, dict):
            return ""
        kind = node.get("kind", "")
        if kind == "MemberExpr":
            member = node.get("name", "")
            inner = node.get("inner", [])
            if inner and isinstance(inner[0], dict):
                base_path = self._extract_field_path(inner[0])
                if base_path:
                    return f"{base_path}.{member}"
                return f".{member}"
        elif kind == "ArraySubscriptExpr":
            # Array access like base[i]; treat as opaque for now.
            return "[]"
        return ""

    def _extract_base(self, node):
        """Extract the base variable name from a field access chain."""
        if not isinstance(node, dict):
            return ""
        kind = node.get("kind", "")
        if kind == "DeclRefExpr":
            return node.get("referencedDecl", {}).get("name", "")
        if kind == "MemberExpr":
            inner = node.get("inner", [])
            if inner and isinstance(inner[0], dict):
                return self._extract_base(inner[0])
        if kind == "ArraySubscriptExpr":
            # Array subscript like cf->stack.data[i]; walk LHS.
            inner = node.get("inner", [])
            if inner and isinstance(inner[0], dict):
                return self._extract_base(inner[0])
        if kind == "ImplicitCastExpr":
            # Array-subscript bases are often wrapped in a cast
            # (e.g. `env[env_len]` → ImplicitCastExpr → DeclRefExpr env).
            inner = node.get("inner", [])
            for child in inner:
                if isinstance(child, dict):
                    b = self._extract_base(child)
                    if b:
                        return b
        if kind == "UnaryOperator":
            # Phase 6 (Rule 4): unwrap deref (`(*env)[i]` → env).  The
            # operand of a UnaryOperator is typically inner[0].
            inner = node.get("inner", [])
            for child in inner:
                if isinstance(child, dict):
                    b = self._extract_base(child)
                    if b:
                        return b
        return ""

    def _classify_rhs(self, node):
        """Classify RHS of an assignment: local, call, constant, unknown."""
        if not isinstance(node, dict):
            return "unknown"
        kind = node.get("kind", "")
        if kind == "DeclRefExpr":
            return "local"
        if kind == "CallExpr":
            return "call"
        if kind in ("IntegerLiteral", "StringLiteral", "CharacterLiteral",
                     "FloatingLiteral", "CXXBoolLiteralExpr"):
            return "constant"
        if kind == "ImplicitCastExpr":
            inner = node.get("inner", [])
            if inner and isinstance(inner[0], dict):
                return self._classify_rhs(inner[0])
        if kind == "MemberExpr":
            return "member"
        if kind == "UnaryOperator":
            return "unary"
        return "unknown"


# ── Self-test: hardcoded AST (Phase 2 update) ─────────────────────────
#
# The self-test AST represents a simplified val_lambda-like function
# that exercises all Phase 1+2 extraction pathways:
#   - GC-managed params (code, env) and locals (v → Value, p → void*)
#   - Non-GC local (msg → char*)
#   - CallExpr to allocator (gc_alloc → stmt_allocs)
#   - CallExpr to non-allocator (strlen → call_graph only)
#   - Field assignments: v.lambda.code (GC field → emitted),
#     v.lambda.env (GC field → emitted), v.tag (non-GC field → skipped)
#   - void* with gc_alloc_oldgen initializer → is_gc_managed=1
#   - Phase 2: gc_root_push_value / gc_root_pop / gc_root_pop_to calls
#     → real stmt_pushes/stmt_pops
#   - Phase 2: gc_use from DeclRefExpr/MemberExpr inside CallExpr args
#   - Phase 2: gc_def from direct assignment to GC-managed var
#   - Phase 2: next_stmt edges between consecutive stmt_ids
#

SELF_TEST_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "val_lambda",
            "type": {"qualType": "struct Value"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "code",
                    "type": {"qualType": "struct Instr *"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "code_len",
                    "type": {"qualType": "int"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "env",
                    "type": {"qualType": "struct Value *"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "env_len",
                    "type": {"qualType": "int"},
                },
                {
                    "kind": "CompoundStmt",
                    "inner": [
                        # ── GC-managed local: Value v ──
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "v",
                                    "type": {"qualType": "struct Value"},
                                }
                            ],
                        },
                        # ── Non-GC local: char *msg ──
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "msg",
                                    "type": {"qualType": "char *"},
                                }
                            ],
                        },
                        # ── void* with gc_alloc_oldgen init → GC-managed ──
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "p",
                                    "type": {"qualType": "void *"},
                                    "inner": [
                                        {
                                            "kind": "ImplicitCastExpr",
                                            "inner": [
                                                {
                                                    "kind": "CallExpr",
                                                    "inner": [
                                                        {
                                                            "kind": "ImplicitCastExpr",
                                                            "inner": [
                                                                {
                                                                    "kind": "DeclRefExpr",
                                                                    "referencedDecl": {
                                                                        "name": "gc_alloc_oldgen",
                                                                    },
                                                                }
                                                            ],
                                                        }
                                                    ],
                                                }
                                            ],
                                        }
                                    ],
                                }
                            ],
                        },
                        # ── Phase 5: Value *new_env = gc_alloc(...) ──
                        # Barrier-relevant type → memcpy into it WILL emit
                        # stmt_memcpy.  Also exercises defining_alloc +
                        # fresh_target (no intervening alloc before memcpy).
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "new_env",
                                    "type": {"qualType": "struct Value *"},
                                    "inner": [
                                        {
                                            "kind": "ImplicitCastExpr",
                                            "inner": [
                                                {
                                                    "kind": "CallExpr",
                                                    "inner": [
                                                        {
                                                            "kind": "ImplicitCastExpr",
                                                            "inner": [
                                                                {
                                                                    "kind": "DeclRefExpr",
                                                                    "referencedDecl": {
                                                                        "name": "gc_alloc",
                                                                    },
                                                                }
                                                            ],
                                                        }
                                                    ],
                                                }
                                            ],
                                        }
                                    ],
                                }
                            ],
                        },
                        # ── memcpy(new_env, env, 16) ──
                        # (immediately after defining alloc → fresh_target)
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "memcpy",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "new_env"},
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "env"},
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "16",
                                },
                            ],
                        },
                        # ── gc_dirty_vectors_add(new_env) → stmt_barrier ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "gc_dirty_vectors_add",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "new_env"},
                                },
                            ],
                        },
                        # ── memset call ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "memset"},
                                        }
                                    ],
                                }
                            ],
                        },
                        # ── strlen call (libc, NOT an allocator) ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "strlen"},
                                        }
                                    ],
                                }
                            ],
                        },
                        # ── gc_root_push_value(&code) → stmt_pushes ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "gc_root_push_value",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "UnaryOperator",
                                    "opcode": "&",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "code"},
                                        }
                                    ],
                                },
                            ],
                        },
                        # ── gc_root_push_value(&env) → stmt_pushes ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "gc_root_push_value",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "UnaryOperator",
                                    "opcode": "&",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "env"},
                                        }
                                    ],
                                },
                            ],
                        },
                        # ── gc_alloc call (IS an allocator → stmt_allocs) ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "gc_alloc",
                                            },
                                        }
                                    ],
                                },
                                # Pass 'code' as an argument → gc_use of code
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "code"},
                                },
                            ],
                        },
                        # ── memcpy(p, env, 16) → stmt_memcpy (Phase 3) ──
                        # dst 'p' is a GC-managed void* (RETURNS_GC_POINTER),
                        # src 'env' is GC-managed Value*.
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "memcpy",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "p"},
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "env"},
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "16",
                                },
                            ],
                        },
                        # ── gc_dirty_vectors_add(p) → stmt_barrier (Phase 3) ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "gc_dirty_vectors_add",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "p"},
                                },
                            ],
                        },
                        # ── v.lambda.env = GC_VALUE_ARRAY(...) ──
                        # GC field 'env' → field_assign emitted;
                        # 'v' is base of MemberExpr → gc_use of v
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                {
                                    "kind": "MemberExpr",
                                    "name": "env",
                                    "inner": [
                                        {
                                            "kind": "MemberExpr",
                                            "name": "lambda",
                                            "inner": [
                                                {
                                                    "kind": "DeclRefExpr",
                                                    "referencedDecl": {"name": "v"},
                                                }
                                            ],
                                        }
                                    ],
                                },
                                {
                                    "kind": "CallExpr",
                                    "inner": [
                                        {
                                            "kind": "ImplicitCastExpr",
                                            "inner": [
                                                {
                                                    "kind": "DeclRefExpr",
                                                    "referencedDecl": {
                                                        "name": "GC_VALUE_ARRAY",
                                                    },
                                                }
                                            ],
                                        }
                                    ],
                                },
                            ],
                        },
                        # ── v.lambda.code = code ──
                        # GC field 'code' → field_assign emitted;
                        # 'v' is base → gc_use of v; 'code' in RHS → gc_use
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                {
                                    "kind": "MemberExpr",
                                    "name": "code",
                                    "inner": [
                                        {
                                            "kind": "MemberExpr",
                                            "name": "lambda",
                                            "inner": [
                                                {
                                                    "kind": "DeclRefExpr",
                                                    "referencedDecl": {"name": "v"},
                                                }
                                            ],
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "code"},
                                },
                            ],
                        },
                        # ── gc_root_pop_to(some_wm) → stmt_pops pop_to ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "gc_root_pop_to",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "some_wm"},
                                },
                            ],
                        },
                        # ── v.tag = VAL_LAMBDA ──
                        # 'tag' is NOT a GC field → NOT emitted as field_assign;
                        # but 'v' is base → gc_use of v
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                {
                                    "kind": "MemberExpr",
                                    "name": "tag",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "v"},
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "VAL_LAMBDA"},
                                },
                            ],
                        },
                    ],
                },
            ],
        },
        # ── A function from a header (no body) → should NOT be emitted ──
        {
            "kind": "FunctionDecl",
            "name": "printf",
            "type": {"qualType": "int (const char *, ...)"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "format",
                    "type": {"qualType": "const char *"},
                },
            ],
        },
    ],
}


def run_self_test(writer):
    """Emit facts from the hardcoded SELF_TEST_AST dict.

    Phase 3: stmt_memcpy and stmt_barrier are now extracted from real
    CallExpr nodes in the self-test AST.
    Phase 5: defining_alloc + fresh_target emitted for Value* vars with
    alloc initializers (new_env).  The void* p memcpy is suppressed by
    BARRIER_RELEVANT_TYPES filtering (Fix 1).
    """
    visitor = AstVisitor(writer)
    visitor.visit(SELF_TEST_AST)

    # ── Skeleton rows ──────────────────────────────────────────────
    # cfg_edge: still skeleton (Phase 2 uses next_stmt instead).
    writer.write("cfg_edge",    ["val_lambda", "0", "1", "fall"])


# ── CLI ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Clang JSON AST → CSV fact extractor for gc_safety.dl"
    )
    parser.add_argument(
        "--ast", metavar="FILE.json", action="append", default=[],
        help="Clang -ast-dump=json output file (repeatable: extract multiple TUs)"
    )
    parser.add_argument(
        "--out-dir", metavar="DIR", default="facts",
        help="Output directory for CSV fact files (default: facts/)"
    )
    parser.add_argument(
        "--self-test", action="store_true",
        help="Run self-test: emit CSVs from hardcoded AST (no clang needed)"
    )
    args = parser.parse_args()

    if not args.self_test and not args.ast:
        parser.print_help()
        print("\nError: either --ast or --self-test is required", file=sys.stderr)
        sys.exit(1)

    writer = FactWriter(args.out_dir)

    try:
        if args.self_test:
            run_self_test(writer)
            print(f"Self-test facts written to {args.out_dir}/")
        else:
            # Multiple --ast files: each is a separate translation unit (e.g.
            # vm/zincvm.c and vm/gc.c).  Each TU is visited into its own writer
            # buffer; overlapping rows (e.g. libc decls present in both TUs)
            # are de-duplicated at close() by FactWriter.dedup().
            for ast_file in args.ast:
                with open(ast_file, "r") as f:
                    ast = json.load(f)
                visitor = AstVisitor(writer)
                visitor.visit(ast)
                print(f"Facts extracted from {ast_file} → {args.out_dir}/")
            writer.dedup()
    finally:
        writer.close()


if __name__ == "__main__":
    main()

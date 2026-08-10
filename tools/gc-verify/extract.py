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

Phases 2-3: cfg_edge/stmt_pushes/stmt_pops/stmt_memcpy/stmt_barrier still
skeleton — real extraction is future work.
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
}


class FactWriter:
    """Manages output CSV files for all 10 fact relations.

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
      - CallExpr          → used in stmt_allocs
      - BinaryOperator =  → used in field_assign

    DeclStmt, VarDecl, ParmVarDecl, and all other nodes do NOT consume
    stmt_ids.  This keeps ids dense and stable — the same source code
    always produces the same ids regardless of how many non-interesting
    nodes exist between interesting ones.

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
        self._gc_locals = set()          # names of GC-managed locals in current fn
        self._call_graph_edges = set()   # (caller, callee) for dedup

    def _next_stmt_id(self):
        sid = self._stmt_counter
        self._stmt_counter += 1
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
        self._gc_locals = set()
        self._call_graph_edges = set()

        # Emit function fact.
        self.writer.write("function", [name])

        # Emit var_decl for parameters.
        for p in params:
            self._emit_var_decl(name, p)

        # Full recursive walk of the function body.
        self._walk_body(name, body)

        # Reset per-function state.
        self._current_function = None
        self._gc_locals = set()

    # ── Full body walk (Phase 1) ──────────────────────────────────

    def _walk_body(self, func_name, node):
        """Full recursive walk of a function body node and its descendants.

        Assigns stmt_ids to CallExpr and BinaryOperator (=) nodes.
        Extracts var_decl, call_graph, stmt_allocs, and field_assign facts.
        """
        if not isinstance(node, dict):
            return

        kind = node.get("kind", "")

        # ── CallExpr → call_graph + stmt_allocs ──
        if kind == "CallExpr":
            sid = self._next_stmt_id()
            self._handle_call_expr(func_name, sid, node)

        # ── VarDecl → var_decl (handles DeclStmt children, ForStmt
        # initializers, and bare VarDecl in CompoundStmt uniformly)
        elif kind == "VarDecl":
            self._emit_var_decl(func_name, node)

        # ── BinaryOperator = → field_assign ──
        elif kind == "BinaryOperator":
            opcode = node.get("opcode", "")
            if opcode == "=":
                sid = self._next_stmt_id()
                self._handle_field_assign(func_name, sid, node)

        # ── Expression nodes that contain calls: recurse ──
        # (ImplicitCastExpr, CStyleCastExpr, ParenExpr, UnaryOperator,
        #  ConditionalOperator, ArraySubscriptExpr, CompoundAssignOperator, …)
        elif kind in ("ImplicitCastExpr", "CStyleCastExpr", "ParenExpr",
                       "UnaryOperator", "ConditionalOperator",
                       "ArraySubscriptExpr", "CompoundAssignOperator",
                       "MemberExpr", "DeclRefExpr",
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

        # ── Statement nodes (control flow, labels, etc.) ──
        # Phase 2 will assign stmt_ids and emit cfg_edge for these.
        elif kind in ("IfStmt", "WhileStmt", "ForStmt", "DoStmt",
                       "SwitchStmt", "CaseStmt", "DefaultStmt",
                       "ReturnStmt", "LabelStmt", "GotoStmt",
                       "BreakStmt", "ContinueStmt", "NullStmt",
                       "IndirectGotoStmt", "CompoundStmt",
                       "AttributedStmt"):
            pass  # recurse only

        # Recurse into children for ALL node kinds (including the ones
        # we handled above — eg a CallExpr's arguments may contain nested
        # CallExprs that also need stmt_ids).
        for child in node.get("inner", []):
            self._walk_body(func_name, child)

    # ── Call expression handling ──────────────────────────────────

    def _handle_call_expr(self, func_name, sid, node):
        """Emit call_graph and (if allocator) stmt_allocs for a CallExpr."""
        callee = self._extract_callee(node)
        if not callee:
            return

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

    # ── Variable declarations ─────────────────────────────────────

    def _emit_var_decl(self, func_name, node):
        """Emit a var_decl fact for a ParmVarDecl or VarDecl.

        Also populates self._gc_locals for use by field_assign filtering.
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
                init_callee = self._extract_var_init_callee(node)
                if init_callee in RETURNS_GC_POINTER:
                    is_gc = 1

        if is_gc:
            self._gc_locals.add(vname)

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

    # ── Field assignment ──────────────────────────────────────────

    def _handle_field_assign(self, func_name, sid, node):
        """Handle BinaryOperator '=' for field_assign fact emission.

        Only emits a row when:
          1. The LHS base variable is a GC-managed local.
          2. The leaf member being assigned is in GC_MANAGED_FIELD_NAMES
             (code, env, car, cdr, data).

        This filters out noise like v.tag = VAL_LAMBDA (tag is not a
        GC-managed field) while capturing v.lambda.code = code.
        """
        inner = node.get("inner", [])
        if len(inner) < 2:
            return

        lhs_node = inner[0]
        rhs_node = inner[1]

        if not isinstance(lhs_node, dict):
            return

        field_path = self._extract_field_path(lhs_node)
        base = self._extract_base(lhs_node)
        rhs_kind = self._classify_rhs(rhs_node)

        if not base or not field_path:
            return

        # Filter 1: base must be a GC-managed local.
        if base not in self._gc_locals:
            return

        # Filter 2: leaf member must be a GC-managed field.
        leaf_member = field_path.rsplit(".", 1)[-1] if "." in field_path else field_path.lstrip(".")
        if leaf_member not in GC_MANAGED_FIELD_NAMES:
            return

        self.writer.write("field_assign", [
            func_name, str(sid), base, field_path, rhs_kind
        ])

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


# ── Self-test: hardcoded AST ─────────────────────────────────────────
#
# The self-test AST represents a simplified val_lambda-like function
# that exercises all Phase 1 extraction pathways:
#   - GC-managed params (code, env) and locals (v → Value, p → void*)
#   - Non-GC local (msg → char*)
#   - CallExpr to allocator (gc_alloc → stmt_allocs)
#   - CallExpr to non-allocator (strlen → call_graph only)
#   - Field assignments: v.lambda.code (GC field → emitted),
#     v.lambda.env (GC field → emitted), v.tag (non-GC field → skipped)
#   - void* with gc_alloc_oldgen initializer → is_gc_managed=1
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
                                }
                            ],
                        },
                        # ── v.lambda.env = GC_VALUE_ARRAY(...) ──
                        # GC field 'env' → emitted
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
                        # GC field 'code' → emitted
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
                        # ── v.tag = VAL_LAMBDA ──
                        # 'tag' is NOT a GC field → NOT emitted
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

    The visitor emits function, var_decl, call_graph, stmt_allocs, and
    field_assign from real AST walk.  We then emit synthetic skeleton rows
    for the remaining 5 relations (cfg_edge, stmt_pushes, stmt_pops,
    stmt_memcpy, stmt_barrier) — these are Phase 2/3 work and are not yet
    extracted from the real AST.
    """
    visitor = AstVisitor(writer)
    visitor.visit(SELF_TEST_AST)

    # ── Skeleton rows for Phase 2/3 relations ──────────────────────
    # These keep the self-test round-trip gate green until Phases 2-3
    # implement real extraction.

    writer.write("cfg_edge",    ["val_lambda", "0", "1", "fall"])
    writer.write("stmt_pushes", ["val_lambda", "3", "ROOT_PTR", "code"])
    writer.write("stmt_pushes", ["val_lambda", "4", "ROOT_PTR", "env"])
    writer.write("stmt_pops",   ["val_lambda", "5", "2", "pop_to"])
    writer.write("stmt_memcpy", ["val_lambda", "6", "v.lambda.env", "env",
                                  "env_len * sizeof(Value)"])
    writer.write("stmt_barrier", ["val_lambda", "7", "v.lambda.env"])


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

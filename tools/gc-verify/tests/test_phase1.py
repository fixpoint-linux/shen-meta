#!/usr/bin/env python3
"""test_phase1.py — Phase 1 extraction quality tests for gc-verify.

Validates the Phase 1 extractor behaviour:
  1. Synthetic AST → correct var_decl (GC vs non-GC types, void* heuristic).
  2. Synthetic AST → stmt_allocs only for allocator calls (not libc).
  3. Synthetic AST → field_assign only for GC-managed fields.
  4. Synthetic AST → function filtering (no-body decls excluded).
  5. extract.py --help exits 0.

Runs WITHOUT clang or souffle — pure Python stdlib + unittest.
"""

import csv
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TOOLS_DIR = PROJECT_ROOT / "tools" / "gc-verify"
EXTRACT_PY = TOOLS_DIR / "extract.py"

# Add tools/gc-verify to sys.path so we can import extract directly.
sys.path.insert(0, str(TOOLS_DIR))
import extract


def _run_extract(args):
    """Run extract.py with given args, return (returncode, stdout, stderr)."""
    proc = subprocess.run(
        [sys.executable, str(EXTRACT_PY)] + args,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _run_visitor_on_ast(ast_dict):
    """Run the AstVisitor on a synthetic AST dict, return parsed CSVs.

    Returns a dict: relation_name → list of row dicts keyed by column name.
    """
    with tempfile.TemporaryDirectory(prefix="gc-verify-phase1-") as tmp:
        writer = extract.FactWriter(tmp)
        visitor = extract.AstVisitor(writer)
        visitor.visit(ast_dict)
        writer.close()

        result = {}
        for rel in extract.CSV_SCHEMAS:
            path = Path(tmp) / f"{rel}.csv"
            rows = []
            with open(path, "r", newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(dict(row))
            result[rel] = rows
        return result


# ── Minimal synthetic AST for Phase 1 assertions ──────────────────

SYNTHETIC_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        # A function with a body (should be emitted).
        {
            "kind": "FunctionDecl",
            "name": "test_fn",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "arg",
                    "type": {"qualType": "int"},
                },
                {
                    "kind": "CompoundStmt",
                    "inner": [
                        # ── GC-managed local: Value val ──
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "val",
                                    "type": {"qualType": "struct Value"},
                                }
                            ],
                        },
                        # ── Non-GC local: char *name ──
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "name",
                                    "type": {"qualType": "char *"},
                                }
                            ],
                        },
                        # ── void* local with gc_alloc init → GC-managed ──
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "ptr",
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
                        # ── gc_alloc call (IS an allocator) ──
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
                        # ── strlen call (libc, NOT an allocator) ──
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "strlen",
                                            },
                                        }
                                    ],
                                }
                            ],
                        },
                        # ── val.code = ... (GC field 'code') → emitted ──
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                {
                                    "kind": "MemberExpr",
                                    "name": "code",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "val"},
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "arg"},
                                },
                            ],
                        },
                        # ── val.tag = 42 (non-GC field 'tag') → NOT emitted ──
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
                                            "referencedDecl": {"name": "val"},
                                        }
                                    ],
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "42",
                                },
                            ],
                        },
                    ],
                },
            ],
        },
        # A function without a body (header decl) — should NOT be emitted.
        {
            "kind": "FunctionDecl",
            "name": "external_libc_fn",
            "type": {"qualType": "int (const char *)"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "s",
                    "type": {"qualType": "const char *"},
                },
            ],
        },
    ],
}


class TestPhase1(unittest.TestCase):
    """Phase 1 extraction quality tests."""

    @classmethod
    def setUpClass(cls):
        """Run the visitor on the synthetic AST once."""
        cls.results = _run_visitor_on_ast(SYNTHETIC_AST)

    # ── function.csv ──────────────────────────────────────────────

    def test_function_only_emits_body_functions(self):
        """Only test_fn (has body) is in function.csv; external_libc_fn is not."""
        names = {r["name"] for r in self.results["function"]}
        self.assertIn("test_fn", names,
                      "test_fn (has body) should be in function.csv")
        self.assertNotIn("external_libc_fn", names,
                         "external_libc_fn (no body) should NOT be in function.csv")

    # ── var_decl.csv ──────────────────────────────────────────────

    def test_var_decl_gc_types(self):
        """Value and Instr* locals are GC-managed, int and char* are not."""
        vd = {r["name"]: r for r in self.results["var_decl"] if r["f"] == "test_fn"}

        # arg: int → is_gc_managed=0
        self.assertIn("arg", vd)
        self.assertEqual(vd["arg"]["is_gc_managed"], "0",
                         "int param should not be GC-managed")

        # val: Value → is_gc_managed=1
        self.assertIn("val", vd)
        self.assertEqual(vd["val"]["is_gc_managed"], "1",
                         "Value local should be GC-managed")
        # Also check normalized type name
        self.assertIn(vd["val"]["type"], ("Value", "struct Value"),
                      f"Expected Value type, got {vd['val']['type']}")

        # name: char* → is_gc_managed=0
        self.assertIn("name", vd)
        self.assertEqual(vd["name"]["is_gc_managed"], "0",
                         "char* local should NOT be GC-managed")

    def test_var_decl_void_star_heuristic(self):
        """void* initialized with gc_alloc → is_gc_managed=1."""
        vd = {r["name"]: r for r in self.results["var_decl"] if r["f"] == "test_fn"}

        self.assertIn("ptr", vd,
                      "ptr (void* with gc_alloc init) should be in var_decl")
        self.assertEqual(vd["ptr"]["is_gc_managed"], "1",
                         "void* with gc_alloc init should be GC-managed")
        self.assertEqual(vd["ptr"]["type"], "void*")

    def test_var_decl_only_has_test_fn(self):
        """external_libc_fn params should NOT appear in var_decl."""
        vd_fns = {r["f"] for r in self.results["var_decl"]}
        self.assertNotIn("external_libc_fn", vd_fns,
                         "No-body function should not produce var_decl rows")

    # ── stmt_allocs.csv ───────────────────────────────────────────

    def test_stmt_allocs_has_gc_alloc(self):
        """gc_alloc call → stmt_allocs row."""
        allocs = [r for r in self.results["stmt_allocs"] if r["f"] == "test_fn"]
        callees = {r["callee"] for r in allocs}
        self.assertIn("gc_alloc", callees,
                      "gc_alloc call should produce stmt_allocs row")

    def test_stmt_allocs_excludes_libc(self):
        """strlen call does NOT create a stmt_allocs row."""
        allocs = [r for r in self.results["stmt_allocs"] if r["f"] == "test_fn"]
        callees = {r["callee"] for r in allocs}
        self.assertNotIn("strlen", callees,
                         "strlen (libc, not an allocator) should NOT be in stmt_allocs")
        self.assertNotIn("memset", callees,
                         "memset should NOT be in stmt_allocs")

    def test_stmt_allocs_stable_ids(self):
        """stmt_allocs rows have stable integer stmt_ids."""
        allocs = [r for r in self.results["stmt_allocs"] if r["f"] == "test_fn"]
        self.assertGreater(len(allocs), 0)
        for row in allocs:
            # stmt_id should be a parseable integer
            int(row["stmt_id"])
            self.assertTrue(row["stmt_id"].isdigit())

    # ── call_graph.csv ────────────────────────────────────────────

    def test_call_graph_has_all_calls(self):
        """call_graph includes both allocator and libc calls."""
        edges = [(r["caller"], r["callee"]) for r in self.results["call_graph"]
                 if r["caller"] == "test_fn"]
        callees = {c for _, c in edges}
        self.assertIn("gc_alloc", callees,
                      "gc_alloc should be in call_graph")
        self.assertIn("strlen", callees,
                      "strlen should be in call_graph (libc calls included)")

    def test_call_graph_no_duplicates(self):
        """call_graph edges are deduplicated."""
        edges = [(r["caller"], r["callee"]) for r in self.results["call_graph"]
                 if r["caller"] == "test_fn" and r["callee"] == "gc_alloc"]
        self.assertEqual(len(edges), 1,
                         f"Expected 1 (test_fn, gc_alloc) edge, got {len(edges)}")

    # ── field_assign.csv ──────────────────────────────────────────

    def test_field_assign_gc_field(self):
        """val.code = arg (GC field 'code') → emitted."""
        fa = [r for r in self.results["field_assign"] if r["f"] == "test_fn"]
        bases = {r["base"]: r for r in fa}
        self.assertIn("val", bases,
                      "val.code assignment should be in field_assign")
        self.assertIn("code", bases["val"]["field_path"],
                      "field_path should contain 'code'")

    def test_field_assign_excludes_non_gc_field(self):
        """val.tag = 42 (non-GC field 'tag') → NOT emitted."""
        fa = [r for r in self.results["field_assign"] if r["f"] == "test_fn"]
        # 'tag' should not appear in any field_path
        for row in fa:
            self.assertNotIn(".tag", row["field_path"],
                             f"val.tag (non-GC field) should not appear: {row}")

    # ── Schema completeness ───────────────────────────────────────

    def test_all_10_schemas_present(self):
        """All 10 CSV relations have at least a header row."""
        for rel in extract.CSV_SCHEMAS:
            self.assertIn(rel, self.results,
                          f"Missing CSV relation: {rel}")

    # ── CLI behaviour ─────────────────────────────────────────────

    def test_help_exits_zero(self):
        """extract.py --help exits with code 0."""
        rc, stdout, stderr = _run_extract(["--help"])
        self.assertEqual(rc, 0, f"--help exited {rc}: {stderr}")
        self.assertIn("usage:", stdout.lower() or stderr.lower())


if __name__ == "__main__":
    unittest.main()

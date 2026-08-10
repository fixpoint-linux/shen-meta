#!/usr/bin/env python3
"""test_phase3.py — Phase 3 memcpy_unbarriered tests for gc-verify.

Validates:
  1. Extractor emits stmt_memcpy for memcpy into GC-managed dst.
  2. Extractor does NOT emit stmt_memcpy for non-GC dst (char*).
  3. Extractor emits stmt_barrier for gc_dirty_vectors_add.
  4. No call_graph edges to memcpy or gc_dirty_vectors_add.
  5. _extract_var_from_arg normalises *env and &env to env.
  6. --self-test produces ≥1 stmt_memcpy + ≥1 stmt_barrier row.
  7. Mini-simulator: reach_stmt, barrier_covers_alloc, memcpy_unbarriered.
  8. All existing Phase 0/1/2 tests still pass.

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
    with tempfile.TemporaryDirectory(prefix="gc-verify-phase3-") as tmp:
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


# ══════════════════════════════════════════════════════════════════════════
# Python mini-simulator of the Phase 3 Datalog rules
# ══════════════════════════════════════════════════════════════════════════

def _compute_reach_stmt(next_stmt_rows):
    """Compute reach_stmt(f, from, to) — transitive closure over next_stmt.

    Returns set of (f, from, to) tuples.
    """
    nexts = {}   # (f, from) → set of direct successors
    for r in next_stmt_rows:
        key = (r["f"], int(r["from"]))
        nexts.setdefault(key, set()).add(int(r["to"]))

    reach = set()
    # Base: direct edges.
    for r in next_stmt_rows:
        reach.add((r["f"], int(r["from"]), int(r["to"])))

    # Fixpoint: transitive closure.
    changed = True
    while changed:
        changed = False
        new_reach = set(reach)
        for (f, a, b) in reach:
            for c in nexts.get((f, b), set()):
                entry = (f, a, c)
                if entry not in new_reach:
                    new_reach.add(entry)
                    changed = True
        reach = new_reach

    return reach


def _compute_barrier_covers(
    stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach_set
):
    """Compute barrier_covers_alloc from the relations.

    Returns set of (f, s_memcpy, dst, s_alloc) tuples.
    """
    covers = set()
    for m in stmt_memcpy_rows:
        f = m["f"]
        mem_sid = int(m["stmt_id"])
        dst = m["dst_expr"]
        for b in stmt_barrier_rows:
            if b["f"] != f:
                continue
            if b["target_expr"] != dst:
                continue
            bar_sid = int(b["stmt_id"])
            for a in stmt_allocs_rows:
                if a["f"] != f:
                    continue
                alloc_sid = int(a["stmt_id"])
                if ((f, mem_sid, bar_sid) in reach_set and
                        (f, bar_sid, alloc_sid) in reach_set):
                    covers.add((f, mem_sid, dst, alloc_sid))
    return covers


def _compute_memcpy_unbarriered(
    stmt_memcpy_rows, stmt_allocs_rows, reach_set, covers_set
):
    """Compute memcpy_unbarriered from the relations.

    Returns set of (f, stmt_id, dst_expr) tuples.
    """
    unbarriered = set()
    for m in stmt_memcpy_rows:
        f = m["f"]
        mem_sid = int(m["stmt_id"])
        dst = m["dst_expr"]
        for a in stmt_allocs_rows:
            if a["f"] != f:
                continue
            alloc_sid = int(a["stmt_id"])
            if (f, mem_sid, alloc_sid) not in reach_set:
                continue
            if (f, mem_sid, dst, alloc_sid) not in covers_set:
                unbarriered.add((f, mem_sid, dst))
    return unbarriered


# ══════════════════════════════════════════════════════════════════════════
# Synthetic ASTs for Phase 3 extraction tests
# ══════════════════════════════════════════════════════════════════════════

# AST: memcpy into GC Value* v → one stmt_memcpy row.
MEMCPY_GC_DST_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_memcpy_gc",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "v",
                    "type": {"qualType": "struct Value *"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "src",
                    "type": {"qualType": "struct Value *"},
                },
                {
                    "kind": "CompoundStmt",
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
                                                "name": "memcpy",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "v"},
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "src"},
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "16",
                                },
                            ],
                        },
                    ],
                },
            ],
        },
    ],
}

# AST: memcpy into char* buf → zero stmt_memcpy rows (non-GC dst).
MEMCPY_CHAR_DST_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_memcpy_char",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "buf",
                    "type": {"qualType": "char *"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "msg",
                    "type": {"qualType": "const char *"},
                },
                {
                    "kind": "CompoundStmt",
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
                                                "name": "memcpy",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "buf"},
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "msg"},
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "10",
                                },
                            ],
                        },
                    ],
                },
            ],
        },
    ],
}

# AST: gc_dirty_vectors_add(v) → one stmt_barrier row.
BARRIER_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_barrier",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "v",
                    "type": {"qualType": "struct Value *"},
                },
                {
                    "kind": "CompoundStmt",
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
                                                "name": "gc_dirty_vectors_add",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "v"},
                                },
                            ],
                        },
                    ],
                },
            ],
        },
    ],
}

# AST: memcpy(*env, ...) + gc_dirty_vectors_add(*env) → both normalize to 'env'.
DEREF_NORM_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_deref",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "env",
                    "type": {"qualType": "struct Value *"},
                },
                {
                    "kind": "CompoundStmt",
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
                                                "name": "memcpy",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "UnaryOperator",
                                    "opcode": "*",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "env",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "env"},
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "8",
                                },
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
                                                "name": "gc_dirty_vectors_add",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "UnaryOperator",
                                    "opcode": "*",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "env",
                                            },
                                        }
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
        },
    ],
}


# ══════════════════════════════════════════════════════════════════════════
# Test cases
# ══════════════════════════════════════════════════════════════════════════

class TestPhase3Extraction(unittest.TestCase):
    """Phase 3 extractor behaviour tests."""

    # ── stmt_memcpy extraction ────────────────────────────────────────

    def test_01_memcpy_into_gc_value_ptr(self):
        """memcpy into GC Value* v → one stmt_memcpy row with dst=v."""
        results = _run_visitor_on_ast(MEMCPY_GC_DST_AST)
        memcpys = results["stmt_memcpy"]
        self.assertEqual(len(memcpys), 1,
                         f"Expected 1 stmt_memcpy, got {len(memcpys)}")
        self.assertEqual(memcpys[0]["dst_expr"], "v")
        self.assertEqual(memcpys[0]["src_expr"], "src")
        self.assertEqual(memcpys[0]["nbytes"], "16")

    def test_02_memcpy_into_char_ptr_zero_rows(self):
        """memcpy into char* buf → zero stmt_memcpy rows (non-GC dst)."""
        results = _run_visitor_on_ast(MEMCPY_CHAR_DST_AST)
        memcpys = results["stmt_memcpy"]
        self.assertEqual(len(memcpys), 0,
                         f"Expected 0 stmt_memcpy for char* dst, got {len(memcpys)}")

    # ── stmt_barrier extraction ──────────────────────────────────────

    def test_03_gc_dirty_vectors_add_emits_barrier(self):
        """gc_dirty_vectors_add(v) → one stmt_barrier row with target=v."""
        results = _run_visitor_on_ast(BARRIER_AST)
        barriers = results["stmt_barrier"]
        self.assertEqual(len(barriers), 1,
                         f"Expected 1 stmt_barrier, got {len(barriers)}")
        self.assertEqual(barriers[0]["target_expr"], "v")
        self.assertEqual(barriers[0]["f"], "test_barrier")

    # ── call_graph filtering ─────────────────────────────────────────

    def test_04_no_call_graph_edge_to_barrier(self):
        """No call_graph edge to gc_dirty_vectors_add (it's intercepted)."""
        results = _run_visitor_on_ast(BARRIER_AST)
        cg = results["call_graph"]
        barrier_edges = [r for r in cg if r["callee"] == "gc_dirty_vectors_add"]
        self.assertEqual(len(barrier_edges), 0,
                         "No call_graph edge to gc_dirty_vectors_add expected")

    def test_05_no_call_graph_edge_to_memcpy(self):
        """No call_graph edge to memcpy (it's intercepted)."""
        results = _run_visitor_on_ast(MEMCPY_GC_DST_AST)
        cg = results["call_graph"]
        memcpy_edges = [r for r in cg if r["callee"] == "memcpy"]
        self.assertEqual(len(memcpy_edges), 0,
                         "No call_graph edge to memcpy expected")

    # ── Dereference normalisation ────────────────────────────────────

    def test_06_deref_normalises_to_var_name(self):
        """memcpy(*env, ...) and gc_dirty_vectors_add(*env) both normalise to env."""
        results = _run_visitor_on_ast(DEREF_NORM_AST)
        memcpys = results["stmt_memcpy"]
        self.assertGreaterEqual(len(memcpys), 1,
                                "Expected stmt_memcpy for memcpy(*env, ...)")
        self.assertEqual(memcpys[0]["dst_expr"], "env",
                         "*env in memcpy dst should normalise to 'env'")
        barriers = results["stmt_barrier"]
        self.assertGreaterEqual(len(barriers), 1,
                                "Expected stmt_barrier for gc_dirty_vectors_add(*env)")
        self.assertEqual(barriers[0]["target_expr"], "env",
                         "*env in barrier target should normalise to 'env'")

    # ── Self-test produces real rows ─────────────────────────────────

    def test_07_self_test_produces_stmt_memcpy_and_barrier(self):
        """--self-test produces ≥1 stmt_memcpy + ≥1 stmt_barrier row."""
        rc, stdout, stderr = _run_extract(["--self-test",
                                            "--out-dir", "/tmp/gc-verify-p3-test"])
        self.assertEqual(rc, 0, f"--self-test failed: {stderr}")

        memcpy_path = Path("/tmp/gc-verify-p3-test") / "stmt_memcpy.csv"
        self.assertTrue(memcpy_path.exists(), "Missing stmt_memcpy.csv")
        with open(memcpy_path, "r") as f:
            rows = list(csv.DictReader(f))
        self.assertGreaterEqual(len(rows), 1,
                                f"Expected ≥1 stmt_memcpy row, got {len(rows)}")
        # The dst should be 'new_env' (the Value* from self-test AST;
        # void* 'p' is no longer emitted — suppressed by Fix 1
        # BARRIER_RELEVANT_TYPES filtering).
        dsts = {r["dst_expr"] for r in rows}
        self.assertIn("new_env", dsts,
                      f"Expected stmt_memcpy with dst='new_env', got dsts={dsts}")

        barrier_path = Path("/tmp/gc-verify-p3-test") / "stmt_barrier.csv"
        self.assertTrue(barrier_path.exists(), "Missing stmt_barrier.csv")
        with open(barrier_path, "r") as f:
            rows = list(csv.DictReader(f))
        self.assertGreaterEqual(len(rows), 1,
                                f"Expected ≥1 stmt_barrier row, got {len(rows)}")
        targets = {r["target_expr"] for r in rows}
        self.assertTrue("p" in targets or "new_env" in targets,
                        f"Expected stmt_barrier with target='p' or 'new_env', got targets={targets}")

        # stmt_memcpy row should no longer have the old skeleton value "99".
        memcpy_ids = {r["stmt_id"] for r in rows}
        self.assertNotIn("99", memcpy_ids,
                         "No skeleton stmt_memcpy with stmt_id=99 expected")


class TestPhase3Analysis(unittest.TestCase):
    """Phase 3 analysis logic tests (Python mini-simulator).

    Validates that the Python ports of reach_stmt, barrier_covers_alloc,
    and memcpy_unbarriered produce the same results as gc_safety.dl.
    """

    def test_08_memcpy_no_barrier_fires(self):
        """memcpy@0 dst=new_env, alloc@2, no barrier → fires."""
        stmt_memcpy_rows = [
            {"f": "buggy", "stmt_id": "0", "dst_expr": "new_env",
             "src_expr": "src_env", "nbytes": ""},
        ]
        stmt_barrier_rows = []  # no barrier!
        stmt_allocs_rows = [
            {"f": "buggy", "stmt_id": "2", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "buggy", "from": "0", "to": "1"},
            {"f": "buggy", "from": "1", "to": "2"},
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        self.assertIn(("buggy", 0, 2), reach,
                      "reach_stmt: 0→2 via 1 should hold")
        self.assertEqual(len(covers), 0,
                         "No barrier → no barrier_covers_alloc")
        self.assertIn(("buggy", 0, "new_env"), unbarriered,
                      "memcpy_unbarriered should fire for unbarriered memcpy")

    def test_09_barrier_between_memcpy_and_alloc_no_fire(self):
        """memcpy@0, barrier@1 target=new_env, alloc@2 → no fire."""
        stmt_memcpy_rows = [
            {"f": "correct", "stmt_id": "0", "dst_expr": "new_env",
             "src_expr": "src_env", "nbytes": ""},
        ]
        stmt_barrier_rows = [
            {"f": "correct", "stmt_id": "1", "target_expr": "new_env"},
        ]
        stmt_allocs_rows = [
            {"f": "correct", "stmt_id": "2", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "correct", "from": "0", "to": "1"},
            {"f": "correct", "from": "1", "to": "2"},
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        self.assertIn(("correct", 0, "new_env", 2), covers,
                      "barrier between memcpy and alloc should cover")
        self.assertEqual(len(unbarriered), 0,
                         f"Expected no unbarriered memcpy, got {unbarriered}")

    def test_10_barrier_wrong_target_fires(self):
        """memcpy dst=new_env, barrier target=other_env, alloc between → fires."""
        stmt_memcpy_rows = [
            {"f": "wrong", "stmt_id": "0", "dst_expr": "new_env",
             "src_expr": "src_env", "nbytes": ""},
        ]
        stmt_barrier_rows = [
            {"f": "wrong", "stmt_id": "1", "target_expr": "other_env"},
        ]
        stmt_allocs_rows = [
            {"f": "wrong", "stmt_id": "2", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "wrong", "from": "0", "to": "1"},
            {"f": "wrong", "from": "1", "to": "2"},
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        self.assertEqual(len(covers), 0,
                         "Barrier for wrong target → no cover")
        self.assertIn(("wrong", 0, "new_env"), unbarriered,
                      "memcpy_unbarriered should fire (barrier wrong target)")

    def test_11_barrier_too_late_fires(self):
        """memcpy@0, alloc@1, barrier@2 → fires (barrier AFTER alloc)."""
        stmt_memcpy_rows = [
            {"f": "late", "stmt_id": "0", "dst_expr": "new_env",
             "src_expr": "src_env", "nbytes": ""},
        ]
        stmt_barrier_rows = [
            {"f": "late", "stmt_id": "2", "target_expr": "new_env"},
        ]
        stmt_allocs_rows = [
            {"f": "late", "stmt_id": "1", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "late", "from": "0", "to": "1"},
            {"f": "late", "from": "1", "to": "2"},
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        # reach_stmt(0,1) is true (alloc follows memcpy), but barrier at 2
        # is after alloc at 1.  barrier_covers_alloc requires reach(barrier→alloc),
        # i.e. reach_stmt(2,1), which is NOT true. So no cover.
        self.assertEqual(len(covers), 0,
                         "Barrier after alloc → no cover (reach(barrier→alloc) false)")
        # memcpy_unbarriered fires because reach_stmt(memcpy→alloc) is true
        # and no barrier_covers_alloc covers this (barrier,alloc) pair.
        self.assertIn(("late", 0, "new_env"), unbarriered,
                      "memcpy_unbarriered should fire (barrier too late)")

    def test_12_barrier_with_no_alloc_after_no_fire(self):
        """memcpy@0, barrier@1, no alloc after → no fire (no alloc reachable)."""
        stmt_memcpy_rows = [
            {"f": "noalloc", "stmt_id": "0", "dst_expr": "new_env",
             "src_expr": "src_env", "nbytes": ""},
        ]
        stmt_barrier_rows = [
            {"f": "noalloc", "stmt_id": "1", "target_expr": "new_env"},
        ]
        stmt_allocs_rows = [
            # alloc at stmt_id=5, NOT reachable from 0→1 (only 0→1 edge exists)
            {"f": "noalloc", "stmt_id": "5", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "noalloc", "from": "0", "to": "1"},
            # No edge from 1 to 5 → alloc unreachable from memcpy
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        # reach_stmt(memcpy→alloc) is false (no path 0→5)
        self.assertNotIn(("noalloc", 0, 5), reach,
                         "alloc at 5 should not be reachable from memcpy at 0")
        self.assertEqual(len(unbarriered), 0,
                         "No unbarriered memcpy: alloc not reachable from memcpy")

    # ── Regression: existing tests still pass ────────────────────────

    def test_13_existing_phase0_tests_pass(self):
        """All Phase 0 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase0.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase0.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_14_existing_phase1_tests_pass(self):
        """All Phase 1 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase1.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase1.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_15_existing_phase2_tests_pass(self):
        """All Phase 2 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase2.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase2.py failed:\n{proc.stderr}\n{proc.stdout}")


if __name__ == "__main__":
    unittest.main()

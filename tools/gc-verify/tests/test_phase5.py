#!/usr/bin/env python3
"""test_phase5.py — Phase 5 calibration tests for gc-verify.

Validates:
  1. BARRIER_RELEVANT_TYPES filtering: Instr* dst → no stmt_memcpy.
  2. fresh_target emitted / withheld for positive / negative controls.
  3. defining_alloc emitted / withheld.
  4. _gc_local_types + _alloc_defined_var populated by extraction.
  5. CaseStmt-scoped next_stmt edges (cross-case vars don't propagate).
  6. Mini-simulators: defining_alloc-aware root_miss, fresh_target-aware
     memcpy_unbarriered, BB-tagged next_stmt.
  7. All existing Phase 0/1/2/3 tests still pass.

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
    with tempfile.TemporaryDirectory(prefix="gc-verify-phase5-") as tmp:
        writer = extract.FactWriter(tmp)
        visitor = extract.AstVisitor(writer)
        visitor.visit(ast_dict)
        writer.close()

        result = {}
        for rel in extract.CSV_SCHEMAS:
            path = Path(tmp) / f"{rel}.csv"
            rows = []
            if path.exists():
                with open(path, "r", newline="") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        rows.append(dict(row))
            result[rel] = rows
        return result


# ══════════════════════════════════════════════════════════════════════════
# Python mini-simulators of the Phase 5 Datalog rules
# ══════════════════════════════════════════════════════════════════════════

def _compute_reach_stmt(next_stmt_rows):
    """Compute reach_stmt(f, from, to) — transitive closure over next_stmt."""
    nexts = {}
    for r in next_stmt_rows:
        key = (r["f"], int(r["from"]))
        nexts.setdefault(key, set()).add(int(r["to"]))

    reach = set()
    for r in next_stmt_rows:
        reach.add((r["f"], int(r["from"]), int(r["to"])))

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


def _compute_live_at(gc_use_rows, gc_def_rows, next_stmt_rows):
    """Compute live_at(f, v, s)."""
    uses = {}
    defs = {}
    nexts = {}

    for r in gc_use_rows:
        key = (r["f"], r["v"])
        uses.setdefault(key, set()).add(int(r["stmt_id"]))
    for r in gc_def_rows:
        key = (r["f"], r["v"])
        defs.setdefault(key, set()).add(int(r["stmt_id"]))
    for r in next_stmt_rows:
        nexts[(r["f"], int(r["from"]))] = int(r["to"])

    live = set()
    for (f, v), stmts in uses.items():
        for s in stmts:
            live.add((f, v, s))

    changed = True
    while changed:
        changed = False
        new_live = set(live)
        for (f, v, s_next) in list(live):
            for (ff, fr), to in nexts.items():
                if ff == f and to == s_next:
                    s = fr
                    killed = (f, v) in defs and s in defs[(f, v)]
                    if not killed:
                        entry = (f, v, s)
                        if entry not in new_live:
                            new_live.add(entry)
                            changed = True
        live = new_live
    return live


def _compute_pushed_may(stmt_pushes_rows, stmt_pops_rows, next_stmt_rows):
    """Compute pushed_may(f, v, s)."""
    pushes = {}
    pop_tos = {}
    nexts = {}

    for r in stmt_pushes_rows:
        key = (r["f"], r["slot_expr"])
        pushes.setdefault(key, set()).add(int(r["stmt_id"]))
    for r in stmt_pops_rows:
        if r.get("pkind") == "pop_to":
            key = (r["f"],)
            pop_tos.setdefault(key, set()).add(int(r["stmt_id"]))
    for r in next_stmt_rows:
        nexts[(r["f"], int(r["from"]))] = int(r["to"])

    pm = set()
    for (f, v), stmts in pushes.items():
        for s in stmts:
            pm.add((f, v, s))

    changed = True
    while changed:
        changed = False
        new_pm = set(pm)
        for (f, v, s) in list(pm):
            to = nexts.get((f, s))
            if to is not None:
                blocked = (f,) in pop_tos and s in pop_tos[(f,)]
                if not blocked:
                    entry = (f, v, to)
                    if entry not in new_pm:
                        new_pm.add(entry)
                        changed = True
        pm = new_pm
    return pm


def _compute_root_miss(
    live_at_set, pushed_may_set, stmt_allocs_rows, var_decl_rows,
    defining_alloc_rows=None,
):
    """Compute root_miss(f, s, v), with Phase 5 defining_alloc suppression."""
    gc_vars = set()
    for r in var_decl_rows:
        if r.get("is_gc_managed") == "1":
            gc_vars.add((r["f"], r["name"]))

    alloc_sites = set()
    for r in stmt_allocs_rows:
        alloc_sites.add((r["f"], int(r["stmt_id"])))

    # Phase 5: defining_alloc set for suppression.
    def_allocs = set()
    if defining_alloc_rows:
        for r in defining_alloc_rows:
            def_allocs.add((r["f"], r["var"], int(r["stmt_id"])))

    rms = set()
    for (f, v, s) in live_at_set:
        if (f, v) in gc_vars and (f, s) in alloc_sites:
            if (f, v, s) not in pushed_may_set:
                if (f, v, s) not in def_allocs:
                    rms.add((f, s, v))
    return rms


def _compute_barrier_covers(
    stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach_set
):
    """Compute barrier_covers_alloc."""
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
    stmt_memcpy_rows, stmt_allocs_rows, reach_set, covers_set,
):
    """Compute memcpy_unbarriered (no fresh_target — dropped as unsound)."""
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
# Synthetic ASTs for Phase 5 extraction tests
# ══════════════════════════════════════════════════════════════════════════

# AST: Instr *code = gc_alloc(...); memcpy(code, ...);
# Fix 1: Instr* is NOT barrier-relevant → no stmt_memcpy row.
INSTR_MEMCPY_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_instr_memcpy",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "src",
                    "type": {"qualType": "struct Instr *"},
                },
                {
                    "kind": "CompoundStmt",
                    "inner": [
                        # Instr *code = gc_alloc(...)
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "code",
                                    "type": {"qualType": "struct Instr *"},
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
                        # memcpy(code, src, ...)
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
                                    "referencedDecl": {"name": "code"},
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "src"},
                                },
                                {
                                    "kind": "IntegerLiteral",
                                    "value": "32",
                                },
                            ],
                        },
                    ],
                },
            ],
        },
    ],
}

# AST: Value *e = gc_alloc(...); use(e); alloc site IS e's own initializer.
# Fix 3a: defining_alloc emitted.
DEFINING_ALLOC_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_defining_alloc",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "CompoundStmt",
                    "inner": [
                        # Value *e = gc_alloc(...) → defining_alloc
                        {
                            "kind": "DeclStmt",
                            "inner": [
                                {
                                    "kind": "VarDecl",
                                    "name": "e",
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
                        # Use e → gc_use
                        {
                            "kind": "CallExpr",
                            "inner": [
                                {
                                    "kind": "ImplicitCastExpr",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {
                                                "name": "use",
                                            },
                                        }
                                    ],
                                },
                                {
                                    "kind": "DeclRefExpr",
                                    "referencedDecl": {"name": "e"},
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

class TestPhase5Extraction(unittest.TestCase):
    """Phase 5 extractor behaviour tests."""

    # ── Fix 1: BARRIER_RELEVANT_TYPES filtering ───────────────────────

    def test_01_instr_ptr_memcpy_no_stmt_memcpy(self):
        """memcpy into Instr* dst → no stmt_memcpy row (not barrier-relevant)."""
        results = _run_visitor_on_ast(INSTR_MEMCPY_AST)
        memcpys = results["stmt_memcpy"]
        self.assertEqual(len(memcpys), 0,
                         f"Expected 0 stmt_memcpy for Instr* dst, got {len(memcpys)}")

    def test_02_self_test_produces_stmt_memcpy_with_value_ptr(self):
        """--self-test produces stmt_memcpy for Value* new_env (barrier-relevant)."""
        rc, stdout, stderr = _run_extract(["--self-test",
                                            "--out-dir", "/tmp/gc-verify-p5-test"])
        self.assertEqual(rc, 0, f"--self-test failed: {stderr}")

        memcpy_path = Path("/tmp/gc-verify-p5-test") / "stmt_memcpy.csv"
        self.assertTrue(memcpy_path.exists(), "Missing stmt_memcpy.csv")
        with open(memcpy_path, "r") as f:
            rows = list(csv.DictReader(f))
        self.assertGreaterEqual(len(rows), 1,
                                f"Expected ≥1 stmt_memcpy row, got {len(rows)}")
        # new_env (Value*) should produce a row; p (void*) should NOT.
        dsts = {r["dst_expr"] for r in rows}
        self.assertIn("new_env", dsts,
                      f"Expected stmt_memcpy with dst='new_env', got dsts={dsts}")
        self.assertNotIn("p", dsts,
                         f"void* 'p' should be suppressed by BARRIER_RELEVANT_TYPES")

    # ── Fix 3a: defining_alloc ───────────────────────────────────────

    def test_03_defining_alloc_emitted(self):
        """Value *e = gc_alloc(...) → defining_alloc row emitted."""
        results = _run_visitor_on_ast(DEFINING_ALLOC_AST)
        das = results["defining_alloc"]
        self.assertGreaterEqual(len(das), 1,
                                f"Expected ≥1 defining_alloc, got {len(das)}")
        e_das = [r for r in das if r["var"] == "e"]
        self.assertEqual(len(e_das), 1,
                         f"Expected defining_alloc for 'e', got {e_das}")
        self.assertEqual(e_das[0]["f"], "test_defining_alloc")

    def test_04_non_alloc_var_no_defining_alloc(self):
        """Var without alloc init → no defining_alloc."""
        # Use the buggy_fn AST from test_phase2 (param 'code' has no init).
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                {
                    "kind": "FunctionDecl",
                    "name": "plain_fn",
                    "type": {"qualType": "void"},
                    "inner": [
                        {
                            "kind": "ParmVarDecl",
                            "name": "code",
                            "type": {"qualType": "struct Instr *"},
                        },
                        {
                            "kind": "CompoundStmt",
                            "inner": [
                                # gc_alloc with code arg (NOT code's own init)
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
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "code"},
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
        }
        results = _run_visitor_on_ast(ast)
        das = results["defining_alloc"]
        code_das = [r for r in das if r["var"] == "code"]
        self.assertEqual(len(code_das), 0,
                         "No defining_alloc for param 'code' (no alloc init)")

    # ── Real-clang-shape VarDecl: init in "init" key ─────────────────

    def test_05_init_key_defining_alloc(self):
        """VarDecl with init in 'init' key (real clang 22 shape) → defining_alloc."""
        # Real clang 22 stores VarDecl initializer in "init" key, not "inner".
        # The init is a CStyleCastExpr wrapping a CallExpr to gc_alloc.
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                {
                    "kind": "FunctionDecl",
                    "name": "real_clang_fn",
                    "type": {"qualType": "void"},
                    "inner": [
                        {
                            "kind": "CompoundStmt",
                            "inner": [
                                {
                                    "kind": "DeclStmt",
                                    "inner": [
                                        {
                                            "kind": "VarDecl",
                                            "name": "arr",
                                            "type": {"qualType": "struct Value *"},
                                            "init": {
                                                "kind": "CStyleCastExpr",
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
                                                            },
                                                            {
                                                                "kind": "IntegerLiteral",
                                                                "value": "128",
                                                            },
                                                            {
                                                                "kind": "IntegerLiteral",
                                                                "value": "2",
                                                            },
                                                        ],
                                                    }
                                                ],
                                            },
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
                                                        "name": "use",
                                                    },
                                                }
                                            ],
                                        },
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "arr"},
                                        },
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
        }
        results = _run_visitor_on_ast(ast)
        das = results["defining_alloc"]
        arr_das = [r for r in das if r["var"] == "arr"]
        self.assertEqual(len(arr_das), 1,
                         f"Expected defining_alloc for 'arr' (init key), got {arr_das}")
        self.assertEqual(arr_das[0]["f"], "real_clang_fn")

    def test_06_init_key_gc_use(self):
        """Value result = v; with init in 'init' key → gc_use for v."""
        # Real clang 22 shape: VarDecl with init in "init" key, holding
        # an ImplicitCastExpr → DeclRefExpr.  The extractor must emit
        # gc_use for the referenced var.
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                {
                    "kind": "FunctionDecl",
                    "name": "copy_fn",
                    "type": {"qualType": "struct Value"},
                    "inner": [
                        {
                            "kind": "ParmVarDecl",
                            "name": "v",
                            "type": {"qualType": "struct Value"},
                        },
                        {
                            "kind": "CompoundStmt",
                            "inner": [
                                {
                                    "kind": "DeclStmt",
                                    "inner": [
                                        {
                                            "kind": "VarDecl",
                                            "name": "result",
                                            "type": {"qualType": "struct Value"},
                                            "init": {
                                                "kind": "ImplicitCastExpr",
                                                "inner": [
                                                    {
                                                        "kind": "DeclRefExpr",
                                                        "referencedDecl": {
                                                            "name": "v",
                                                        },
                                                    }
                                                ],
                                            },
                                        }
                                    ],
                                },
                            ],
                        },
                    ],
                },
            ],
        }
        results = _run_visitor_on_ast(ast)
        uses = results["gc_use"]
        v_uses = [r for r in uses if r["v"] == "v"]
        self.assertGreaterEqual(len(v_uses), 1,
                                f"Expected gc_use for 'v' from init-key VarDecl, got {v_uses}")
        # Also verify gc_def for 'result'.
        defs = results["gc_def"]
        result_defs = [r for r in defs if r["v"] == "result"]
        self.assertGreaterEqual(len(result_defs), 1,
                                f"Expected gc_def for 'result', got {result_defs}")

    # ── _gc_local_types / _alloc_defined_var populated ───────────────

    def test_07_gc_local_types_populated(self):
        """_gc_local_types maps GC var names to normalized types."""
        # Use the visitor directly to inspect internal state.
        with tempfile.TemporaryDirectory(prefix="gc-verify-p5-ty-") as tmp:
            writer = extract.FactWriter(tmp)
            visitor = extract.AstVisitor(writer)
            visitor.visit(extract.SELF_TEST_AST)
            # After visiting, check _gc_local_types (last function visited).
            # The self-test AST has val_lambda with these GC vars.
            self.assertIn("code", visitor._gc_local_types,
                          "code should be in _gc_local_types")
            self.assertIn("v", visitor._gc_local_types,
                          "v should be in _gc_local_types")
            self.assertIn("new_env", visitor._gc_local_types,
                          "new_env should be in _gc_local_types")

    def test_08_alloc_defined_var_populated(self):
        """_alloc_defined_var maps (f, var) → sid for vars with alloc init."""
        with tempfile.TemporaryDirectory(prefix="gc-verify-p5-ad-") as tmp:
            writer = extract.FactWriter(tmp)
            visitor = extract.AstVisitor(writer)
            visitor.visit(extract.SELF_TEST_AST)
            # new_env has gc_alloc init → should be in _alloc_defined_var.
            self.assertIn(("val_lambda", "new_env"), visitor._alloc_defined_var,
                          "new_env should be in _alloc_defined_var")
            # code (param) has NO init → should NOT be in _alloc_defined_var.
            self.assertNotIn(("val_lambda", "code"), visitor._alloc_defined_var,
                             "code should NOT be in _alloc_defined_var")

    # ── Fix 3b: CaseStmt BB scoping ──────────────────────────────────

    def test_09_casestmt_bb_scoping(self):
        """next_stmt edges do NOT cross CaseStmt boundaries."""
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                {
                    "kind": "FunctionDecl",
                    "name": "switch_fn",
                    "type": {"qualType": "void"},
                    "inner": [
                        {
                            "kind": "ParmVarDecl",
                            "name": "code",
                            "type": {"qualType": "struct Instr *"},
                        },
                        {
                            "kind": "ParmVarDecl",
                            "name": "tag",
                            "type": {"qualType": "int"},
                        },
                        {
                            "kind": "CompoundStmt",
                            "inner": [
                                {
                                    "kind": "SwitchStmt",
                                    "inner": [
                                        {
                                            "kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "tag"},
                                        },
                                        {
                                            "kind": "CompoundStmt",
                                            "inner": [
                                                {
                                                    "kind": "CaseStmt",
                                                    "inner": [
                                                        {
                                                            "kind": "IntegerLiteral",
                                                            "value": "0",
                                                        },
                                                        # case 0: use code
                                                        {
                                                            "kind": "CallExpr",
                                                            "inner": [
                                                                {
                                                                    "kind": "ImplicitCastExpr",
                                                                    "inner": [
                                                                        {
                                                                            "kind": "DeclRefExpr",
                                                                            "referencedDecl": {
                                                                                "name": "use_code",
                                                                            },
                                                                        }
                                                                    ],
                                                                },
                                                                {
                                                                    "kind": "DeclRefExpr",
                                                                    "referencedDecl": {
                                                                        "name": "code",
                                                                    },
                                                                },
                                                            ],
                                                        },
                                                    ],
                                                },
                                                {
                                                    "kind": "CaseStmt",
                                                    "inner": [
                                                        {
                                                            "kind": "IntegerLiteral",
                                                            "value": "1",
                                                        },
                                                        # case 1: gc_alloc
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
                                                            ],
                                                        },
                                                    ],
                                                },
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
        results = _run_visitor_on_ast(ast)
        nexts = results["next_stmt"]

        # Find the stmt_ids for the two call exprs.
        uses = results["gc_use"]
        allocs = results["stmt_allocs"]

        self.assertGreater(len(uses), 0, "Expected gc_use of code")
        self.assertGreater(len(allocs), 0, "Expected stmt_allocs")

        alloc_sid = int(allocs[0]["stmt_id"])
        use_sids = {int(r["stmt_id"]) for r in uses if r["v"] == "code"}

        # code is used ONLY in case 0.  alloc is in case 1.
        # next_stmt should NOT connect any use_sid to alloc_sid
        # (they're in different BBs).  So live_at should NOT reach
        # from the use back to the alloc.
        cross_edges = [(int(r["from"]), int(r["to"])) for r in nexts
                       if r["f"] == "switch_fn"]
        # Verify no edge crosses case boundaries.
        for frm, to in cross_edges:
            for use_sid in use_sids:
                if frm == use_sid and to == alloc_sid:
                    self.fail(
                        f"next_stmt {frm}→{to} crosses case boundary "
                        f"(use_sid={use_sid}, alloc_sid={alloc_sid})"
                    )
                if frm == alloc_sid and to == use_sid:
                    self.fail(
                        f"next_stmt {frm}→{to} crosses case boundary"
                    )

    # ── Phase 5 CSV schemas ──────────────────────────────────────────

    def test_10_new_schemas_in_self_test(self):
        """Phase 5 CSV relation (defining_alloc) emitted."""
        rc, stdout, stderr = _run_extract(["--self-test",
                                            "--out-dir", "/tmp/gc-verify-p5-schemas"])
        self.assertEqual(rc, 0, f"--self-test failed: {stderr}")
        for rel in ("defining_alloc",):
            path = Path("/tmp/gc-verify-p5-schemas") / f"{rel}.csv"
            self.assertTrue(path.exists(),
                            f"Missing CSV: {rel}.csv")

    def test_11_all_16_schemas_in_self_test(self):
        """All 16 CSV relations have headers produced by --self-test."""
        rc, stdout, stderr = _run_extract(["--self-test",
                                            "--out-dir", "/tmp/gc-verify-p5-all"])
        self.assertEqual(rc, 0, f"--self-test failed: {stderr}")
        for rel in extract.CSV_SCHEMAS:
            path = Path("/tmp/gc-verify-p5-all") / f"{rel}.csv"
            self.assertTrue(path.exists(),
                            f"Missing CSV: {rel}.csv")
        self.assertEqual(len(extract.CSV_SCHEMAS), 16,
                         f"Expected 16 schemas (fresh_target dropped, +call_site/array_store), got {len(extract.CSV_SCHEMAS)}")

    def test_11b_fresh_target_removed(self):
        """fresh_target is NOT in CSV_SCHEMAS and no fresh_target.csv emitted."""
        self.assertNotIn("fresh_target", extract.CSV_SCHEMAS,
                         "fresh_target must NOT be in CSV_SCHEMAS")
        rc, stdout, stderr = _run_extract(["--self-test",
                                            "--out-dir", "/tmp/gc-verify-p5-nft"])
        self.assertEqual(rc, 0, f"--self-test failed: {stderr}")
        ft_path = Path("/tmp/gc-verify-p5-nft") / "fresh_target.csv"
        # File exists because FactWriter writes ALL schemas as files.
        # But the data rows should be header-only.
        if ft_path.exists():
            with open(ft_path, "r") as f:
                lines = [l for l in f if l.strip()]
            self.assertLessEqual(len(lines), 1,
                                 f"fresh_target.csv should be header-only, got {lines}")


class TestPhase5Analysis(unittest.TestCase):
    """Phase 5 analysis logic tests (Python mini-simulator).

    Validates that the Python ports of the updated Datalog rules produce
    the same results as gc_safety.dl.
    """

    # ── defining_alloc-aware root_miss ────────────────────────────────

    def test_12_defining_alloc_suppresses_root_miss(self):
        """defining_alloc at alloc site → root_miss does NOT fire."""
        # Scenario: Value *e = gc_alloc(...);  use(e);
        # gc_def for e at stmt 0, the alloc call is at stmt 1 (inside the
        # VarDecl init), use of e at stmt 2.  e is live at stmt 1 (use at 2
        # propagates back; no kill at 1).  Without defining_alloc this would
        # fire.  With defining_alloc(e, stmt_id=1), it's suppressed.

        gc_use_rows = [
            {"f": "def_fn", "stmt_id": "2", "v": "e"},
        ]
        gc_def_rows = [
            {"f": "def_fn", "stmt_id": "0", "v": "e"},
        ]
        next_stmt_rows = [
            {"f": "def_fn", "from": "0", "to": "1"},
            {"f": "def_fn", "from": "1", "to": "2"},
        ]
        stmt_pushes_rows = []
        stmt_pops_rows = []
        stmt_allocs_rows = [
            # The alloc call inside the VarDecl init.
            {"f": "def_fn", "stmt_id": "1", "callee": "gc_alloc"},
        ]
        var_decl_rows = [
            {"f": "def_fn", "name": "e", "type": "Value*",
             "is_gc_managed": "1"},
        ]
        defining_alloc_rows = [
            {"f": "def_fn", "var": "e", "stmt_id": "1"},
        ]

        live = _compute_live_at(gc_use_rows, gc_def_rows, next_stmt_rows)
        pm = _compute_pushed_may(stmt_pushes_rows, stmt_pops_rows,
                                 next_stmt_rows)
        rms = _compute_root_miss(live, pm, stmt_allocs_rows, var_decl_rows,
                                 defining_alloc_rows=defining_alloc_rows)

        # e is live at stmt 1 (propagated back from use at 2; gc_def at 0
        # kills backward propagation FROM 0 but not from 1→2).
        self.assertIn(("def_fn", "e", 1), live,
                      "e should be live at stmt 1 (alloc site)")

        # defining_alloc suppresses root_miss at stmt 1.
        self.assertEqual(len(rms), 0,
                         f"Expected no root_miss (defining_alloc), got {rms}")

    def test_13_no_defining_alloc_still_fires(self):
        """Without defining_alloc, root_miss fires for the same scenario."""
        gc_use_rows = [
            {"f": "bug_fn", "stmt_id": "2", "v": "e"},
        ]
        gc_def_rows = [
            {"f": "bug_fn", "stmt_id": "0", "v": "e"},
        ]
        next_stmt_rows = [
            {"f": "bug_fn", "from": "0", "to": "1"},
            {"f": "bug_fn", "from": "1", "to": "2"},
        ]
        stmt_pushes_rows = []
        stmt_pops_rows = []
        stmt_allocs_rows = [
            {"f": "bug_fn", "stmt_id": "1", "callee": "gc_alloc"},
        ]
        var_decl_rows = [
            {"f": "bug_fn", "name": "e", "type": "Value*",
             "is_gc_managed": "1"},
        ]
        # NO defining_alloc rows.

        live = _compute_live_at(gc_use_rows, gc_def_rows, next_stmt_rows)
        pm = _compute_pushed_may(stmt_pushes_rows, stmt_pops_rows,
                                 next_stmt_rows)
        rms = _compute_root_miss(live, pm, stmt_allocs_rows, var_decl_rows,
                                 defining_alloc_rows=[])

        self.assertIn(("bug_fn", "e", 1), live,
                      "e should be live at stmt 1 (alloc site)")
        # Without defining_alloc, this SHOULD fire.
        self.assertIn(("bug_fn", 1, "e"), rms,
                      "Expected root_miss without defining_alloc")

    # ── memcpy_unbarriered (no fresh_target) ─────────────────────────

    def test_14_memcpy_unbarriered_without_barrier(self):
        """Without a barrier, memcpy_unbarriered still fires."""
        stmt_memcpy_rows = [
            {"f": "nft_fn", "stmt_id": "1", "dst_expr": "new_env",
             "src_expr": "src_env", "nbytes": ""},
        ]
        stmt_barrier_rows = []
        stmt_allocs_rows = [
            {"f": "nft_fn", "stmt_id": "0", "callee": "gc_alloc"},
            {"f": "nft_fn", "stmt_id": "2", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "nft_fn", "from": "0", "to": "1"},
            {"f": "nft_fn", "from": "1", "to": "2"},
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        self.assertIn(("nft_fn", 1, "new_env"), unbarriered,
                      "Expected memcpy_unbarriered without barrier")

    def test_15_memcpy_unbarriered_with_barrier_suppressed(self):
        """With a barrier, memcpy_unbarriered is suppressed."""
        stmt_memcpy_rows = [
            {"f": "bar_fn", "stmt_id": "1", "dst_expr": "buf",
             "src_expr": "src", "nbytes": ""},
        ]
        stmt_barrier_rows = [
            {"f": "bar_fn", "stmt_id": "2", "target_expr": "buf"},
        ]
        stmt_allocs_rows = [
            {"f": "bar_fn", "stmt_id": "0", "callee": "gc_alloc"},
            {"f": "bar_fn", "stmt_id": "3", "callee": "gc_alloc"},
        ]
        next_stmt_rows = [
            {"f": "bar_fn", "from": "0", "to": "1"},
            {"f": "bar_fn", "from": "1", "to": "2"},
            {"f": "bar_fn", "from": "2", "to": "3"},
        ]

        reach = _compute_reach_stmt(next_stmt_rows)
        covers = _compute_barrier_covers(
            stmt_memcpy_rows, stmt_barrier_rows, stmt_allocs_rows, reach)
        unbarriered = _compute_memcpy_unbarriered(
            stmt_memcpy_rows, stmt_allocs_rows, reach, covers)

        self.assertEqual(len(unbarriered), 0,
                         f"Expected no unbarriered memcpy (barrier covers), got {unbarriered}")

    # ── BB-tagged next_stmt cross-case propagation ───────────────────

    def test_16_cross_case_liveness_not_propagated(self):
        """Var used in case A, alloc in case B → var NOT live at alloc."""
        # Simulate two cases: stmt 0 (use code in case A), stmt 1 (alloc in case B).
        # No next_stmt edge between 0 and 1 → code is NOT live at stmt 1.
        gc_use_rows = [
            {"f": "cross_fn", "stmt_id": "0", "v": "code"},
        ]
        gc_def_rows = []
        # NO edge from 0 to 1 (different BBs).
        next_stmt_rows = [
            # Only within-case edges exist, but not from 0 to 1.
        ]
        stmt_pushes_rows = []
        stmt_pops_rows = []
        stmt_allocs_rows = [
            {"f": "cross_fn", "stmt_id": "1", "callee": "gc_alloc"},
        ]
        var_decl_rows = [
            {"f": "cross_fn", "name": "code", "type": "Instr*",
             "is_gc_managed": "1"},
        ]

        live = _compute_live_at(gc_use_rows, gc_def_rows, next_stmt_rows)
        pm = _compute_pushed_may(stmt_pushes_rows, stmt_pops_rows,
                                 next_stmt_rows)
        rms = _compute_root_miss(live, pm, stmt_allocs_rows, var_decl_rows)

        # code is live at stmt 0 (its use site) but NOT at stmt 1
        # because no next_stmt edge 0→1 (cross-case).
        self.assertIn(("cross_fn", "code", 0), live,
                      "code should be live at stmt 0 (use site)")
        self.assertNotIn(("cross_fn", "code", 1), live,
                         "code should NOT be live at stmt 1 (cross-case)")
        self.assertEqual(len(rms), 0,
                         f"Expected no root_miss (cross-case), got {rms}")

    def test_17_same_case_liveness_still_propagated(self):
        """Var used and alloc in same BB → liveness propagates normally."""
        gc_use_rows = [
            {"f": "same_fn", "stmt_id": "1", "v": "code"},
        ]
        gc_def_rows = []
        next_stmt_rows = [
            {"f": "same_fn", "from": "0", "to": "1"},
        ]
        stmt_pushes_rows = []
        stmt_pops_rows = []
        stmt_allocs_rows = [
            {"f": "same_fn", "stmt_id": "0", "callee": "gc_alloc"},
        ]
        var_decl_rows = [
            {"f": "same_fn", "name": "code", "type": "Instr*",
             "is_gc_managed": "1"},
        ]

        live = _compute_live_at(gc_use_rows, gc_def_rows, next_stmt_rows)
        pm = _compute_pushed_may(stmt_pushes_rows, stmt_pops_rows,
                                 next_stmt_rows)
        rms = _compute_root_miss(live, pm, stmt_allocs_rows, var_decl_rows)

        # code is live at stmt 0 (propagated back from use at 1).
        self.assertIn(("same_fn", "code", 0), live,
                      "code should be live at stmt 0 (same BB)")
        self.assertIn(("same_fn", 0, "code"), rms,
                      "Expected root_miss in same-BB straight-line case")

    # ── Regression: existing tests still pass ────────────────────────

    def test_18_existing_phase0_tests_pass(self):
        """All Phase 0 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase0.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase0.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_19_existing_phase1_tests_pass(self):
        """All Phase 1 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase1.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase1.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_20_existing_phase2_tests_pass(self):
        """All Phase 2 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase2.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase2.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_21_existing_phase3_tests_pass(self):
        """All Phase 3 tests still pass."""
        test_file = TOOLS_DIR / "tests" / "test_phase3.py"
        proc = subprocess.run(
            [sys.executable, str(test_file)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0,
                         f"test_phase3.py failed:\n{proc.stderr}\n{proc.stdout}")


if __name__ == "__main__":
    unittest.main()

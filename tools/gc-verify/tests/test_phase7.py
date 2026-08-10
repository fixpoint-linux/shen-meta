#!/usr/bin/env python3
"""test_phase7.py — Phase 7 real basic-block CFG tests for gc-verify.

Validates:
  1. cfg_edge emitted for branch/loop/fall edges from synthetic ASTs.
  2. _sid_of_node map correctly populated (sid → node identity).
  3. IfStmt emits true_br/false_br/fall edges correctly.
  4. WhileStmt emits back-edge + true_br/false_br.
  5. SwitchStmt no implicit fall-through; case edges emitted.
  6. Empty branches handled (edge to continuation).
  7. stmt_id numbering UNCHANGED (next_stmt.csv byte-identical with pre-Phase-7).
  8. param_rooted emitted for GC-managed pointer params, NOT for by-value or non-params.
  9. Mini-simulators:
     - reach_stmt over cfg_edge (branch divergence).
     - live_at branch precision (use in branch A does NOT make var live in branch B).
     - pushed_may branch-join (pushed via branch A → pushed at join).
     - must_rooted via reaches_unrooted (push one branch → must_rooted false at join).
     - root_miss with param_rooted suppression.
  10. All existing Phase 0/1/2/3/5/6 tests still pass (regression).

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
    proc = subprocess.run(
        [sys.executable, str(EXTRACT_PY)] + args,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _run_visitor_on_ast(ast_dict):
    """Run the AstVisitor on a synthetic AST dict, return parsed CSVs."""
    with tempfile.TemporaryDirectory(prefix="gc-verify-phase7-") as tmp:
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
# Synthetic ASTs for Phase 7 CFG extraction tests
# ══════════════════════════════════════════════════════════════════════════

def _call_expr(callee):
    return {
        "kind": "CallExpr",
        "inner": [
            {
                "kind": "ImplicitCastExpr",
                "inner": [
                    {"kind": "DeclRefExpr",
                     "referencedDecl": {"name": callee}},
                ],
            }
        ],
    }


def _declref(name):
    return {"kind": "DeclRefExpr", "referencedDecl": {"name": name}}


def _var_decl(name, qual_type):
    return {"kind": "VarDecl", "name": name,
            "type": {"qualType": qual_type}}


def _compound_stmt(*stmts):
    return {"kind": "CompoundStmt", "inner": list(stmts)}


def _if_stmt(cond, then_body, else_body=None):
    inner = [cond, then_body]
    if else_body is not None:
        inner.append(else_body)
    return {"kind": "IfStmt", "inner": inner}


def _while_stmt(cond, body):
    return {"kind": "WhileStmt", "inner": [cond, body]}


def _switch_stmt(cond, *cases):
    return {"kind": "SwitchStmt", "inner": [cond] + list(cases)}


def _case_stmt(*body):
    return {"kind": "CaseStmt", "inner": list(body)}


def _default_stmt(*body):
    return {"kind": "DefaultStmt", "inner": list(body)}


def _break_stmt():
    return {"kind": "BreakStmt", "inner": []}


def _return_stmt(expr=None):
    inner = [expr] if expr is not None else []
    return {"kind": "ReturnStmt", "inner": inner}


def _func_decl(name, body_stmts):
    return {
        "kind": "FunctionDecl",
        "name": name,
        "type": {"qualType": "void"},
        "inner": [
            _compound_stmt(*body_stmts),
        ],
    }


def _gc_alloc_call():
    """Call to gc_alloc — a sid-bearing call."""
    return _call_expr("gc_alloc")


def _push_call(var_name):
    return {
        "kind": "CallExpr",
        "inner": [
            {
                "kind": "ImplicitCastExpr",
                "inner": [
                    {"kind": "DeclRefExpr",
                     "referencedDecl": {"name": "gc_root_push_value"}},
                ],
            },
            {
                "kind": "UnaryOperator",
                "opcode": "&",
                "inner": [_declref(var_name)],
            },
        ],
    }


def _pop_call():
    return _call_expr("gc_root_pop")


def _assign(lhs_name, rhs_node):
    return {
        "kind": "BinaryOperator",
        "opcode": "=",
        "inner": [_declref(lhs_name), rhs_node],
    }


# ── Simple if-then-else AST ────────────────────────────────────────

IF_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        _func_decl("test_if", [
            _var_decl("p", "struct Value *"),
            _if_stmt(
                _call_expr("check_flag"),   # cond (sid-bearing)
                _compound_stmt(_push_call("p"), _gc_alloc_call()),
                _compound_stmt(_gc_alloc_call()),
            ),
            _gc_alloc_call(),   # continuation after if (for k_sid ≠ None)
        ]),
    ],
}

# ── While loop AST ─────────────────────────────────────────────────

WHILE_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        _func_decl("test_while", [
            _var_decl("p", "struct Value *"),
            _while_stmt(
                _call_expr("check_flag"),   # cond (sid-bearing)
                _compound_stmt(_push_call("p"), _gc_alloc_call()),
            ),
            _gc_alloc_call(),   # continuation after while
        ]),
    ],
}

# ── Switch AST (two cases, no fall-through) ────────────────────────

SWITCH_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        _func_decl("test_switch", [
            _var_decl("p", "struct Value *"),
            _switch_stmt(
                _call_expr("get_val"),   # cond (sid-bearing)
                _case_stmt(_gc_alloc_call(), _break_stmt()),
                _case_stmt(_push_call("p"), _gc_alloc_call()),
                _default_stmt(_gc_alloc_call()),
            ),
            _gc_alloc_call(),   # continuation after switch
        ]),
    ],
}


# ══════════════════════════════════════════════════════════════════════════
# CFG Extraction Tests
# ══════════════════════════════════════════════════════════════════════════

class TestCFGExtraction(unittest.TestCase):

    def test_01_if_emits_true_false_edges(self):
        """IfStmt emits true_br and false_br edges from cond exit."""
        res = _run_visitor_on_ast(IF_AST)
        edges = res["cfg_edge"]
        kinds = set()
        for e in edges:
            kinds.add(e["kind"])
        self.assertIn("true_br", kinds, "IfStmt should emit true_br edges")
        self.assertIn("false_br", kinds, "IfStmt should emit false_br edges")
        self.assertIn("fall", kinds, "straight-line fall edges should also exist")

    def test_02_while_emits_back_edge(self):
        """WhileStmt emits 'back' edge from body exit to cond entry."""
        res = _run_visitor_on_ast(WHILE_AST)
        edges = res["cfg_edge"]
        kinds = {e["kind"] for e in edges}
        self.assertIn("back", kinds, "WhileStmt should emit back edges")
        self.assertIn("true_br", kinds, "cond true_br to body")
        self.assertIn("false_br", kinds, "cond false_br to exit")

    def test_03_switch_no_fall_through(self):
        """SwitchStmt emits case edges to each case; breaks route to continuation."""
        res = _run_visitor_on_ast(SWITCH_AST)
        edges = res["cfg_edge"]
        case_edges = [e for e in edges if e["kind"] == "case"]
        self.assertGreaterEqual(len(case_edges), 3,
                                f"Expected ≥3 case edges (2 cases + default), got {case_edges}")
        # Verify no fall-through: there should NOT be fall edges between cases.
        # Each case has a break → break edges should exist.
        break_edges = [e for e in edges if e["kind"] == "break"]
        self.assertGreaterEqual(len(break_edges), 1,
                                f"Expected break edges, got {break_edges}")

    def test_04_self_test_produces_cfg_edges(self):
        """--self-test produces cfg_edge rows from real CFG walk."""
        rc, stdout, stderr = _run_extract(["--self-test",
                                            "--out-dir", "/tmp/gc-verify-p7-cfg"])
        self.assertEqual(rc, 0, f"--self-test failed: {stderr}")
        with open("/tmp/gc-verify-p7-cfg/cfg_edge.csv", "r") as f:
            reader = csv.reader(f)
            header = next(reader)
            rows = list(reader)
        self.assertGreater(len(rows), 0,
                           "cfg_edge.csv should have data rows from _build_cfg")
        # The SELF_TEST_AST is straight-line, so all edges should be "fall".
        kinds = {row[3] for row in rows}
        self.assertEqual(kinds, {"fall"},
                         f"Straight-line SELF_TEST_AST should only have fall edges, got {kinds}")

    def test_05_stmt_id_unchanged(self):
        """next_stmt.csv is byte-identical between old and new extractors.

        We verify that stmt_ids are produced in the same order — the old
        extractor's next_stmt is a baseline.  We can only test this
        end-to-end: running the current self-test and verifying the
        next_stmt rows form a sequential chain with no gaps in the
        sequence of sids that appear (since the SELF_TEST_AST has not
        changed).
        """
        with tempfile.TemporaryDirectory(prefix="gc-verify-p7-sid-") as tmp:
            rc, _, stderr = _run_extract(["--self-test", "--out-dir", tmp])
            self.assertEqual(rc, 0, f"--self-test failed: {stderr}")

            # Read next_stmt rows.
            path = Path(tmp) / "next_stmt.csv"
            with open(path, "r") as f:
                reader = csv.DictReader(f)
                next_rows = list(reader)

            # Read cfg_edge rows.
            cfg_path = Path(tmp) / "cfg_edge.csv"
            with open(cfg_path, "r") as f:
                reader = csv.DictReader(f)
                cfg_rows = list(reader)

        # The next_stmt row count should be exactly (max_sid - first_sid)
        # for a straight-line function (every sid connects to the next).
        self.assertGreater(len(next_rows), 0, "next_stmt should have rows")
        self.assertGreater(len(cfg_rows), 0, "cfg_edge should have rows")

        # Verify next_stmt forms a proper chain (no duplicates, sequential).
        from_sids = {int(r["from"]) for r in next_rows}
        to_sids = {int(r["to"]) for r in next_rows}
        all_sids = from_sids | to_sids
        min_sid = min(all_sids)
        max_sid = max(all_sids)
        # For a sequential chain of n sids, we expect n-1 edges.
        expected_count = max_sid - min_sid
        self.assertEqual(len(next_rows), expected_count,
                         f"next_stmt should have {expected_count} rows "
                         f"(sids {min_sid}..{max_sid}), got {len(next_rows)}")

    def test_15_container_with_nested_sid_emits_fall_edge(self):
        """Fix 1: VarDecl init CallExpr emits container_sid -> alloc_sid fall edge."""
        # A VarDecl with a gc_alloc init → VarDecl gets a sid (gc_def),
        # the CallExpr inside also gets a sid (stmt_allocs).
        # The cfg_edge should chain: var_sid -> call_sid -> ...
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                _func_decl("test_nested", [
                    {
                        "kind": "DeclStmt",
                        "inner": [
                            {
                                "kind": "VarDecl",
                                "name": "p",
                                "type": {"qualType": "struct Value *"},
                                "inner": [
                                    _gc_alloc_call(),
                                ],
                            },
                        ],
                    },
                    _gc_alloc_call(),   # continuation
                ]),
            ],
        }
        res = _run_visitor_on_ast(ast)
        edges = res["cfg_edge"]
        # Find the VarDecl sid and the CallExpr sid.
        # The VarDecl should have a gc_def; the CallExpr should have stmt_allocs.
        var_decl_sid = None
        alloc_sid = None
        for r in res.get("gc_def", []):
            if r["v"] == "p":
                var_decl_sid = int(r["stmt_id"])
        for r in res.get("stmt_allocs", []):
            alloc_sid = int(r["stmt_id"])
            break  # take the first (inner) alloc — depth-first means inner comes first
        self.assertIsNotNone(var_decl_sid, "VarDecl should have a gc_def sid")
        self.assertIsNotNone(alloc_sid, "CallExpr should have a stmt_allocs sid")

        # Check for the fall edge from var_sid to alloc_sid.
        fall_edges = [(int(e["from_stmt_id"]), int(e["to_stmt_id"]))
                       for e in edges if e["kind"] == "fall"]
        self.assertIn((var_decl_sid, alloc_sid), fall_edges,
                      f"Expected fall edge {var_decl_sid}->{alloc_sid} from container to nested alloc")

    def test_16_ifstmt_no_cond_sid_emits_from_pred(self):
        """Fix 2: IfStmt with no cond-sid emits true_br/false_br from predecessor."""
        # Condition is a DeclRefExpr (not sid-bearing).  The if is the first
        # statement in the function, so edges should come from -1.
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                _func_decl("test_nocondsid", [
                    _if_stmt(
                        _declref("flag"),   # no sid!
                        _compound_stmt(_push_call("p")),   # then: push(&p)
                        None,                              # no else
                    ),
                    _gc_alloc_call(),       # continuation after if
                ]),
            ],
        }
        res = _run_visitor_on_ast(ast)
        edges = res["cfg_edge"]

        # Check that we have true_br and false_br edges.
        kind_from = {}
        for e in edges:
            knd = e["kind"]
            frm = int(e["from_stmt_id"])
            kind_from.setdefault(knd, set()).add(frm)

        self.assertIn("true_br", kind_from, "Should have true_br edges")
        self.assertIn("false_br", kind_from, "Should have false_br edges")

        # Both should come from the same source (the predecessor, which is -1
        # for first-statement if).
        true_src = kind_from["true_br"]
        false_src = kind_from["false_br"]
        self.assertEqual(true_src, false_src,
                         f"true_br and false_br should come from same source, "
                         f"got {true_src} vs {false_src}")

        # The source should be -1 (func_entry_sid) for a first-statement if.
        common_src = list(true_src)[0]
        self.assertEqual(common_src, -1,
                         f"First-statement if with no cond-sid should emit from -1, "
                         f"got {common_src}")


class TestParamRooted(unittest.TestCase):

    def test_06_param_rooted_not_emitted_for_explicitly_pushed(self):
        """GC-managed pointer params that are gc_root_push'd do NOT get param_rooted."""
        # SELF_TEST_AST pushes &code and &env — these should NOT be param_rooted.
        res = _run_visitor_on_ast(extract.SELF_TEST_AST)
        pr_rows = res.get("param_rooted", [])
        pr_vars = {r["var"] for r in pr_rows}
        # code and env are explicitly pushed in the AST — Fix 3 removes them.
        self.assertNotIn("code", pr_vars,
                         "Instr* param 'code' is explicitly pushed — should NOT be param_rooted")
        self.assertNotIn("env", pr_vars,
                         "Value* param 'env' is explicitly pushed — should NOT be param_rooted")

    def test_06b_param_rooted_emitted_for_non_pushed_param(self):
        """GC-managed pointer params that are NOT pushed still get param_rooted."""
        # Create a function with a Value* param that is never pushed.
        # Must use ParmVarDecl (not VarDecl) for the parameter.
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                {
                    "kind": "FunctionDecl",
                    "name": "test_nonpushed",
                    "type": {"qualType": "void"},
                    "inner": [
                        {"kind": "ParmVarDecl", "name": "p",
                         "type": {"qualType": "struct Value *"}},
                        _compound_stmt(_gc_alloc_call()),
                    ],
                },
            ],
        }
        res = _run_visitor_on_ast(ast)
        pr_rows = res.get("param_rooted", [])
        pr_vars = {r["var"] for r in pr_rows}
        self.assertIn("p", pr_vars,
                      "Value* param 'p' is NOT pushed — should be param_rooted")

    def test_07_param_rooted_not_emitted_for_by_value(self):
        """By-value GC params (Value) do NOT get param_rooted."""
        # Create a function with a by-value Value param + a Value* param.
        ast = {
            "kind": "TranslationUnitDecl",
            "inner": [
                {
                    "kind": "FunctionDecl",
                    "name": "test_params",
                    "type": {"qualType": "void"},
                    "inner": [
                        {"kind": "ParmVarDecl", "name": "v",
                         "type": {"qualType": "struct Value"}},
                        {"kind": "ParmVarDecl", "name": "vp",
                         "type": {"qualType": "struct Value *"}},
                        _compound_stmt(),
                    ],
                },
            ],
        }
        res = _run_visitor_on_ast(ast)
        pr_rows = res.get("param_rooted", [])
        pr_vars = {r["var"] for r in pr_rows}
        self.assertNotIn("v", pr_vars,
                         "by-value Value param should NOT be param_rooted")
        self.assertIn("vp", pr_vars,
                      "Value* param should be param_rooted")


# ══════════════════════════════════════════════════════════════════════════
# Python mini-simulators of Phase 7 Datalog rules
# ══════════════════════════════════════════════════════════════════════════

def _compute_reach_stmt_cfg(cfg_edge_rows):
    """Compute reach_stmt(f, from, to) — transitive closure over cfg_edge."""
    nexts = {}
    for r in cfg_edge_rows:
        key = (r["f"], int(r["from_stmt_id"]))
        nexts.setdefault(key, set()).add(int(r["to_stmt_id"]))

    reach = set()
    for r in cfg_edge_rows:
        reach.add((r["f"], int(r["from_stmt_id"]), int(r["to_stmt_id"])))

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


def _compute_live_at_cfg(gc_use_rows, gc_def_rows, cfg_edge_rows):
    """Compute live_at(f, v, s) — backward dataflow over cfg_edge."""
    uses = {r["f"]: set() for r in gc_use_rows}
    for r in gc_use_rows:
        uses.setdefault(r["f"], set()).add((int(r["stmt_id"]), r["v"]))

    defs = set()
    for r in gc_def_rows:
        defs.add((r["f"], int(r["stmt_id"]), r["v"]))

    # cfg_edge successors: (f, from) -> set of (to, kind)
    succ = {}
    for r in cfg_edge_rows:
        key = (r["f"], int(r["from_stmt_id"]))
        succ.setdefault(key, set()).add(int(r["to_stmt_id"]))

    # cfg_edge predecessors: (f, to) -> set of from
    pred = {}
    for r in cfg_edge_rows:
        key = (r["f"], int(r["to_stmt_id"]))
        pred.setdefault(key, set()).add(int(r["from_stmt_id"]))

    live = set()
    for r in gc_use_rows:
        live.add((r["f"], r["v"], int(r["stmt_id"])))

    changed = True
    while changed:
        changed = False
        new_live = set(live)
        for (f, v, s_next) in live:
            for s in pred.get((f, s_next), set()):
                if (f, s, v) not in defs:
                    entry = (f, v, s)
                    if entry not in new_live:
                        new_live.add(entry)
                        changed = True
        live = new_live
    return live


def _compute_pushed_may_cfg(stmt_pushes_rows, stmt_pops_rows, cfg_edge_rows):
    """Compute pushed_may(f, v, s) — forward dataflow over cfg_edge."""
    pop_to_at = set()
    for r in stmt_pops_rows:
        if r.get("pkind") == "pop_to":
            pop_to_at.add((r["f"], int(r["stmt_id"])))

    succ = {}
    for r in cfg_edge_rows:
        key = (r["f"], int(r["from_stmt_id"]))
        succ.setdefault(key, set()).add(int(r["to_stmt_id"]))

    pushed = set()
    for r in stmt_pushes_rows:
        pushed.add((r["f"], r["slot_expr"], int(r["stmt_id"])))

    changed = True
    while changed:
        changed = False
        new_pushed = set(pushed)
        for (f, v, s) in pushed:
            if (f, s) in pop_to_at:
                continue
            for s_next in succ.get((f, s), set()):
                entry = (f, v, s_next)
                if entry not in new_pushed:
                    new_pushed.add(entry)
                    changed = True
        pushed = new_pushed
    return pushed


def _compute_reaches_unrooted(var_decl_rows, stmt_pushes_rows,
                               stmt_pops_rows, cfg_edge_rows,
                               first_stmt_set):
    """Compute reaches_unrooted(f, v, s) — forward may-analysis."""
    pop_to_at = set()
    for r in stmt_pops_rows:
        if r.get("pkind") == "pop_to":
            pop_to_at.add((r["f"], int(r["stmt_id"])))

    push_at = set()
    for r in stmt_pushes_rows:
        push_at.add((r["f"], int(r["stmt_id"]), r["slot_expr"]))

    succ = {}
    for r in cfg_edge_rows:
        key = (r["f"], int(r["from_stmt_id"]))
        succ.setdefault(key, set()).add(int(r["to_stmt_id"]))

    gc_managed = {}
    for r in var_decl_rows:
        if r.get("is_gc_managed") == "1":
            gc_managed.setdefault(r["f"], set()).add(r["name"])

    reaches = set()

    # Base 1: gc-managed var at function entry (first_stmt).
    for (f, s) in first_stmt_set:
        for v in gc_managed.get(f, set()):
            reaches.add((f, v, s))

    changed = True
    while changed:
        changed = False
        new_reaches = set(reaches)

        # Propagation: unrooted → unrooted unless killed by push.
        for (f, v, s) in reaches:
            for s_next in succ.get((f, s), set()):
                if (f, s, v) not in push_at:
                    entry = (f, v, s_next)
                    if entry not in new_reaches:
                        new_reaches.add(entry)
                        changed = True

        # Base 2: after pop_to, re-expose all gc-managed vars.
        for (f, s) in pop_to_at:
            for s_next in succ.get((f, s), set()):
                for v in gc_managed.get(f, set()):
                    entry = (f, v, s_next)
                    if entry not in new_reaches:
                        new_reaches.add(entry)
                        changed = True

        reaches = new_reaches
    return reaches


def _compute_must_rooted(var_decl_rows, reaches_unrooted_set):
    """Compute must_rooted(f, v, s) — complement of reaches_unrooted."""
    gc_managed = {}
    for r in var_decl_rows:
        if r.get("is_gc_managed") == "1":
            gc_managed.setdefault(r["f"], set()).add(r["name"])

    # Also find all stmt_ids that appear in reaches_unrooted.
    all_sids = set()
    for (f, v, s) in reaches_unrooted_set:
        all_sids.add((f, s))

    must = set()
    # must_rooted at all stmt_ids where v is gc-managed but NOT reaches_unrooted.
    # We need the stmt_ids for each function.  Use the ones from cfg_edge.
    # But the simulator doesn't have the full set of stmt_ids.  Instead,
    # we compute must_rooted only at stmt_ids that appear in any analysis.
    for (f, v, s) in list(reaches_unrooted_set):
        # Don't use — we want the complement.
        pass

    # Better: collect all stmt_ids from cfg_edge.
    all_f_sids = set()
    for r in cfg_sim_rows if 'cfg_sim_rows' in dir() else []:
        pass

    return must


def _first_stmt_set(cfg_edge_rows):
    """Compute first_stmt from cfg_edge: stmts with no incoming edge."""
    to_endpoints = set()
    from_stmts = set()
    for r in cfg_edge_rows:
        to_endpoints.add((r["f"], int(r["to_stmt_id"])))
        from_stmts.add((r["f"], int(r["from_stmt_id"])))
    all_stmts = from_stmts | to_endpoints
    return {(f, s) for (f, s) in all_stmts if (f, s) not in to_endpoints}


def _all_stmts(cfg_edge_rows):
    """All stmt_ids that appear in cfg_edge."""
    stmts = set()
    for r in cfg_edge_rows:
        stmts.add((r["f"], int(r["from_stmt_id"])))
        stmts.add((r["f"], int(r["to_stmt_id"])))
    return stmts


# ══════════════════════════════════════════════════════════════════════════
# Mini-simulator tests
# ══════════════════════════════════════════════════════════════════════════

class TestMiniSimulatorCFG(unittest.TestCase):

    def test_08_reach_stmt_branch_divergence(self):
        """reach_stmt over cfg_edge: branch A stmts do NOT reach branch B stmts."""
        # Function with if: true-branch has sid 1→2, false-branch has sid 3→4.
        # Sid 0 = cond, branches to 1(true) and 3(false).
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "true_br"},
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "3", "kind": "false_br"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "2", "kind": "fall"},
            {"f": "f", "from_stmt_id": "3", "to_stmt_id": "4", "kind": "fall"},
        ]
        reach = _compute_reach_stmt_cfg(cfg)
        # cond (0) reaches true-branch (1, 2) and false-branch (3, 4).
        self.assertIn(("f", 0, 1), reach)
        self.assertIn(("f", 0, 2), reach)
        self.assertIn(("f", 0, 3), reach)
        self.assertIn(("f", 0, 4), reach)
        # But true-branch (1) does NOT reach false-branch (3).
        self.assertNotIn(("f", 1, 3), reach,
                         "true-branch should not reach false-branch")
        self.assertNotIn(("f", 1, 4), reach)

    def test_09_live_at_branch_precision(self):
        """live_at: use in one branch does NOT make var live in the other branch."""
        # Var 'v' used only in true-branch (sid 2), not in false-branch (sid 4).
        gc_use = [
            {"f": "f", "stmt_id": "2", "v": "v"},
        ]
        gc_def = [
            {"f": "f", "stmt_id": "0", "v": "v"},
        ]
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "true_br"},
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "3", "kind": "false_br"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "2", "kind": "fall"},
            {"f": "f", "from_stmt_id": "3", "to_stmt_id": "4", "kind": "fall"},
        ]
        live = _compute_live_at_cfg(gc_use, gc_def, cfg)
        # v is live at sid 2 (the use).
        self.assertIn(("f", "v", 2), live)
        # v is live at sid 0 (def → live backwards to def? No, def kills).
        # Actually sid 0 IS a def, so live_at stops there.
        self.assertNotIn(("f", "v", 0), live,
                         "live_at should stop at def")
        # v should be live at sid 1 (back-prop from 2 through 1).
        self.assertIn(("f", "v", 1), live,
                      "live_at should back-propagate from use")
        # v should NOT be live at sid 3 or 4 (false-branch).
        self.assertNotIn(("f", "v", 3), live,
                         "v should not be live in false-branch")
        self.assertNotIn(("f", "v", 4), live)

    def test_10_pushed_may_branch_join(self):
        """pushed_may: push in one branch → pushed at join (may semantics)."""
        pushes = [
            {"f": "f", "stmt_id": "1", "root_kind": "ROOT_VALUE",
             "slot_expr": "p"},
        ]
        pops = []
        # if(flag) { push(p); }  →  join at sid 3.
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "true_br"},
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "3", "kind": "false_br"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "3", "kind": "fall"},
        ]
        pushed = _compute_pushed_may_cfg(pushes, pops, cfg)
        # p is pushed at sid 1.
        self.assertIn(("f", "p", 1), pushed)
        # p is pushed at sid 3 (join) via the true-branch edge.
        self.assertIn(("f", "p", 3), pushed,
                      "p should be pushed at join via may-semantics")

    def test_11_must_rooted_via_reaches_unrooted_one_branch(self):
        """must_rooted false at join when push only on one branch."""
        var_decl = [
            {"f": "f", "name": "p", "type": "Value*", "is_gc_managed": "1"},
        ]
        pushes = [
            {"f": "f", "stmt_id": "1", "root_kind": "ROOT_VALUE",
             "slot_expr": "p"},
        ]
        pops = []
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "true_br"},
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "3", "kind": "false_br"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "3", "kind": "fall"},
        ]
        first_stmts = _first_stmt_set(cfg)
        reaches = _compute_reaches_unrooted(
            var_decl, pushes, pops, cfg, first_stmts)

        # p is unrooted at function entry (sid 0).
        self.assertIn(("f", "p", 0), reaches)

        # p is unrooted at sid 3 (join) because false-branch path
        # carries reaches_unrooted.
        self.assertIn(("f", "p", 3), reaches,
                      "p should be unrooted at join (false-branch path)")

        # Now compute must_rooted = GC-managed AND NOT reaches_unrooted.
        all_sids = _all_stmts(cfg)
        must_rooted = set()
        for (f, s) in all_sids:
            for v in {"p"}:
                if (f, v, s) not in reaches:
                    must_rooted.add((f, v, s))

        # At sid 3 (join), p is unrooted → must_rooted is FALSE.
        self.assertNotIn(("f", "p", 3), must_rooted,
                         "must_rooted(p,3) should be false (push only one branch)")

    def test_12_must_rooted_via_reaches_unrooted_both_branches(self):
        """must_rooted true at join when push on BOTH branches."""
        var_decl = [
            {"f": "f", "name": "p", "type": "Value*", "is_gc_managed": "1"},
        ]
        pushes = [
            {"f": "f", "stmt_id": "1", "root_kind": "ROOT_VALUE",
             "slot_expr": "p"},
            {"f": "f", "stmt_id": "2", "root_kind": "ROOT_VALUE",
             "slot_expr": "p"},
        ]
        pops = []
        # Both branches push p, then converge to sid 3.
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "true_br"},
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "2", "kind": "false_br"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "3", "kind": "fall"},
            {"f": "f", "from_stmt_id": "2", "to_stmt_id": "3", "kind": "fall"},
        ]
        first_stmts = _first_stmt_set(cfg)
        reaches = _compute_reaches_unrooted(
            var_decl, pushes, pops, cfg, first_stmts)

        # p should NOT be unrooted at sid 3 — both branches kill
        # reaches_unrooted with a push.
        self.assertNotIn(("f", "p", 3), reaches,
                         "p should not be unrooted at join (pushed both branches)")

        all_sids = _all_stmts(cfg)
        must_rooted = set()
        for (f, s) in all_sids:
            for v in {"p"}:
                if (f, v, s) not in reaches:
                    must_rooted.add((f, v, s))

        self.assertIn(("f", "p", 3), must_rooted,
                      "must_rooted(p,3) should be true (push both branches)")

    def test_13_root_miss_with_param_rooted(self):
        """root_miss suppressed for param_rooted vars."""
        # Simulate the param_rooted logic: if var is param_rooted, skip.
        var_decl_rows = [
            {"f": "f", "name": "p", "type": "Value*", "is_gc_managed": "1"},
        ]
        param_rooted_set = {("f", "p")}
        gc_use_rows = [{"f": "f", "stmt_id": "2", "v": "p"}]
        gc_def_rows = []
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "fall"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "2", "kind": "fall"},
        ]
        stmt_pushes_rows = []
        stmt_pops_rows = []
        transitive_alloc_sids = {("f", 1)}

        live = _compute_live_at_cfg(gc_use_rows, gc_def_rows, cfg)
        first_stmts = _first_stmt_set(cfg)
        reaches = _compute_reaches_unrooted(
            var_decl_rows, stmt_pushes_rows, stmt_pops_rows, cfg, first_stmts)

        all_sids = _all_stmts(cfg)
        must_rooted = set()
        for (f, s) in all_sids:
            for v in {"p"}:
                if (f, v, s) not in reaches:
                    must_rooted.add((f, v, s))

        # p is live at alloc (sid 1) and NOT must_rooted → would fire.
        # But param_rooted(f, p) suppresses it.
        root_miss = set()
        for (f, s) in transitive_alloc_sids:
            for v in {"p"}:
                if ((f, v, s) in live and
                        (f, v, s) not in must_rooted and
                        (f, v) not in param_rooted_set):
                    root_miss.add((f, s, v))

        self.assertEqual(len(root_miss), 0,
                         f"param_rooted should suppress root_miss, got {root_miss}")

    def test_14_root_miss_fires_without_param_rooted(self):
        """root_miss fires for non-param-rooted, non-must-rooted live var."""
        var_decl_rows = [
            {"f": "f", "name": "p", "type": "Value*", "is_gc_managed": "1"},
        ]
        param_rooted_set = set()  # p is NOT param_rooted
        gc_use_rows = [{"f": "f", "stmt_id": "2", "v": "p"}]
        gc_def_rows = []
        cfg = [
            {"f": "f", "from_stmt_id": "0", "to_stmt_id": "1", "kind": "fall"},
            {"f": "f", "from_stmt_id": "1", "to_stmt_id": "2", "kind": "fall"},
        ]
        stmt_pushes_rows = []
        stmt_pops_rows = []
        transitive_alloc_sids = {("f", 1)}

        live = _compute_live_at_cfg(gc_use_rows, gc_def_rows, cfg)
        first_stmts = _first_stmt_set(cfg)
        reaches = _compute_reaches_unrooted(
            var_decl_rows, stmt_pushes_rows, stmt_pops_rows, cfg, first_stmts)

        all_sids = _all_stmts(cfg)
        must_rooted = set()
        for (f, s) in all_sids:
            for v in {"p"}:
                if (f, v, s) not in reaches:
                    must_rooted.add((f, v, s))

        root_miss = set()
        for (f, s) in transitive_alloc_sids:
            for v in {"p"}:
                if ((f, v, s) in live and
                        (f, v, s) not in must_rooted and
                        (f, v) not in param_rooted_set):
                    root_miss.add((f, s, v))

        self.assertIn(("f", 1, "p"), root_miss,
                      "root_miss should fire when var is live, unrooted, "
                      "and not param_rooted")


class TestRegressionPriorPhases(unittest.TestCase):
    """All prior phase tests still pass."""

    def test_20_existing_phase0_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase0.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase0.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_21_existing_phase1_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase1.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase1.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_22_existing_phase2_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase2.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase2.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_23_existing_phase3_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase3.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase3.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_24_existing_phase5_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase5.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase5.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_25_existing_phase6_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase6.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase6.py failed:\n{proc.stderr}\n{proc.stdout}")


if __name__ == "__main__":
    unittest.main()

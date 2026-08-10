#!/usr/bin/env python3
"""test_phase6.py — Phase 6 calibration tests for gc-verify.

Validates:
  1. call_site emitted for all CallExprs (incl. non-seed callees) → feeds
     transitive_alloc_site.
  2. array_store emitted for ArraySubscriptExpr LHS with a GC barrier-relevant
     base (Value*/ValueArray*).
  3. array_store filtered for non-GC / non-barrier-relevant bases.
  4. UnaryOperator base unwrap in _extract_base ((*env)[i] → env).
  5. Mini-simulators:
     - transitive_alloc_site: indirect callers included, non-may-collect excluded.
     - single_store_unbarriered + barrier_covers_store (array_store-keyed).
     - depth + push_pop_balance: balanced clean, push-no-pop fires,
       pop-no-push fires, pop_to resets clean, deep nesting clean.
  6. All existing Phase 0/1/2/3/5 tests still pass (regression).

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
    """Run the AstVisitor on a synthetic AST dict, return parsed CSVs."""
    with tempfile.TemporaryDirectory(prefix="gc-verify-phase6-") as tmp:
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
# Python mini-simulators of the Phase 6 Datalog rules
# ══════════════════════════════════════════════════════════════════════════

def _compute_transitive_alloc_site(call_site_rows, may_collect_set):
    """Compute transitive_alloc_site(f, s) from call_site + may_collect.

    call_site rows are dicts with keys f/stmt_id/callee.  A site is an
    allocating site iff its callee is in may_collect.
    """
    out = set()
    for r in call_site_rows:
        if r["callee"] in may_collect_set:
            out.add((r["f"], int(r["stmt_id"])))
    return out


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


def _compute_barrier_covers_store(
    array_store_rows, stmt_barrier_rows, stmt_allocs_rows, reach_set
):
    """Compute barrier_covers_store(f, s_store, base, s_alloc)."""
    covers = set()
    for s in array_store_rows:
        f = s["f"]
        store_sid = int(s["stmt_id"])
        base = s["base_var"]
        for b in stmt_barrier_rows:
            if b["f"] != f:
                continue
            if b["target_expr"] != base:
                continue
            bar_sid = int(b["stmt_id"])
            for a in stmt_allocs_rows:
                if a["f"] != f:
                    continue
                alloc_sid = int(a["stmt_id"])
                if ((f, store_sid, bar_sid) in reach_set and
                        (f, bar_sid, alloc_sid) in reach_set):
                    covers.add((f, store_sid, base, alloc_sid))
    return covers


def _compute_single_store_unbarriered(
    array_store_rows, stmt_allocs_rows, reach_set, covers_set,
):
    """Compute single_store_unbarriered(f, s_store, base)."""
    unbarriered = set()
    for s in array_store_rows:
        f = s["f"]
        store_sid = int(s["stmt_id"])
        base = s["base_var"]
        for a in stmt_allocs_rows:
            if a["f"] != f:
                continue
            alloc_sid = int(a["stmt_id"])
            if (f, store_sid, alloc_sid) not in reach_set:
                continue
            if (f, store_sid, base, alloc_sid) not in covers_set:
                unbarriered.add((f, store_sid, base))
    return unbarriered


def _compute_depth_and_balance(
    stmt_pushes_rows, stmt_pops_rows, stmt_allocs_rows,
    stmt_memcpy_rows, stmt_barrier_rows, next_stmt_rows,
):
    """Compute depth + push_pop_balance (single-path intra-BB semantics).

    Mirrors gc_safety.dl Rule 1: pushes/pop_ones/pop_tos along the linear
    next_stmt chain, pop_to resets depth to 0.  Returns the set of
    push_pop_balance(f, s, kind, depth) rows.
    """
    # any_stmt(f, s)
    any_stmt = set()
    for r in stmt_pushes_rows:
        any_stmt.add((r["f"], int(r["stmt_id"])))
    for r in stmt_pops_rows:
        any_stmt.add((r["f"], int(r["stmt_id"])))
    for r in stmt_allocs_rows:
        any_stmt.add((r["f"], int(r["stmt_id"])))
    for r in stmt_memcpy_rows:
        any_stmt.add((r["f"], int(r["stmt_id"])))
    for r in stmt_barrier_rows:
        any_stmt.add((r["f"], int(r["stmt_id"])))

    push_at = set()
    for r in stmt_pushes_rows:
        push_at.add((r["f"], int(r["stmt_id"])))

    pop_one_at = set()
    pop_to_at = set()
    for r in stmt_pops_rows:
        if r.get("pkind") == "pop_to":
            pop_to_at.add((r["f"], int(r["stmt_id"])))
        else:
            pop_one_at.add((r["f"], int(r["stmt_id"])))

    # next_stmt(f, from, to)
    nexts = {}
    for r in next_stmt_rows:
        nexts.setdefault((r["f"], int(r["from"])), set()).add(int(r["to"]))

    # has_successor(f, s)
    has_succ = set()
    for (f, s) in nexts.keys():
        has_succ.add((f, s))

    # func_exit(f, s) :- any_stmt(f, s), !has_successor(f, s)
    func_exit = set()
    for (f, s) in any_stmt:
        if (f, s) not in has_succ:
            func_exit.add((f, s))

    # first_stmt(f, s) :- any_stmt(f, s), !next_stmt(f, _, s)
    # (s never appears as the 'to' endpoint)
    to_endpoints = set()
    for r in next_stmt_rows:
        to_endpoints.add((r["f"], int(r["to"])))
    first_stmt = set()
    for (f, s) in any_stmt:
        if (f, s) not in to_endpoints:
            first_stmt.add((f, s))

    # depth fixpoint (single-path linear, but iterate to be safe)
    depth = {}
    for (f, s) in first_stmt:
        depth[(f, s)] = 0
    changed = True
    while changed:
        changed = False
        new_depth = dict(depth)
        for (f, s1), d in list(depth.items()):
            for s2 in nexts.get((f, s1), set()):
                if (f, s1) in pop_to_at:
                    nd = 0
                elif (f, s1) in push_at:
                    nd = d + 1
                elif (f, s1) in pop_one_at:
                    nd = d - 1
                else:
                    nd = d
                key = (f, s2)
                if new_depth.get(key) != nd:
                    new_depth[key] = nd
                    changed = True
        depth = new_depth

    out = set()
    # pop_without_push: pop_one_at(s), depth(s) == 0
    for (f, s) in pop_one_at:
        if depth.get((f, s)) == 0:
            out.add((f, s, "pop_without_push", 0))
    # push_never_popped: func_exit(s), depth(s) > 0
    for (f, s) in func_exit:
        d = depth.get((f, s))
        if d is not None and d > 0:
            out.add((f, s, "push_never_popped", d))
    return out


# ══════════════════════════════════════════════════════════════════════════
# Synthetic ASTs for Phase 6 extraction tests
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


def _arr_sub(base_name, idx_name):
    """ArraySubscriptExpr base_name[idx_name]."""
    return {
        "kind": "ArraySubscriptExpr",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": base_name}},
            {"kind": "DeclRefExpr", "referencedDecl": {"name": idx_name}},
        ],
    }


def _arr_sub_deref(base_name, idx_name):
    """ArraySubscriptExpr (*base_name)[idx_name] — UnaryOperator base."""
    return {
        "kind": "ArraySubscriptExpr",
        "inner": [
            {"kind": "UnaryOperator",
             "inner": [
                 {"kind": "DeclRefExpr",
                  "referencedDecl": {"name": base_name}},
             ]},
            {"kind": "DeclRefExpr", "referencedDecl": {"name": idx_name}},
        ],
    }


# AST: Value *env param; env[i] = v (array_store); env[j] = v;
#      call to non-seed helper and to gc_alloc (call_site).
ARRAY_STORE_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_array_store",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "env",
                    "type": {"qualType": "struct Value *"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "i",
                    "type": {"qualType": "int"},
                },
                {
                    "kind": "CompoundStmt",
                    "inner": [
                        # env[i] = v → array_store(env)
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                _arr_sub("env", "i"),
                                {"kind": "DeclRefExpr",
                                 "referencedDecl": {"name": "v"}},
                            ],
                        },
                        # (*env)[i] = v → array_store(env) via UnaryOperator
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                _arr_sub_deref("env", "i"),
                                {"kind": "DeclRefExpr",
                                 "referencedDecl": {"name": "v"}},
                            ],
                        },
                        # call to non-seed helper → call_site
                        _call_expr("call_closure_helper"),
                        # call to seed allocator → call_site + stmt_allocs
                        _call_expr("gc_alloc"),
                    ],
                },
            ],
        },
    ],
}

# AST: env is Instr* (non-barrier-relevant) — env[i] = v filtered out.
NON_GC_ARRAY_STORE_AST = {
    "kind": "TranslationUnitDecl",
    "inner": [
        {
            "kind": "FunctionDecl",
            "name": "test_non_gc_array_store",
            "type": {"qualType": "void"},
            "inner": [
                {
                    "kind": "ParmVarDecl",
                    "name": "instr",
                    "type": {"qualType": "struct Instr *"},
                },
                {
                    "kind": "ParmVarDecl",
                    "name": "i",
                    "type": {"qualType": "int"},
                },
                {
                    "kind": "CompoundStmt",
                    "inner": [
                        # instr[i] = v — Instr* is GC-managed but NOT
                        # barrier-relevant (like memcpy) → filtered.
                        {
                            "kind": "BinaryOperator",
                            "opcode": "=",
                            "inner": [
                                _arr_sub("instr", "i"),
                                {"kind": "DeclRefExpr",
                                 "referencedDecl": {"name": "v"}},
                            ],
                        },
                    ],
                },
            ],
        },
    ],
}


class TestExtractionPhase6(unittest.TestCase):
    def test_01_call_site_emitted_for_all_calls(self):
        """call_site emitted for non-seed and seed callees alike."""
        res = _run_visitor_on_ast(ARRAY_STORE_AST)
        sites = res["call_site"]
        callees = {r["callee"] for r in sites}
        self.assertIn("call_closure_helper", callees,
                      "non-seed helper should be in call_site")
        self.assertIn("gc_alloc", callees,
                      "seed allocator should be in call_site")
        self.assertEqual(sites[0]["f"], "test_array_store")

    def test_02_array_store_emitted_for_gc_base(self):
        """env[i]=v and (*env)[i]=v emit array_store(base=env)."""
        res = _run_visitor_on_ast(ARRAY_STORE_AST)
        stores = res["array_store"]
        bases = {(r["f"], r["base_var"]) for r in stores}
        self.assertIn(("test_array_store", "env"), bases,
                      "env should be a tracked array_store base")
        self.assertGreaterEqual(len(stores), 1)

    def test_03_array_store_filtered_for_non_barrier_base(self):
        """Instr* base does NOT emit array_store."""
        res = _run_visitor_on_ast(NON_GC_ARRAY_STORE_AST)
        stores = res["array_store"]
        self.assertEqual(len(stores), 0,
                         f"Instr* base should be filtered, got {stores}")

    def test_04_unary_op_base_unwrap(self):
        """_extract_base unwraps UnaryOperator deref to its inner DeclRef."""
        node = _arr_sub_deref("env", "i")
        # Run via the visitor machinery by extracting a base.
        with tempfile.TemporaryDirectory(prefix="gc-verify-phase6-unwrap-") as tmp:
            writer = extract.FactWriter(tmp)
            visitor = extract.AstVisitor(writer)
            base = visitor._extract_base(node)
            self.assertEqual(base, "env",
                             f"UnaryOperator base unwrap should give env, got {base!r}")


class TestMiniSimulatorRule3(unittest.TestCase):
    def test_05_transitive_alloc_site_includes_indirect(self):
        """Indirect callers (may_collect callee) are included."""
        call_sites = [
            {"f": "a", "stmt_id": "1", "callee": "gc_alloc"},
            {"f": "b", "stmt_id": "7", "callee": "call_closure1"},
            {"f": "c", "stmt_id": "3", "callee": "strlen"},
        ]
        # may_collect includes the indirect allocator call_closure1.
        may = {"gc_alloc", "call_closure1"}
        tas = _compute_transitive_alloc_site(call_sites, may)
        self.assertIn(("a", 1), tas, "direct seed allocator site")
        self.assertIn(("b", 7), tas, "indirect may_collect caller site")
        self.assertNotIn(("c", 3), tas, "non-may-collect callee excluded")

    def test_06_transitive_alloc_site_excludes_non_collect(self):
        """Callee not in may_collect → site excluded."""
        call_sites = [
            {"f": "d", "stmt_id": "5", "callee": "strlen"},
        ]
        may = {"gc_alloc"}
        tas = _compute_transitive_alloc_site(call_sites, may)
        self.assertEqual(tas, set())


class TestMiniSimulatorRule4(unittest.TestCase):
    def test_07_single_store_unbarriered_fires(self):
        """Store followed by alloc, no covering barrier → fires."""
        array_stores = [
            {"f": "f", "stmt_id": "1", "base_var": "env"},
        ]
        stmt_barriers = []
        stmt_allocs = [
            {"f": "f", "stmt_id": "3", "callee": "gc_alloc"},
        ]
        next_stmt = [
            {"f": "f", "from": "1", "to": "2"},
            {"f": "f", "from": "2", "to": "3"},
        ]
        reach = _compute_reach_stmt(next_stmt)
        covers = _compute_barrier_covers_store(
            array_stores, stmt_barriers, stmt_allocs, reach)
        unbar = _compute_single_store_unbarriered(
            array_stores, stmt_allocs, reach, covers)
        self.assertIn(("f", 1, "env"), unbar,
                      "unbarriered store should fire")

    def test_08_single_store_barriered_clean(self):
        """Store + barrier between store and alloc → clean."""
        array_stores = [
            {"f": "f", "stmt_id": "1", "base_var": "env"},
        ]
        stmt_barriers = [
            {"f": "f", "stmt_id": "2", "target_expr": "env"},
        ]
        stmt_allocs = [
            {"f": "f", "stmt_id": "3", "callee": "gc_alloc"},
        ]
        next_stmt = [
            {"f": "f", "from": "1", "to": "2"},
            {"f": "f", "from": "2", "to": "3"},
        ]
        reach = _compute_reach_stmt(next_stmt)
        covers = _compute_barrier_covers_store(
            array_stores, stmt_barriers, stmt_allocs, reach)
        unbar = _compute_single_store_unbarriered(
            array_stores, stmt_allocs, reach, covers)
        self.assertEqual(unbar, set(),
                         f"barriered store should be clean, got {unbar}")

    def test_09_single_store_no_alloc_clean(self):
        """Store with no following alloc → clean (nothing to protect)."""
        array_stores = [
            {"f": "f", "stmt_id": "1", "base_var": "env"},
        ]
        stmt_barriers = []
        stmt_allocs = []
        next_stmt = []
        reach = _compute_reach_stmt(next_stmt)
        covers = _compute_barrier_covers_store(
            array_stores, stmt_barriers, stmt_allocs, reach)
        unbar = _compute_single_store_unbarriered(
            array_stores, stmt_allocs, reach, covers)
        self.assertEqual(unbar, set())


class TestMiniSimulatorRule1(unittest.TestCase):
    def _empty(self):
        return [], [], [], [], [], []

    def test_10_balanced_clean(self):
        """push ... pop balanced along a path → clean."""
        pushes = [{"f": "f", "stmt_id": "1", "root_kind": "ROOT_VALUE",
                   "slot_expr": "v"}]
        pops = [{"f": "f", "stmt_id": "3", "pop_count": "1", "pkind": "pop_one"}]
        allocs = [{"f": "f", "stmt_id": "2", "callee": "gc_alloc"}]
        memcpy, barrier = [], []
        next_stmt = [
            {"f": "f", "from": "1", "to": "2"},
            {"f": "f", "from": "2", "to": "3"},
            {"f": "f", "from": "3", "to": "4"},
        ]
        # stmt 4 is the final any_stmt (e.g. a second alloc) so func_exit
        # sees depth 0 after the pop.
        allocs.append({"f": "f", "stmt_id": "4", "callee": "gc_alloc"})
        bal = _compute_depth_and_balance(
            pushes, pops, allocs, memcpy, barrier, next_stmt)
        self.assertEqual(bal, set(), f"balanced should be clean, got {bal}")

    def test_11_push_no_pop_fires(self):
        """push at exit (final stmt depth>0) → push_never_popped."""
        pushes = [{"f": "f", "stmt_id": "1", "root_kind": "ROOT_VALUE",
                   "slot_expr": "v"}]
        pops = []
        allocs = [{"f": "f", "stmt_id": "2", "callee": "gc_alloc"}]
        memcpy, barrier = [], []
        next_stmt = [
            {"f": "f", "from": "1", "to": "2"},
        ]
        bal = _compute_depth_and_balance(
            pushes, pops, allocs, memcpy, barrier, next_stmt)
        self.assertTrue(any(k == "push_never_popped" for _, _, k, _ in bal),
                        f"expected push_never_popped, got {bal}")

    def test_12_pop_no_push_fires(self):
        """pop with nothing pushed (depth 0) → pop_without_push."""
        pushes = []
        pops = [{"f": "f", "stmt_id": "1", "pop_count": "1", "pkind": "pop_one"}]
        allocs, memcpy, barrier = [], [], []
        next_stmt = []
        bal = _compute_depth_and_balance(
            pushes, pops, allocs, memcpy, barrier, next_stmt)
        self.assertTrue(any(k == "pop_without_push" for _, _, k, _ in bal),
                        f"expected pop_without_push, got {bal}")

    def test_13_pop_to_resets_clean(self):
        """pop_to resets depth to 0; no imbalance."""
        pushes = [{"f": "f", "stmt_id": "1", "root_kind": "ROOT_VALUE",
                   "slot_expr": "v"}]
        pops = [{"f": "f", "stmt_id": "2", "pop_count": "0", "pkind": "pop_to"}]
        allocs = [{"f": "f", "stmt_id": "3", "callee": "gc_alloc"}]
        memcpy, barrier = [], []
        next_stmt = [
            {"f": "f", "from": "1", "to": "2"},
            {"f": "f", "from": "2", "to": "3"},
        ]
        bal = _compute_depth_and_balance(
            pushes, pops, allocs, memcpy, barrier, next_stmt)
        self.assertEqual(bal, set(),
                         f"pop_to reset should be clean, got {bal}")

    def test_14_deep_nesting_clean(self):
        """10 balanced push/pop pairs + trailing neutral stmt → clean."""
        pushes, pops, allocs = [], [], []
        next_stmt = []
        sids = list(range(1, 31))  # 10 pushes, 10 allocs, 10 pops = 30 stmts
        for i, sid in enumerate(sids):
            if i % 3 == 0:
                pushes.append({"f": "f", "stmt_id": str(sid),
                               "root_kind": "ROOT_VALUE", "slot_expr": "v"})
            elif i % 3 == 1:
                allocs.append({"f": "f", "stmt_id": str(sid),
                               "callee": "gc_alloc"})
            else:
                pops.append({"f": "f", "stmt_id": str(sid),
                             "pop_count": "1", "pkind": "pop_one"})
            if sid < sids[-1]:
                next_stmt.append({"f": "f", "from": str(sid),
                                  "to": str(sid + 1)})
        # Neutral final alloc so the func_exit stmt sees depth 0 after the
        # last pop (depth at a statement is the pre-execution depth).
        allocs.append({"f": "f", "stmt_id": "31", "callee": "gc_alloc"})
        next_stmt.append({"f": "f", "from": "30", "to": "31"})
        memcpy, barrier = [], []
        bal = _compute_depth_and_balance(
            pushes, pops, allocs, memcpy, barrier, next_stmt)
        self.assertEqual(bal, set(),
                         f"deep balanced nesting should be clean, got {bal}")


class TestRegressionPriorPhases(unittest.TestCase):
    def test_15_existing_phase0_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase0.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase0.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_16_existing_phase1_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase1.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase1.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_17_existing_phase2_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase2.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase2.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_18_existing_phase3_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase3.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase3.py failed:\n{proc.stderr}\n{proc.stdout}")

    def test_19_existing_phase5_tests_pass(self):
        test_file = TOOLS_DIR / "tests" / "test_phase5.py"
        proc = subprocess.run([sys.executable, str(test_file)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         f"test_phase5.py failed:\n{proc.stderr}\n{proc.stdout}")


if __name__ == "__main__":
    unittest.main()

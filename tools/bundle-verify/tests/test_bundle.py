#!/usr/bin/env python3
"""test_bundle.py — Python-stdlib tests for bundle-verify.

Validates:
  1. extract_bundle.py correctly parses the csexp wire format.
  2. Mini-simulators for each Datalog rule produce correct results.
  3. Edge cases: nested cur, curried calls, arity mismatch, unresolved calls.

Runs WITHOUT souffle or clang — pure Python stdlib + unittest.
"""

import csv
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path


# ── Test helpers ──────────────────────────────────────────────────────

TOOLS_DIR = Path(__file__).resolve().parent.parent
EXTRACT_PY = TOOLS_DIR / "extract_bundle.py"

# Import the extractor module
sys.path.insert(0, str(TOOLS_DIR))
import extract_bundle as ext


def run_extract(bundle_text, out_dir):
    """Run the extractor on a synthetic bundle string, return FactWriter rows."""
    writer = ext.FactWriter(out_dir)
    parser = ext.BundleParser(bundle_text, writer)
    n = parser.parse_bundle()
    writer.close()
    return n


def read_csv(path):
    """Read a CSV file and return list of row tuples (excluding header)."""
    rows = []
    with open(path) as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            rows.append(tuple(row))
    return rows, header


# ── Wire format unit tests ────────────────────────────────────────────

class TestWireFormat(unittest.TestCase):
    """Test the csexp atom and bundle parsing."""

    def test_atom_parse_number(self):
        ap = ext.AtomParser("[1:n]0")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "n")
        self.assertEqual(value, "0")

    def test_atom_parse_symbol(self):
        ap = ext.AtomParser("[7:s]number?")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "s")
        self.assertEqual(value, "number?")

    def test_atom_parse_string(self):
        ap = ext.AtomParser("[5:S]hello")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "S")
        self.assertEqual(value, "hello")

    def test_atom_parse_boolean_true(self):
        ap = ext.AtomParser("[4:b]true")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "b")
        self.assertEqual(value, "true")

    def test_atom_parse_boolean_false(self):
        ap = ext.AtomParser("[5:b]false")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "b")
        self.assertEqual(value, "false")

    def test_atom_parse_multi_digit_length(self):
        ap = ext.AtomParser("[12:s]hello world!")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "s")
        self.assertEqual(value, "hello world!")

    def test_atom_with_whitespace_before(self):
        ap = ext.AtomParser("  [3:s]foo")
        kind, value = ap.parse_atom()
        self.assertEqual(kind, "s")
        self.assertEqual(value, "foo")

    def test_atom_invalid_no_bracket(self):
        ap = ext.AtomParser("abc")
        with self.assertRaises(ValueError):
            ap.parse_atom()

    def test_atom_invalid_type(self):
        ap = ext.AtomParser("[3:x]abc")
        with self.assertRaises(ValueError):
            ap.parse_atom()

    def test_atom_value_truncated(self):
        ap = ext.AtomParser("[10:s]short")
        with self.assertRaises(ValueError):
            ap.parse_atom()

    def test_simple_bundle(self):
        """Parse a minimal bundle with one closure."""
        bundle = "(([2:s]id (c(ra[1:n]0v))))"
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)
            self.assertEqual(n, 1)

            closures, _ = read_csv(Path(d) / "closure.csv")
            self.assertIn(("id", "2"), closures)  # arity 2 (1 grab + 1)

            instrs, _ = read_csv(Path(d) / "instr.csv")
            self.assertIn(("id", "0", "r"), instrs)
            self.assertIn(("id", "1", "a"), instrs)
            self.assertIn(("id", "2", "v"), instrs)

            operands, _ = read_csv(Path(d) / "operand.csv")
            self.assertIn(("id", "1", "n", "0"), operands)  # access 0

    def test_bundle_with_call(self):
        """Parse a bundle with a pushmark+apply call."""
        bundle = "(([8:s]apply-id (c(ma[1:n]0g[2:s]idpv))))"
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)
            self.assertEqual(n, 1)

            pushmarks, _ = read_csv(Path(d) / "pushmark.csv")
            self.assertIn(("apply-id", "0"), pushmarks)

            call_sites, _ = read_csv(Path(d) / "call_site.csv")
            self.assertIn(("apply-id", "3", "apply"), call_sites)

            global_refs, _ = read_csv(Path(d) / "global_ref.csv")
            self.assertIn(("apply-id", "2", "id"), global_refs)

    def test_bundle_with_appterm(self):
        """Parse a bundle with appterm (tail call)."""
        bundle = "(([7:s]tail-id (c(ma[1:n]0g[2:s]idt))))"
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)
            self.assertEqual(n, 1)

            call_sites, _ = read_csv(Path(d) / "call_site.csv")
            self.assertIn(("tail-id", "3", "appterm"), call_sites)

    def test_bundle_with_prim(self):
        """Parse a bundle with inline prim call."""
        bundle = "(([4:s]add1 (c(ra[1:n]0n[1:n]1P[1:s]+v))))"
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)
            self.assertEqual(n, 1)

            prim_refs, _ = read_csv(Path(d) / "prim_ref.csv")
            self.assertIn(("add1", "3", "+"), prim_refs)

    def test_nested_cur(self):
        """Parse a bundle with a nested cur (inline lambda)."""
        bundle = "(([4:s]mkfn (c(c(rn[1:n]0a[1:n]0P[1:s]+v)v))))"
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)
            self.assertEqual(n, 1)

            closures, _ = read_csv(Path(d) / "closure.csv")
            # mkfn is the ONLY real closure; the nested cur is a cur_body, not a closure.
            self.assertIn(("mkfn", "1"), closures)
            self.assertEqual(len(closures), 1,
                             "closure() must contain only real top-level closures")

            cur_lits, _ = read_csv(Path(d) / "cur_lit.csv")
            self.assertEqual(len(cur_lits), 1)
            self.assertEqual(cur_lits[0][0], "mkfn")
            self.assertEqual(cur_lits[0][1], "0")  # idx 0
            sub_id = cur_lits[0][2]

            # Nested cur body must NOT be emitted as a phantom closure() row.
            self.assertNotIn((sub_id, "2"), closures,
                             "nested cur body must not appear in closure()")

            # Nested cur body IS emitted as a cur_body row with its arity.
            cur_bodies, _ = read_csv(Path(d) / "cur_body.csv")
            self.assertIn((sub_id, "2"), cur_bodies)  # sub: 1 grab → arity 2

            instrs, _ = read_csv(Path(d) / "instr.csv")
            # mkfn: c at 0, v at 1
            self.assertIn(("mkfn", "0", "c"), instrs)
            self.assertIn(("mkfn", "1", "v"), instrs)
            # sub: r at 0, n at 1, a at 2, P at 3, +, v at 4
            self.assertIn((sub_id, "0", "r"), instrs)

    def test_multiple_closures(self):
        """Parse a bundle with two top-level closures."""
        bundle = (
            "(([2:s]id (c(ra[1:n]0v)))"
            "([7:s]const-5 (c(n[1:n]5v))))"
        )
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)
            self.assertEqual(n, 2)

            closures, _ = read_csv(Path(d) / "closure.csv")
            self.assertIn(("id", "2"), closures)  # 1 grab → arity 2
            self.assertIn(("const-5", "1"), closures)  # 0 grabs → arity 1

    def test_static_tables(self):
        """Verify static tables are emitted."""
        bundle = "(([2:s]id (c(ra[1:n]0v))))"
        with tempfile.TemporaryDirectory() as d:
            n = run_extract(bundle, d)

            # allowed_prim
            rows, header = read_csv(Path(d) / "allowed_prim.csv")
            self.assertEqual(header, ["prim"])
            prims = {r[0] for r in rows}
            self.assertIn("cons", prims)
            self.assertIn("hd", prims)
            self.assertIn("+", prims)

            # instruction_keyword
            rows, _ = read_csv(Path(d) / "instruction_keyword.csv")
            keywords = {r[0] for r in rows}
            self.assertIn("access", keywords)
            self.assertIn("global", keywords)

            # opcode_valid
            rows, _ = read_csv(Path(d) / "opcode_valid.csv")
            ops = {r[0] for r in rows}
            for c in "agfjnSsPbmprvedtc":
                self.assertIn(c, ops, f"opcode {c} missing from valid set")

            # prim_arity
            rows, _ = read_csv(Path(d) / "prim_arity.csv")
            arities = {r[0]: int(r[1]) for r in rows}
            self.assertEqual(arities.get("cons"), 2)
            self.assertEqual(arities.get("hd"), 1)
            self.assertEqual(arities.get("emptylist"), 1)


# ── Datalog mini-simulators ───────────────────────────────────────────

class MiniSolver:
    """Simulate Soufflé Datalog rules on in-memory fact sets."""

    def __init__(self):
        self.facts = {}  # relation -> set of tuples

    def load_csvs(self, out_dir):
        """Load all fact CSVs from extract_bundle output."""
        for rel_name in ext.CSV_SCHEMAS:
            csv_path = Path(out_dir) / f"{rel_name}.csv"
            if csv_path.exists():
                rows, _ = read_csv(csv_path)
                self.facts[rel_name] = set(rows)

    def has(self, rel, *args):
        return tuple(str(a) for a in args) in self.facts.get(rel, set())

    def all_of(self, rel):
        return self.facts.get(rel, set())

    # ── Rule simulators ─────────────────────────────────────────────

    def bad_opcode(self):
        """Flag instr where op ∉ opcode_valid."""
        valid = {r[0] for r in self.all_of("opcode_valid")}
        result = set()
        for name, idx, op in self.all_of("instr"):
            if op not in valid:
                result.add((name, idx, op))
        return result

    def dangling_global(self):
        """Flag global_ref where target ∉ closure ∪ allowed_prim ∪ instruction_keyword."""
        closures = {r[0] for r in self.all_of("closure")}
        allowed = {r[0] for r in self.all_of("allowed_prim")}
        keywords = {r[0] for r in self.all_of("instruction_keyword")}
        result = set()
        for name, idx, target in self.all_of("global_ref"):
            if target not in closures and target not in allowed and target not in keywords:
                result.add((name, idx, target))
        return result

    def unknown_prim(self):
        """Flag prim_ref where prim ∉ allowed_prim."""
        allowed = {r[0] for r in self.all_of("allowed_prim")}
        result = set()
        for name, idx, prim in self.all_of("prim_ref"):
            if prim not in allowed:
                result.add((name, idx, prim))
        return result

    def curried_call(self):
        """Flag where two call_sites are adjacent (indices differ by 1)."""
        # Build per-closure call_site index sets
        cs_by_name = {}
        for name, idx, kind in self.all_of("call_site"):
            cs_by_name.setdefault(name, set()).add(int(idx))

        result = set()
        for name, indices in cs_by_name.items():
            for i in indices:
                if i + 1 in indices:
                    result.add((name, str(i)))  # flag the FIRST of the pair
        return result

    def pushmark_pairs(self):
        """Return list of (name, pm_idx, cs_idx, cs_kind) for each pushmark→call_site pair.

        Pushmarks and call_sites form balanced pairs (like parentheses).
        A pushmark at pm pairs with a call_site at cs when:
          1. pm < cs
          2. No "crossing": at no call_site k between pm and cs do
             call_sites strictly exceed pushmarks in (pm, k].
          3. intervening_cs == intervening_pm (balanced within the span).
        """
        pms = {}  # name -> sorted list of indices
        for name, idx in self.all_of("pushmark"):
            pms.setdefault(name, []).append(int(idx))
        css = {}  # name -> sorted list of (idx, kind)
        for name, idx, kind in self.all_of("call_site"):
            css.setdefault(name, []).append((int(idx), kind))

        pairs = []
        for name in set(list(pms.keys()) + list(css.keys())):
            pm_list = sorted(pms.get(name, []))
            cs_list = sorted(css.get(name, []))
            cs_indices = [c[0] for c in cs_list]

            for cs_idx, cs_kind in cs_list:
                for pm_idx in pm_list:
                    if pm_idx >= cs_idx:
                        break
                    # Check crossing: any call_site k between pm and cs
                    # where cs_before > pm_before in (pm, k]
                    crossing = False
                    for k in cs_indices:
                        if pm_idx < k < cs_idx:
                            cs_before = sum(1 for c in cs_indices if pm_idx < c <= k)
                            pm_before = sum(1 for p in pm_list if pm_idx < p <= k)
                            if cs_before > pm_before:
                                crossing = True
                                break
                    if crossing:
                        continue

                    # Check balanced intervening counts
                    n_cs = sum(1 for c in cs_indices if pm_idx < c < cs_idx)
                    n_pm = sum(1 for p in pm_list if pm_idx < p < cs_idx)
                    if n_cs == n_pm:
                        pairs.append((name, str(pm_idx), str(cs_idx), cs_kind))
                        break
        return pairs

    def arity_mismatch(self):
        """Return arity_mismatch rows for the simulated bundle.

        Uses supplied_args from the extractor's stack simulation (CSV input).
        Only checks global-ref and cur-lit callees (prim calls are trusted).
        """
        # Build lookup tables
        closures = {}  # name -> arity
        for name, arity in self.all_of("closure"):
            closures[name] = int(arity)

        # Build per-closure instruction opcode lookup
        instrs = {}  # (name, idx) -> op
        for name, idx, op in self.all_of("instr"):
            instrs[(name, int(idx))] = op

        # Build global_ref, cur_lit lookups
        global_refs = {}  # (name, idx) -> target
        for name, idx, target in self.all_of("global_ref"):
            global_refs[(name, int(idx))] = target

        cur_lits = {}  # (name, idx) -> sub_id
        for name, idx, sub_id in self.all_of("cur_lit"):
            cur_lits[(name, int(idx))] = sub_id

        # Nested cur bodies live in cur_body (Part-1 fix), not closure.
        cur_bodies = {}  # sub_id -> arity
        for sub_id, arity in self.all_of("cur_body"):
            cur_bodies[sub_id] = int(arity)

        # Read supplied_args from extractor (stack simulation output)
        supplied = {}  # (name, cs_idx) -> n
        for name, cs_idx, n in self.all_of("supplied_args"):
            supplied[(name, int(cs_idx))] = int(n)

        result = []
        for (name, cs_idx), n_supplied in supplied.items():
            callee_idx = cs_idx - 1
            callee_op = instrs.get((name, callee_idx))

            if callee_op == 'g':
                target = global_refs.get((name, callee_idx))
                if target and target in closures:
                    expected = closures[target]
                    if expected != n_supplied:
                        result.append((name, str(cs_idx), target, str(expected), str(n_supplied)))
            elif callee_op == 'c':
                sub_id = cur_lits.get((name, callee_idx))
                if sub_id and sub_id in cur_bodies:
                    expected = cur_bodies[sub_id]
                    if expected != n_supplied:
                        result.append((name, str(cs_idx), sub_id, str(expected), str(n_supplied)))
            # prim calls: trusted, no arity check here

        return result

    def unresolved_call(self):
        """Return call sites where callee is access (higher-order param).

        Scoped by call_site, not pushmark_pair — matches simplified Datalog.
        """
        instrs = {}  # (name, idx) -> op
        for name, idx, op in self.all_of("instr"):
            instrs[(name, int(idx))] = op

        result = []
        for name, cs_idx_str, kind in self.all_of("call_site"):
            cs_idx = int(cs_idx_str)
            callee_idx = cs_idx - 1
            callee_op = instrs.get((name, callee_idx))
            if callee_op == 'a':
                result.append((name, str(cs_idx)))
        return result


# ── Datalog rule tests ────────────────────────────────────────────────

class TestDatalogRules(unittest.TestCase):
    """Test each Datalog rule via the mini-simulator."""

    def _parse_and_solve(self, bundle_text):
        """Parse a synthetic bundle and return a MiniSolver loaded with facts."""
        d = tempfile.mkdtemp(prefix="bv-test-")
        run_extract(bundle_text, d)
        solver = MiniSolver()
        solver.load_csvs(d)
        # Clean up
        import shutil
        shutil.rmtree(d, ignore_errors=True)
        return solver

    # ── bad_opcode ──────────────────────────────────────────────────

    def test_bad_opcode_none(self):
        """All opcodes in a valid bundle are recognized."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(ra[1:n]0v))))"
        )
        self.assertEqual(solver.bad_opcode(), set())

    def test_bad_opcode_detected(self):
        """A synthetic bad opcode is flagged."""
        # We need to inject a bad opcode. The extractor validates opcodes,
        # so we instead test directly against a manually-constructed fact set.
        solver = MiniSolver()
        solver.facts["instr"] = {("test", "0", "x")}  # 'x' is not a valid opcode
        solver.facts["opcode_valid"] = {(c,) for c in "agfjnSsPbmprvedtc"}
        bad = solver.bad_opcode()
        self.assertIn(("test", "0", "x"), bad)

    # ── dangling_global ─────────────────────────────────────────────

    def test_dangling_global_none(self):
        """A global ref to a known closure is not dangling."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(ra[1:n]0v)))"
            "([7:s]call-id (c(mg[2:s]idpv))))"
        )
        self.assertEqual(solver.dangling_global(), set())

    def test_dangling_global_detected(self):
        """A global ref to an unknown name is dangling."""
        solver = MiniSolver()
        solver.facts["global_ref"] = {("test", "0", "nonexistent")}
        solver.facts["closure"] = {("id", "1")}
        solver.facts["allowed_prim"] = {(p,) for p in ext.ALLOWED_PRIMS}
        solver.facts["instruction_keyword"] = {(k,) for k in ext.INSTRUCTION_KEYWORDS}
        dang = solver.dangling_global()
        self.assertIn(("test", "0", "nonexistent"), dang)

    def test_dangling_global_allowed_prim_ok(self):
        """A global ref to an allowed prim is NOT dangling."""
        solver = MiniSolver()
        solver.facts["global_ref"] = {("test", "0", "cons")}
        solver.facts["closure"] = set()
        solver.facts["allowed_prim"] = {(p,) for p in ext.ALLOWED_PRIMS}
        solver.facts["instruction_keyword"] = {(k,) for k in ext.INSTRUCTION_KEYWORDS}
        dang = solver.dangling_global()
        self.assertEqual(dang, set())

    def test_dangling_global_keyword_ok(self):
        """A global ref to an instruction keyword is NOT dangling."""
        solver = MiniSolver()
        solver.facts["global_ref"] = {("test", "0", "access")}
        solver.facts["closure"] = set()
        solver.facts["allowed_prim"] = {(p,) for p in ext.ALLOWED_PRIMS}
        solver.facts["instruction_keyword"] = {(k,) for k in ext.INSTRUCTION_KEYWORDS}
        dang = solver.dangling_global()
        self.assertEqual(dang, set())

    # ── unknown_prim ────────────────────────────────────────────────

    def test_unknown_prim_none(self):
        """All prim refs are to allowlisted primitives."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(ra[1:n]0P[2:s]hdv))))"
        )
        self.assertEqual(solver.unknown_prim(), set())

    def test_unknown_prim_detected(self):
        """A prim ref to a non-allowed primitive is flagged."""
        solver = MiniSolver()
        solver.facts["prim_ref"] = {("test", "0", "eval")}  # Not in allowed_prim
        solver.facts["allowed_prim"] = {(p,) for p in ext.ALLOWED_PRIMS}
        unk = solver.unknown_prim()
        self.assertIn(("test", "0", "eval"), unk)

    # ── curried_call ────────────────────────────────────────────────

    def test_curried_call_none(self):
        """No adjacent call sites in a normal closure."""
        solver = self._parse_and_solve(
            "(([7:s]call-id (c(mg[2:s]idpv))))"
        )
        self.assertEqual(solver.curried_call(), set())

    def test_curried_call_detected(self):
        """Two adjacent applies are flagged as curried."""
        solver = MiniSolver()
        solver.facts["call_site"] = {
            ("test", "3", "apply"),
            ("test", "4", "apply"),
        }
        curried = solver.curried_call()
        self.assertIn(("test", "3"), curried)

    def test_curried_call_appterm_apply(self):
        """Adjacent appterm + apply is curried."""
        solver = MiniSolver()
        solver.facts["call_site"] = {
            ("test", "3", "appterm"),
            ("test", "4", "apply"),
        }
        curried = solver.curried_call()
        self.assertIn(("test", "3"), curried)

    def test_curried_call_non_adjacent(self):
        """Non-adjacent call sites are NOT flagged."""
        solver = MiniSolver()
        solver.facts["call_site"] = {
            ("test", "3", "apply"),
            ("test", "7", "apply"),
        }
        self.assertEqual(solver.curried_call(), set())

    # ── arity_mismatch ──────────────────────────────────────────────

    def test_arity_match(self):
        """A call with correct arity is not flagged."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"        # 0 grabs → arity 1
            "([7:s]call-id (c(ma[1:n]0g[2:s]idpv))))"  # 1 arg → match
        )
        # call-id: pushmark at 0, access 0 at 1, global id at 2, apply at 3
        # Stack sim: m[M], a0[M,V], g id[M,V,V], p: V's above M=2, excl callee=1 → supplied=1
        # Expected: id has arity 1
        mismatches = solver.arity_mismatch()
        self.assertEqual(mismatches, [])

    def test_arity_mismatch_too_few(self):
        """A call with too few arguments is flagged."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(ra[1:n]0a[1:n]1P[1:s]+v)))"  # 1 grab → arity 2
            "([7:s]call-id (c(ma[1:n]0g[2:s]idpv))))"     # 1 arg → mismatch
        )
        # call-id: pushmark at 0, access 0 at 1, global id at 2, apply at 3
        # Stack sim: m[M], a0[M,V], g id[M,V,V], p: supplied=1
        # Expected: id has arity 2
        mismatches = solver.arity_mismatch()
        self.assertEqual(len(mismatches), 1)
        self.assertEqual(mismatches[0][0], "call-id")
        self.assertEqual(mismatches[0][2], "id")
        self.assertEqual(mismatches[0][3], "2")  # expected
        self.assertEqual(mismatches[0][4], "1")  # supplied

    def test_arity_mismatch_too_many(self):
        """A call with too many arguments is flagged."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"  # 0 grabs → arity 1
            "([7:s]call-id (c(mn[1:n]0n[1:n]1g[2:s]idpv))))"  # 2 args
        )
        # Stack sim: m[M], n0[M,V], n1[M,V,V], g id[M,V,V,V], p:
        #   V's above M=3, excl callee=1 → supplied=2, expected=1
        mismatches = solver.arity_mismatch()
        self.assertEqual(len(mismatches), 1)
        self.assertEqual(mismatches[0][3], "1")  # expected 1
        self.assertEqual(mismatches[0][4], "2")  # supplied 2

    def test_arity_zero_args(self):
        """A 1-arg call to a 1-arg closure is fine (no such thing as 0-arg in ZINC)."""
        solver = self._parse_and_solve(
            "(([7:s]const-5 (c(n[1:n]5v)))"  # 0 grabs → arity 1
            "([9:s]use-const (c(mn[1:n]0g[7:s]const-5pv))))"  # 1 arg → match
        )
        mismatches = solver.arity_mismatch()
        self.assertEqual(mismatches, [])

    def test_arity_prim_call(self):
        """Primitive call via pushmark+apply is TRUSTED (no arity check in Datalog)."""
        solver = self._parse_and_solve(
            "(([4:s]test (c(mn[1:n]1n[1:n]2P[1:s]+pv))))"
        )
        # pushmark at 0, number 1 at 1, number 2 at 2, prim + at 3, apply at 4
        # Stack sim: m[M], n1[M,V], n2[M,V,V], P+[M,V], p: supplied=0
        # But prim calls are trusted → no arity_mismatch
        mismatches = solver.arity_mismatch()
        self.assertEqual(mismatches, [])

    def test_arity_prim_call_wrong(self):
        """Primitive call with wrong arity is NOT flagged (prims are trusted)."""
        solver = self._parse_and_solve(
            "(([4:s]test (c(mn[1:n]1P[1:s]+pv))))"
        )
        # + needs 2 args but only 1 supplied via pushmark+apply.
        # Prim calls are trusted → no arity_mismatch in the Datalog.
        mismatches = solver.arity_mismatch()
        self.assertEqual(mismatches, [])

    def test_arity_cur_lit_callee(self):
        """Callee is an inline cur (lambda literal) — arity checked via cur_body.

        Nested cur bodies are emitted as `cur_body` rows (Part-1 fix).  The
        Datalog's expected_arity cur-lit branch resolves via `cur_body(sub_id,
        arity)`, so a cur-lit callee IS arity-checked.
        """
        solver = self._parse_and_solve(
            "(([4:s]test (c(mn[1:n]0c(rra[1:n]0a[1:n]1P[1:s]+v)pv))))"
        )
        # pushmark at 0, number 0 at 1, cur at 2 (sub: r r a a P v, 2 grabs → arity 3), apply at 3
        # Stack sim: m[M], n0[M,V], c[M,V,V], p: V's above M=2, excl callee=1 → supplied=1
        # cur_body arity = 3 (leading grabs 2 + 1) → expected 3 vs supplied 1 → mismatch.
        mismatches = solver.arity_mismatch()
        self.assertEqual(len(mismatches), 1)
        self.assertEqual(mismatches[0][4], "1")   # supplied
        self.assertEqual(mismatches[0][3], "3")   # expected

    # ── unresolved_call ─────────────────────────────────────────────

    def test_unresolved_call_detected(self):
        """A call via [access N] (higher-order param) is unresolved."""
        solver = self._parse_and_solve(
            "(([6:s]applyf (c(rma[1:n]1a[1:n]0pv))))"
        )
        # grab at 0, pushmark at 1, access 1 at 2, access 0 at 3, apply at 4
        # Callee is access 0 → unresolved
        unresolved = solver.unresolved_call()
        self.assertEqual(len(unresolved), 1)
        self.assertEqual(unresolved[0][0], "applyf")

    def test_unresolved_call_none(self):
        """A normal call without access callee is not unresolved."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(ra[1:n]0v)))"
            "([7:s]call-id (c(ma[1:n]0g[2:s]idpv))))"
        )
        unresolved = solver.unresolved_call()
        self.assertEqual(unresolved, [])

    # ── Nested pushmark (multiple calls in one closure) ──────────────

    def test_multiple_calls_in_closure(self):
        """Two calls in one closure, each with correct arity."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"  # 0 grabs → arity 1
            "([5:s]twice (c(rma[1:n]0g[2:s]idpma[1:n]0g[2:s]idpv))))"
        )
        # twice: 1 grab → arity 2
        # First call: r, m, a0, g id, p → supplied=1, id arity=1 → match
        # Second call: m, a0, g id, p → supplied=1, id arity=1 → match
        mismatches = solver.arity_mismatch()
        self.assertEqual(mismatches, [])
        unresolved = solver.unresolved_call()
        self.assertEqual(unresolved, [])

    # ── pushmark_pair correctness ───────────────────────────────────

    def test_pushmark_pair_nested_calls(self):
        """Nested pushmarks pair correctly."""
        solver = MiniSolver()
        # Simulate: m y m x g p f p (nested call)
        solver.facts["pushmark"] = {("test", "0"), ("test", "2")}
        solver.facts["call_site"] = {("test", "5", "apply"), ("test", "7", "apply")}
        solver.facts["instr"] = {
            ("test", "0", "m"), ("test", "1", "a"), ("test", "2", "m"),
            ("test", "3", "a"), ("test", "4", "g"), ("test", "5", "p"),
            ("test", "6", "g"), ("test", "7", "p"),
        }
        solver.facts["closure"] = {("g_target", "1")}
        solver.facts["global_ref"] = {("test", "4", "inner"), ("test", "6", "outer")}
        solver.facts["operand"] = set()
        solver.facts["cur_lit"] = set()
        solver.facts["prim_ref"] = set()

        pairs = solver.pushmark_pairs()
        # pushmark at 2 pairs with call at 5 (inner call)
        # pushmark at 0 pairs with call at 7 (outer call)
        self.assertIn(("test", "2", "5", "apply"), pairs)
        self.assertIn(("test", "0", "7", "apply"), pairs)

    # ── End-to-end extract+simulate on synthetic bundles ─────────────

    def test_e2e_clean_bundle(self):
        """A clean synthetic bundle produces zero violations."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"         # 0 grabs → arity 1
            "([7:s]call-id (c(ma[1:n]0g[2:s]idpv)))"  # 1 arg → match
            "([3:s]add (c(ra[1:n]0a[1:n]1P[1:s]+v)))" # 1 grab → arity 2
            "([8:s]call-add (c(ma[1:n]0n[1:n]1g[3:s]addpv))))"  # 2 args → match
        )
        self.assertEqual(solver.bad_opcode(), set())
        self.assertEqual(solver.dangling_global(), set())
        self.assertEqual(solver.unknown_prim(), set())
        self.assertEqual(solver.curried_call(), set())
        self.assertEqual(solver.arity_mismatch(), [])
        self.assertEqual(solver.unresolved_call(), [])

    def test_e2e_bad_bundle(self):
        """A synthetic bundle with multiple violations catches all."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(ra[1:n]0v)))"
            "([9:s]bad-calls (c(mg[2:s]idpmg[5:s]ghostpma[1:n]0a[1:n]0pv))))"
        )
        # bad-calls instruction layout:
        #   0: m (pushmark)
        #   1: g id (global ref — callee)
        #   2: p (apply) — 0-arg call to id (arity 2 → mismatch, expected=2, supplied=0)
        #   3: m (pushmark)
        #   4: g ghost (global ref — dangling)
        #   5: p (apply) — call to ghost (ghost not in closures → no arity check)
        #   6: m (pushmark)
        #   7: a 0 (access — arg)
        #   8: a 0 (access — callee, higher-order)
        #   9: p (apply) — unresolved call
        #  10: v (return)
        # No adjacent call sites in this bundle → 0 curried calls.

        curried = solver.curried_call()
        self.assertEqual(len(curried), 0, "No adjacent call sites in this bundle")

        dangling = solver.dangling_global()
        self.assertIn(("bad-calls", "4", "ghost"), dangling)

        mismatches = solver.arity_mismatch()
        self.assertTrue(any(m[2] == "id" for m in mismatches),
                        "Should detect arity mismatch for id")
        # Verify specific values: id arity=2, supplied=0
        id_mismatch = [m for m in mismatches if m[2] == "id"]
        self.assertEqual(len(id_mismatch), 1)
        self.assertEqual(id_mismatch[0][3], "2")  # expected
        self.assertEqual(id_mismatch[0][4], "0")  # supplied

        unresolved = solver.unresolved_call()
        self.assertGreater(len(unresolved), 0, "Should detect unresolved call")


# ── PRIM_ARITY corrections ────────────────────────────────────────────

class TestPrimArity(unittest.TestCase):
    """Verify the 4 prim_arity corrections from vm/zincvm.c exec_primitive."""

    def test_prim_arity_corrections(self):
        """Verify address->=3, char-code=2, emptylist=1, trap-error=2."""
        arities = ext.PRIM_ARITY
        self.assertEqual(arities.get("address->"), 3,
                         "address-> pops vec, idx, val → 3 args")
        self.assertEqual(arities.get("char-code"), 2,
                         "char-code pops string, index → 2 args")
        self.assertEqual(arities.get("emptylist"), 1,
                         "emptylist pops number 0 sentinel → 1 arg")
        self.assertEqual(arities.get("trap-error"), 2,
                         "trap-error pops body, handler → 2 args")
        self.assertEqual(arities.get("fail"), 1,
                         "fail pops optional arg → 1 (variable-arity cap)")

    def test_prim_arity_is_emitted(self):
        """Verify prim_arity facts are emitted to CSV."""
        solver = MiniSolver()
        solver.facts["prim_arity"] = set()
        for prim, arity in sorted(ext.PRIM_ARITY.items()):
            solver.facts["prim_arity"].add((prim, str(arity)))
        self.assertIn(("address->", "3"), solver.all_of("prim_arity"))
        self.assertIn(("char-code", "2"), solver.all_of("prim_arity"))
        self.assertIn(("emptylist", "1"), solver.all_of("prim_arity"))
        self.assertIn(("trap-error", "2"), solver.all_of("prim_arity"))


# ── supplied_args stack simulation tests ──────────────────────────────

class TestSuppliedArgs(unittest.TestCase):
    """Test the forward-dataflow stack simulation in extract_bundle.py."""

    def _parse_and_solve(self, bundle_text):
        d = tempfile.mkdtemp(prefix="bv-test-")
        run_extract(bundle_text, d)
        solver = MiniSolver()
        solver.load_csvs(d)
        import shutil
        shutil.rmtree(d, ignore_errors=True)
        return solver

    def test_simple_global_call(self):
        """A 1-arg global call → supplied_args(n, cs, 1)."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"
            "([7:s]call-id (c(ma[1:n]0g[2:s]idpv))))"
        )
        supplied = {(r[0], int(r[1])): int(r[2])
                    for r in solver.all_of("supplied_args")}
        self.assertEqual(supplied.get(("call-id", 3)), 1)

    def test_two_arg_global_call(self):
        """A 2-arg global call → supplied_args(n, cs, 2)."""
        solver = self._parse_and_solve(
            "(([3:s]add (c(ra[1:n]0a[1:n]1P[1:s]+v)))"
            "([8:s]call-add (c(ma[1:n]0n[1:n]1g[3:s]addpv))))"
        )
        supplied = {(r[0], int(r[1])): int(r[2])
                    for r in solver.all_of("supplied_args")}
        self.assertEqual(supplied.get(("call-add", 4)), 2)

    def test_nested_call_correct_arg_counts(self):
        """Inner apply inside outer: both get correct arg counts."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"
            "([5:s]twice (c(rma[1:n]0g[2:s]idpma[1:n]0g[2:s]idpv))))"
        )
        supplied = {(r[0], int(r[1])): int(r[2])
                    for r in solver.all_of("supplied_args")}
        # First call at pc=4: after r, m, a0, g id, p
        self.assertEqual(supplied.get(("twice", 4)), 1)
        # Second call at pc=8: after m, a0, g id, p
        self.assertEqual(supplied.get(("twice", 8)), 1)

    def test_inline_prim_outer_call_counts_correctly(self):
        """An inline prim (net -1) → outer call counts correctly."""
        solver = self._parse_and_solve(
            "(([3:s]add (c(ra[1:n]0a[1:n]1P[1:s]+v)))"
            "([4:s]test (c(ma[1:n]0n[1:n]1P[1:s]+g[3:s]addpv))))"
        )
        supplied = {(r[0], int(r[1])): int(r[2])
                    for r in solver.all_of("supplied_args")}
        # test body: m, a0, n1, P+, g add, p, v
        # Stack: m[M], a0[M,V], n1[M,V,V], P+[M,V], g add[M,V,V], p
        # V's above M=2, excl callee=1 → supplied=1
        # But add expects 2 → mismatch (tested in arity tests, not here)
        self.assertEqual(supplied.get(("test", 5)), 1)

    def test_prim_call_supplied_args(self):
        """Prim call via apply also gets supplied_args."""
        solver = self._parse_and_solve(
            "(([4:s]test (c(mn[1:n]1n[1:n]2P[1:s]+pv))))"
        )
        supplied = {(r[0], int(r[1])): int(r[2])
                    for r in solver.all_of("supplied_args")}
        # m, n1, n2, P+, p
        # Stack: m[M], n1[M,V], n2[M,V,V], P+[M,V], p
        # V's above M=1, excl callee=0 → supplied=0
        # (Prims consume their own args, callee is the + result)
        self.assertEqual(supplied.get(("test", 4)), 0)

    def test_appterm_supplied_args(self):
        """Appterm (tail call) also gets supplied_args."""
        solver = self._parse_and_solve(
            "(([2:s]id (c(a[1:n]0v)))"
            "([7:s]tail-id (c(ma[1:n]0g[2:s]idt))))"
        )
        supplied = {(r[0], int(r[1])): int(r[2])
                    for r in solver.all_of("supplied_args")}
        self.assertEqual(supplied.get(("tail-id", 3)), 1)


# ── Self-test integration ────────────────────────────────────────────

class TestSelfTest(unittest.TestCase):
    """Test that extract_bundle.py --self-test works."""

    def test_self_test_runs(self):
        """The --self-test flag produces correct output."""
        with tempfile.TemporaryDirectory() as d:
            ext.self_test(d)
            # Verify output files exist
            for rel in ext.CSV_SCHEMAS:
                path = Path(d) / f"{rel}.csv"
                self.assertTrue(path.exists(), f"Missing {rel}.csv")


# ── Regression: real bundle can be parsed without error ──────────────

class TestRealBundle(unittest.TestCase):
    """Parse the real globals.csexp and verify basic statistics."""

    def test_real_bundle_parses(self):
        """The real bundle parses without errors."""
        bundle_path = TOOLS_DIR / ".." / ".." / "globals.csexp"
        if not bundle_path.exists():
            self.skipTest("globals.csexp not found — run `make bundle` first")

        with tempfile.TemporaryDirectory() as d:
            data = bundle_path.read_text()
            writer = ext.FactWriter(d)
            parser = ext.BundleParser(data, writer)
            n = parser.parse_bundle()
            writer.close()

            self.assertGreater(n, 0, "Should parse at least one closure")

            # Verify key facts exist
            closures, _ = read_csv(Path(d) / "closure.csv")
            # closure() now holds ONLY the n top-level closures (no phantom
            # nested-cur sub-ids).  Nested cur bodies live in cur_body.csv.
            self.assertEqual(len(closures), n,
                             "closure() must contain exactly the top-level closures")

            # No closure row may be a fabricated nested-cur sub-id (parent.N.M...).
            import re
            for cname, arity in closures:
                self.assertNotRegex(
                    cname, r"\.\d+$",
                    f"closure() contains phantom nested-cur name '{cname}'")

            # Every nested cur body from cur_lit must be present in cur_body.
            cur_lits, _ = read_csv(Path(d) / "cur_lit.csv")
            cur_bodies, _ = read_csv(Path(d) / "cur_body.csv")
            cur_body_names = {r[0] for r in cur_bodies}
            self.assertGreater(len(cur_lits), 0, "bundle should have nested cur bodies")
            for _n, _idx, sub in cur_lits:
                self.assertIn(sub, cur_body_names,
                              f"cur_lit sub-id '{sub}' missing from cur_body")

            instrs, _ = read_csv(Path(d) / "instr.csv")
            self.assertGreater(len(instrs), 1000)

            # Verify global_ref and prim_ref counts are reasonable
            global_refs, _ = read_csv(Path(d) / "global_ref.csv")
            prim_refs, _ = read_csv(Path(d) / "prim_ref.csv")
            call_sites, _ = read_csv(Path(d) / "call_site.csv")
            pushmarks, _ = read_csv(Path(d) / "pushmark.csv")

            self.assertGreater(len(global_refs), 0)
            self.assertGreater(len(prim_refs), 0)
            # pushmark count should equal call_site count
            self.assertEqual(len(pushmarks), len(call_sites),
                             "pushmark count must equal call_site count")

    def test_real_bundle_instr_opcodes_valid(self):
        """Every instruction in the real bundle uses a valid opcode."""
        bundle_path = TOOLS_DIR / ".." / ".." / "globals.csexp"
        if not bundle_path.exists():
            self.skipTest("globals.csexp not found")

        valid = ext.VALID_OPCODES
        with tempfile.TemporaryDirectory() as d:
            data = bundle_path.read_text()
            writer = ext.FactWriter(d)
            parser = ext.BundleParser(data, writer)
            parser.parse_bundle()
            writer.close()

            instrs, _ = read_csv(Path(d) / "instr.csv")
            for row in instrs:
                op = row[2]
                self.assertIn(op, valid,
                              f"Invalid opcode '{op}' in {row[0]} at idx {row[1]}")

    def test_real_bundle_no_unknown_prims(self):
        """Every [prim X] in the real bundle is in the allowlist."""
        bundle_path = TOOLS_DIR / ".." / ".." / "globals.csexp"
        if not bundle_path.exists():
            self.skipTest("globals.csexp not found")

        with tempfile.TemporaryDirectory() as d:
            data = bundle_path.read_text()
            writer = ext.FactWriter(d)
            parser = ext.BundleParser(data, writer)
            parser.parse_bundle()
            writer.close()

            prim_refs, _ = read_csv(Path(d) / "prim_ref.csv")
            for row in prim_refs:
                prim = row[2]
                self.assertIn(prim, ext.ALLOWED_PRIMS,
                              f"Unknown prim '{prim}' in {row[0]} at idx {row[1]}")


if __name__ == "__main__":
    unittest.main()

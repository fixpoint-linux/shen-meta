#!/usr/bin/env python3
"""test_phase0.py — Phase 0 round-trip gate for gc-verify.

Validates:
  1. extract.py --self-test produces all 10 CSV files with correct headers.
  2. Every .input filename in gc_safety.dl has a corresponding CSV header
     from the self-test output (schema cross-check).
  3. extract.py --help exits 0.

Runs WITHOUT clang or souffle — pure Python stdlib + unittest.
"""

import csv
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TOOLS_DIR = PROJECT_ROOT / "tools" / "gc-verify"
EXTRACT_PY = TOOLS_DIR / "extract.py"
GC_SAFETY_DL = TOOLS_DIR / "gc_safety.dl"


def _run_extract(args):
    """Run extract.py with given args, return (returncode, stdout, stderr)."""
    proc = subprocess.run(
        [sys.executable, str(EXTRACT_PY)] + args,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


class TestPhase0(unittest.TestCase):
    """Phase 0 round-trip gate."""

    # ── Expected CSV schemas (from CSV_SCHEMAS in extract.py) ────────

    EXPECTED_SCHEMAS = {
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

    @classmethod
    def setUpClass(cls):
        """Run extract.py --self-test once into a temp dir."""
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="gc-verify-test-")
        rc, stdout, stderr = _run_extract([
            "--self-test", "--out-dir", cls.temp_dir.name
        ])
        cls.extract_stdout = stdout
        cls.extract_stderr = stderr

    @classmethod
    def tearDownClass(cls):
        cls.temp_dir.cleanup()

    # ── Test 1: all 10 CSV files produced ────────────────────────────

    def test_01_all_csv_files_exist(self):
        """All 10 expected CSV files are produced by --self-test."""
        for rel in self.EXPECTED_SCHEMAS:
            path = Path(self.temp_dir.name) / f"{rel}.csv"
            self.assertTrue(
                path.exists(),
                f"Missing CSV: {rel}.csv"
            )

    # ── Test 2: each CSV has correct header ──────────────────────────

    def test_02_csv_headers_correct(self):
        """Each CSV file has the correct header row."""
        for rel, expected_cols in self.EXPECTED_SCHEMAS.items():
            path = Path(self.temp_dir.name) / f"{rel}.csv"
            with open(path, "r", newline="") as f:
                reader = csv.reader(f)
                header = next(reader)
            self.assertEqual(
                header, expected_cols,
                f"Header mismatch for {rel}.csv: got {header}, expected {expected_cols}"
            )

    # ── Test 3: each CSV has at least one data row ───────────────────

    def test_03_csv_has_data_rows(self):
        """Each CSV file has at least one data row (not just header)."""
        for rel in self.EXPECTED_SCHEMAS:
            path = Path(self.temp_dir.name) / f"{rel}.csv"
            with open(path, "r", newline="") as f:
                reader = csv.reader(f)
                next(reader)  # header
                rows = list(reader)
            self.assertGreater(
                len(rows), 0,
                f"No data rows in {rel}.csv"
            )

    # ── Test 4: extract.py --help exits 0 ────────────────────────────

    def test_04_help_exits_zero(self):
        """extract.py --help exits with code 0."""
        rc, stdout, stderr = _run_extract(["--help"])
        self.assertEqual(rc, 0, f"--help exited {rc}: {stderr}")
        self.assertIn("usage:", stdout.lower() or stderr.lower())

    # ── Test 5: extract.py with no args exits non-zero ───────────────

    def test_05_no_args_fails(self):
        """extract.py with no args prints error and exits non-zero."""
        rc, stdout, stderr = _run_extract([])
        self.assertNotEqual(rc, 0, "Expected non-zero exit for no-args")

    # ── Test 6: schema cross-check (dl inputs vs csv headers) ────────

    def test_06_schema_cross_check(self):
        """Every .input filename in gc_safety.dl has a CSV header match."""
        dl_path = GC_SAFETY_DL
        self.assertTrue(dl_path.exists(), f"Missing: {dl_path}")

        dl_text = dl_path.read_text()

        # Find all .input declarations and their filenames
        # Pattern: .input RELNAME(IO=file, ..., filename="facts/NAME.csv")
        input_pattern = re.compile(
            r'\.input\s+(\w+)\s*\([^)]*filename\s*=\s*"facts/([^"]+\.csv)"'
        )
        dl_inputs = {}
        for m in input_pattern.finditer(dl_text):
            rel_name = m.group(1)
            csv_name = m.group(2)
            # Strip .csv to get the relation short name
            rel_short = csv_name.replace(".csv", "")
            dl_inputs[rel_short] = (rel_name, csv_name)

        self.assertGreater(
            len(dl_inputs), 0,
            "No .input declarations found in gc_safety.dl"
        )

        # Check that every .input relation exists as a CSV in self-test output
        for rel_short, (rel_name, csv_name) in dl_inputs.items():
            path = Path(self.temp_dir.name) / f"{rel_short}.csv"
            self.assertTrue(
                path.exists(),
                f"gc_safety.dl .input '{rel_name}' expects facts/{csv_name} "
                f"but self-test did not produce {rel_short}.csv"
            )

            # Verify header columns match the .decl
            # Find the .decl for this relation
            decl_pattern = re.compile(
                rf'\.decl\s+{re.escape(rel_name)}\(([^)]+)\)'
            )
            decl_m = decl_pattern.search(dl_text)
            self.assertIsNotNone(
                decl_m,
                f"No .decl found for relation '{rel_name}'"
            )

            # Parse .decl columns: "f:symbol, stmt_id:number, ..."
            decl_cols_raw = decl_m.group(1)
            decl_cols = [
                c.split(":")[0].strip()
                for c in decl_cols_raw.split(",")
            ]

            # Read CSV header
            with open(path, "r", newline="") as f:
                csv_header = next(csv.reader(f))

            self.assertEqual(
                decl_cols, csv_header,
                f"Column mismatch for {rel_name} ({rel_short}.csv):\n"
                f"  .decl: {decl_cols}\n"
                f"  CSV:   {csv_header}"
            )

        # Also verify that ALL 10 expected schemas have .input decls
        for rel in self.EXPECTED_SCHEMAS:
            self.assertIn(
                rel, dl_inputs,
                f"CSV '{rel}' has no corresponding .input in gc_safety.dl"
            )

    # ── Test 7: gc_safety.dl has output declarations ─────────────────

    def test_07_output_declarations(self):
        """gc_safety.dl has .output declarations for may_collect, root_miss,
        memcpy_unbarriered."""
        dl_text = GC_SAFETY_DL.read_text()
        for out_rel in ("may_collect", "root_miss", "memcpy_unbarriered"):
            self.assertIn(
                f".output {out_rel}",
                dl_text,
                f"Missing .output declaration for '{out_rel}'"
            )

    # ── Test 8: may_collect seeds present ────────────────────────────

    def test_08_may_collect_seeds(self):
        """gc_safety.dl has the 6 required may_collect seeds."""
        dl_text = GC_SAFETY_DL.read_text()
        seeds = [
            "gc_alloc", "gc_alloc_oldgen", "gc_alloc_atomic",
            "collect", "collect_nursery", "gcalloc_internal",
        ]
        for seed in seeds:
            self.assertIn(
                f'may_collect("{seed}")',
                dl_text,
                f"Missing may_collect seed: {seed}"
            )

    # ── Test 9: skeleton rules are present and vacuous ───────────────

    def test_09_skeleton_rules(self):
        """gc_safety.dl has skeleton root_miss and memcpy_unbarriered rules
        using 'false' body."""
        dl_text = GC_SAFETY_DL.read_text()

        self.assertIn(
            "root_miss",
            dl_text,
            "Missing root_miss rule"
        )
        # root_miss should have a rule body with 'false'
        # Find the root_miss rule line (non-decl, non-output)
        root_miss_rules = [
            line for line in dl_text.split("\n")
            if "root_miss" in line
            and not line.strip().startswith(".")
            and not line.strip().startswith("//")
        ]
        self.assertGreater(
            len(root_miss_rules), 0,
            "No root_miss rule found (only .decl/.output)"
        )
        self.assertIn(
            "false",
            root_miss_rules[0],
            "root_miss skeleton rule should use 'false' body"
        )

        self.assertIn(
            "memcpy_unbarriered",
            dl_text,
            "Missing memcpy_unbarriered rule"
        )
        mcpy_rules = [
            line for line in dl_text.split("\n")
            if "memcpy_unbarriered" in line
            and not line.strip().startswith(".")
            and not line.strip().startswith("//")
        ]
        self.assertGreater(
            len(mcpy_rules), 0,
            "No memcpy_unbarriered rule found"
        )
        self.assertIn(
            "false",
            mcpy_rules[0],
            "memcpy_unbarriered skeleton rule should use 'false' body"
        )

    # ── Test 10: Phase comments present ──────────────────────────────

    def test_10_phase_comments(self):
        """gc_safety.dl has Phase 2/3 markers on skeleton rules."""
        dl_text = GC_SAFETY_DL.read_text()
        # Check that the file mentions phases
        self.assertIn("Phase 2", dl_text, "Missing 'Phase 2' comment in gc_safety.dl")
        self.assertIn("Phase 3", dl_text, "Missing 'Phase 3' comment in gc_safety.dl")


if __name__ == "__main__":
    unittest.main()

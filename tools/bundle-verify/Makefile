# tools/bundle-verify/Makefile — Shen bundle safe-subset verifier (opt-in, not gating)
#
# Requires: python3 (stdlib only), souffle on $PATH.
# No clang needed.

.PHONY: run selftest snapshot clean

# ── Full pipeline (needs souffle) ─────────────────────────────────────

run:
	@echo "==> Checking prerequisites..."
	@command -v souffle >/dev/null 2>&1 || { echo "ERROR: souffle not found" >&2; exit 1; }
	@echo "==> Extracting facts from ../../globals.csexp ..."
	@mkdir -p facts
	python3 extract_bundle.py --bundle ../../globals.csexp --out-dir facts/
	@echo "==> Extracting source-level facts from ../../shen/ ..."
	python3 extract_source.py --source-dir ../../shen/ --out-dir facts/
	@echo "==> Running Soufflé analysis..."
	@mkdir -p out
	# .input/.output filenames carry the facts/ and out/ prefixes, so the
	# fact dir (-F) and output dir (-D) must be '.' to avoid double-prefixing.
	souffle bundle_safety.dl -F . -D .
	@echo "==> Results in out/"
	@echo "==> Checking real-bundle baseline against expected/..."
	@bash check_results.sh

# ── Snapshot (refresh expected/ from current real-bundle output) ──────

snapshot:
	@command -v souffle >/dev/null 2>&1 || { echo "ERROR: souffle not found" >&2; exit 1; }
	@mkdir -p facts out expected
	python3 extract_bundle.py --bundle ../../globals.csexp --out-dir facts/
	python3 extract_source.py --source-dir ../../shen/ --out-dir facts/
	souffle bundle_safety.dl -F . -D .
	cp out/bad_opcode.csv expected/bad_opcode.csv
	cp out/dangling_global.csv expected/dangling_global.csv
	cp out/unknown_prim.csv expected/unknown_prim.csv
	cp out/curried_call.csv expected/curried_call.csv
	cp out/arity_mismatch.csv expected/arity_mismatch.csv
	cp out/unresolved_call.csv expected/unresolved_call.csv
	cp out/source_file.csv expected/source_file.csv
	cp out/unsafe_construct.csv expected/unsafe_construct.csv
	cp out/nonlinear_pattern.csv expected/nonlinear_pattern.csv
	cp out/tuple_pattern.csv expected/tuple_pattern.csv
	@echo "==> expected/ refreshed. Review: git diff expected/"

# ── Self-test (Python stdlib only, no souffle) ────────────────────────

selftest:
	python3 tests/test_bundle.py -v
	python3 tests/test_source.py -v

# ── Clean ────────────────────────────────────────────────────────────

clean:
	rm -rf facts/ out/ __pycache__/ tests/__pycache__/

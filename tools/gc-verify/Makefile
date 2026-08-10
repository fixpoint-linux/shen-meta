# tools/gc-verify/Makefile — GC-safety verifier (opt-in, not gating)
#
# Requires: clang >= 14, souffle on $PATH.
# Python 3 stdlib only (no pip deps).

.PHONY: run selftest clean

# ── Full pipeline (needs clang + souffle) ────────────────────────────

run:
	@echo "==> Checking prerequisites..."
	@command -v clang >/dev/null 2>&1 || { echo "ERROR: clang not found (need clang >= 14)" >&2; exit 1; }
	@command -v souffle >/dev/null 2>&1 || { echo "ERROR: souffle not found" >&2; exit 1; }
	@echo "==> Extracting facts from vm/zincvm.c + vm/gc.c ..."
	@mkdir -p facts
	@clang -Xclang -ast-dump=json -fsyntax-only -I ../../vm ../../vm/zincvm.c > /tmp/gcverify_zincvm.json 2>/dev/null
	@clang -Xclang -ast-dump=json -fsyntax-only -I ../../vm ../../vm/gc.c > /tmp/gcverify_gc.json 2>/dev/null
	python3 extract.py --ast /tmp/gcverify_zincvm.json --ast /tmp/gcverify_gc.json --out-dir facts/
	@echo "==> Running Soufflé analysis..."
	@mkdir -p out
	# .input/.output filenames carry the facts/ and out/ prefixes, so the
	# fact dir (-F) and output dir (-D) must be '.' to avoid double-prefixing.
	souffle gc_safety.dl -F . -D .
	@echo "==> Results in out/ (may_collect.csv, root_miss.csv, memcpy_unbarriered.csv)"

# ── Self-test (Python stdlib only, no clang/souffle/pytest) ──────────

selftest:
	python3 tests/test_phase0.py -v
	python3 tests/test_phase1.py -v

# ── Clean ────────────────────────────────────────────────────────────

clean:
	rm -rf facts/ out/ __pycache__/ tests/__pycache__/
	rm -f /tmp/gcverify_zincvm.json /tmp/gcverify_gc.json

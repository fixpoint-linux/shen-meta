# tools/qbe-gc-verify/Makefile — GC-root-safety verifier for the QBE native
# closures (globals.qbe).  Opt-in, not gating.
#
# Requires: souffle on $PATH; Python 3 stdlib only (no pip deps).
# Mirrors tools/gc-verify (the C-VM verifier) but parses the QBE IR text
# instead of C AST, so no clang is needed.

.PHONY: run clean

# ── Full pipeline (needs souffle) ────────────────────────────────────

run:
	@echo "==> Checking prerequisites..."
	@command -v souffle >/dev/null 2>&1 || { echo "ERROR: souffle not found" >&2; exit 1; }
	@[ -f ../../globals.qbe ] || { echo "ERROR: ../../globals.qbe missing — run make qbe-gen first" >&2; exit 1; }
	@echo "==> Extracting facts from globals.qbe ..."
	@mkdir -p facts out
	python3 extract.py ../../globals.qbe
	@echo "==> Running Soufflé GC-root analysis (root_miss)..."
	souffle gc_safety_qbe.dl -F facts -D out
	@echo "==> Results in out/ (rm_gt0.csv, n_affected.csv, total_rm.csv)"
	@echo "==> Summary:"
	@echo "  affected closures (root_miss >= 1): $$(cat out/n_affected.csv)"
	@echo "  total root_miss sites:               $$(cat out/total_rm.csv)"

# ── Clean ────────────────────────────────────────────────────────────

clean:
	rm -rf facts/ out/ __pycache__

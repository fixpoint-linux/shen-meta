#!/bin/bash
# check_results.sh — real-VM baseline diff: run the clang → extract.py →
# souffle pipeline against vm/zincvm.c + vm/gc.c, then diff the output
# relations against expected/.
#
# FAIL = new row in output not in expected/ (regression).
# WARN = row in expected/ no longer fires (likely a fix; re-run `make snapshot`).
#
# Requires: clang >= 14, souffle on PATH. Run from tools/gc-verify/.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/gc_safety.dl"
VM_DIR="$HERE/../../vm"
EXPECTED="$HERE/expected"
RELATIONS="root_miss memcpy_unbarriered single_store_unbarriered push_pop_balance"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# ── Prerequisites (fast-fail, exit 2) ──────────────────────────────────

if ! command -v clang >/dev/null 2>&1; then
    echo "ERROR: clang not found (need clang >= 14)" >&2; exit 2
fi
if ! command -v souffle >/dev/null 2>&1; then
    echo "ERROR: souffle not found" >&2; exit 2
fi
if [ ! -d "$EXPECTED" ]; then
    echo "ERROR: $EXPECTED missing — run \`make snapshot\` first" >&2; exit 2
fi

# ── Pipeline (self-contained into $WORK) ───────────────────────────────

clang -Xclang -ast-dump=json -fsyntax-only -I "$VM_DIR" \
    "$VM_DIR/zincvm.c" > "$WORK/zincvm.json" 2>/dev/null
clang -Xclang -ast-dump=json -fsyntax-only -I "$VM_DIR" \
    "$VM_DIR/gc.c" > "$WORK/gc.json" 2>/dev/null

python3 "$HERE/extract.py" \
    --ast "$WORK/zincvm.json" \
    --ast "$WORK/gc.json" \
    --out-dir "$WORK/facts" >/dev/null 2>&1

mkdir -p "$WORK/out"
(cd "$WORK" && souffle "$DL" -F . -D . >/dev/null 2>&1)

# ── Per-relation set-diff ──────────────────────────────────────────────

for rel in $RELATIONS; do
    got="$WORK/out/${rel}.csv"
    want="$EXPECTED/${rel}.csv"

    if [ ! -f "$want" ]; then
        echo "WARN $rel: no expected/${rel}.csv — skipping (run \`make snapshot\` to seed)"
        continue
    fi

    # Strip header, sort both sides.
    got_sorted="$WORK/${rel}_got_sorted.csv"
    want_sorted="$WORK/${rel}_want_sorted.csv"
    tail -n +2 "$got" 2>/dev/null | LC_ALL=C sort > "$got_sorted"
    tail -n +2 "$want" 2>/dev/null | LC_ALL=C sort > "$want_sorted"

    # Rows in output NOT in expected → FAIL (new candidates).
    extra="$WORK/${rel}_extra.csv"
    comm -23 "$got_sorted" "$want_sorted" > "$extra"
    extra_n="$(wc -l < "$extra")"

    # Rows in expected NOT in output → WARN (candidates that went away).
    gone="$WORK/${rel}_gone.csv"
    comm -13 "$got_sorted" "$want_sorted" > "$gone"
    gone_n="$(wc -l < "$gone")"

    got_n="$(wc -l < "$got_sorted")"

    if [ "$extra_n" -gt 0 ]; then
        echo "FAIL $rel: $extra_n NEW row(s) not in expected/:"
        cat "$extra"
        fail=1
    else
        echo "OK   $rel: $got_n row(s) match expected baseline"
    fi

    if [ "$gone_n" -gt 0 ]; then
        echo "WARN $rel: $gone_n row(s) in expected/ no longer fire (probably a fix — re-run \`make snapshot\` to refresh):"
        cat "$gone"
    fi
done

# ── Final ──────────────────────────────────────────────────────────────

if [ "$fail" -eq 0 ]; then
    echo "check_results: ALL PASS"
else
    echo "check_results: FAILURES PRESENT"
    exit 1
fi

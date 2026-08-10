#!/bin/bash
# check_fixtures.sh — regression-gate: run each fixture through the real
# clang → extract.py → souffle pipeline and assert the outcome.
#
# Positive fixtures (BUGGY code) MUST produce ≥1 row in the target relation.
# Negative fixtures (CORRECT code) MUST produce 0 rows.
#
# Requires: clang >= 14, souffle on PATH. Run from tools/gc-verify/.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/gc_safety.dl"
FX_DIR="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# run_fixture <name> <expect_positive: yes|no> [rel: root_miss|memcpy_unbarriered]
run_fixture() {
    local name="$1" expect="$2"
    local rel="${3:-root_miss}"
    local fx="$FX_DIR/$name.c"
    local dir="$WORK/$name"
    mkdir -p "$dir/out"
    if ! clang -Xclang -ast-dump=json -fsyntax-only -I "$FX_DIR" \
            "$fx" > "$dir/ast.json" 2>/dev/null; then
        echo "FAIL $name: clang AST dump failed"; fail=1; return
    fi
    if ! python3 "$HERE/extract.py" --ast "$dir/ast.json" \
            --out-dir "$dir/facts" >/dev/null 2>&1; then
        echo "FAIL $name: extract.py failed"; fail=1; return
    fi
    (cd "$dir" && souffle "$DL" -F . -D . >/dev/null 2>&1)
    local n=0
    if [ -f "$dir/out/${rel}.csv" ]; then
        n="$(tail -n +2 "$dir/out/${rel}.csv" | wc -l)"
    fi
    if [ "$expect" = "yes" ]; then
        if [ "$n" -ge 1 ]; then
            echo "OK   $name: fires ($n $rel) [expected]"
        else
            echo "FAIL $name: expected ≥1 $rel, got 0"; fail=1
        fi
    else
        if [ "$n" -eq 0 ]; then
            echo "OK   $name: clean (0 $rel) [expected]"
        else
            echo "FAIL $name: expected 0 $rel, got $n"; fail=1
        fi
    fi
}

run_fixture val_lambda_env yes
run_fixture trap_error_hc  yes
run_fixture rooted_ok     no

# Phase 3: memcpy_unbarriered fixtures.
run_fixture memcpy_unbarriered yes memcpy_unbarriered
run_fixture memcpy_barriered  no  memcpy_unbarriered
run_fixture memcpy_charbuf    no  memcpy_unbarriered

# Phase 5: calibration fixtures.
run_fixture memcpy_instr_array           no  memcpy_unbarriered   # Fix 1: Instr* dst filtered
run_fixture memcpy_fresh_target          no  memcpy_unbarriered   # barrier_covers_alloc negative control
run_fixture root_miss_cross_case         no  root_miss            # Fix 3b: case-scoped next_stmt
run_fixture root_miss_own_defining_alloc no  root_miss            # Fix 3a: defining_alloc suppresses
run_fixture root_miss_straight_line      yes root_miss            # positive control: still fires

if [ "$fail" -eq 0 ]; then
    echo "check_fixtures: ALL PASS"
else
    echo "check_fixtures: FAILURES PRESENT"
    exit 1
fi

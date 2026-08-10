#!/bin/bash
# check_fixtures.sh — regression-gate: run each fixture through the real
# clang → extract.py → souffle pipeline and assert the root_miss outcome.
#
# Positive fixtures (BUGGY code) MUST produce ≥1 root_miss.
# Negative fixtures (CORRECTLY ROOTED code) MUST produce 0 root_miss.
#
# Requires: clang >= 14, souffle on PATH. Run from tools/gc-verify/.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/gc_safety.dl"
FX_DIR="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# run_fixture <name> <expect_positive: yes|no>
run_fixture() {
    local name="$1" expect="$2"
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
    if [ -f "$dir/out/root_miss.csv" ]; then
        n="$(tail -n +2 "$dir/out/root_miss.csv" | wc -l)"
    fi
    if [ "$expect" = "yes" ]; then
        if [ "$n" -ge 1 ]; then
            echo "OK   $name: fires ($n root_miss) [expected]"
        else
            echo "FAIL $name: expected ≥1 root_miss, got 0"; fail=1
        fi
    else
        if [ "$n" -eq 0 ]; then
            echo "OK   $name: clean (0 root_miss) [expected]"
        else
            echo "FAIL $name: expected 0 root_miss, got $n"; fail=1
        fi
    fi
}

run_fixture val_lambda_env yes
run_fixture trap_error_hc  yes
run_fixture rooted_ok     no

if [ "$fail" -eq 0 ]; then
    echo "check_fixtures: ALL PASS"
else
    echo "check_fixtures: FAILURES PRESENT"
    exit 1
fi

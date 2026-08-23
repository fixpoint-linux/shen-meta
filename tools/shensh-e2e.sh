#!/usr/bin/env bash
# shensh-e2e.sh — end-to-end tests for the shensh shell (shpar-p2 U5).
#
# Feeds shell command LINES through the REAL shensh REPL (stdin pipe, the
# same path a user types) and greps the combined output for expected
# patterns.  Never probes parser internals via nested REPL expressions;
# commands are exercised exactly like real usage.  The '(' escape lines
# run through the bundled flat-Shen reader/compiler (shen-parse-exprs +
# shen->kl), so simple Shen SURFACE forms are fair game as test inputs.
#
# Must run from the repo root: the shell boots shell/*.shen relative to
# cwd (the script cds itself).  Requires ./shensh + globals.csexp
# (run `make` and `make bundle` first — the Makefile target does both).
#
# Prompt pollution: the prompt ("<cwd>> ") and heredoc continuation
# prompts ("> ") interleave with command output on the same line, so
# expectations are grep patterns, not exact-output matches.
set -u
cd "$(dirname "$0")/.."

BIN=./shensh
BUNDLE=globals.csexp
if [ ! -x "$BIN" ]; then echo "FAIL: $BIN not built (run make)"; exit 1; fi
if [ ! -f "$BUNDLE" ]; then echo "FAIL: $BUNDLE missing (run make bundle)"; exit 1; fi

pass=0
fail=0

# t <name> <input> <expect-ERE> [<expect-ERE> ...]
#   Runs the input lines through one fresh shensh process; every expect
#   pattern must match the combined output (stdout+stderr).
t() {
    local name="$1" input="$2"
    shift 2
    local out
    out="$(printf '%s\n' "$input" | "$BIN" "$BUNDLE" 2>&1)"
    local ok=1 pat
    for pat in "$@"; do
        if ! printf '%s' "$out" | grep -qE -- "$pat"; then
            ok=0
            echo "FAIL $name"
            echo "  input:    $(printf '%s' "$input" | head -1 | sed 's/^/\\/;s/$/\\/')"
            echo "  expected: /$pat/"
            echo "  got:      $(printf '%s' "$out" | grep -v -E 'Loaded|Perfect' | head -6)"
            break
        fi
    done
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        echo "ok   $name"
    else
        fail=$((fail + 1))
    fi
}

# tn <name> <input> <expect-ERE>  — the pattern must NOT appear.
tn() {
    local name="$1" input="$2" pat="$3"
    local out
    out="$(printf '%s\n' "$input" | "$BIN" "$BUNDLE" 2>&1)"
    if printf '%s' "$out" | grep -qE -- "$pat"; then
        fail=$((fail + 1))
        echo "FAIL $name (pattern /$pat/ unexpectedly present)"
        printf '%s' "$out" | grep -v -E 'Loaded|Perfect' | head -6 | sed 's/^/  /'
    else
        pass=$((pass + 1))
        echo "ok   $name"
    fi
}

# tc <name> <input> <expect-ERE> <count>  — the pattern must match exactly
# <count> lines (used for ordering-sensitive checks like 2>&1 >file).
tc() {
    local name="$1" input="$2" pat="$3" want="$4"
    local out n
    out="$(printf '%s\n' "$input" | "$BIN" "$BUNDLE" 2>&1)"
    n="$(printf '%s' "$out" | grep -cE -- "$pat")"
    if [ "$n" -eq "$want" ]; then
        pass=$((pass + 1))
        echo "ok   $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name (pattern /$pat/ matched $n lines, wanted $want)"
        printf '%s' "$out" | grep -v -E 'Loaded|Perfect' | head -6 | sed 's/^/  /'
    fi
}

D="$(mktemp -d /tmp/shensh-e2e.XXXXXX)"
trap 'rm -rf "$D"' EXIT

echo "== OLD cases (behaviour parity with the /bin/sh era) =="

t  "pwd"                 'pwd'                          "$(pwd)"
t  "echo hello"          'echo hello'                   '> hello'
t  "echo a | cat"        'echo a | cat'                 '> a'
t  "/bin/echo hi"        '/bin/echo hi'                 '> hi'
t  "KLambda (+ 1 2)"     '(+ 1 2)'                      '=> 3'
t  "cd / then pwd"       'cd /
pwd'                                                     '/> /'
tn "exit stops the repl" 'echo before
exit
echo after'                                              'after'
t  "exit prints exit"    'exit'                         'exit'

echo "== NEW: Shen surface at the '(' escape (flat-Shen reader/compiler) =="

t  "Shen define with sig"   '(define sq { number --> number } X -> (* X X))
(sq 7)'                   'registered sq' '=> 49'
t  "Shen define multi-rule recursive" '(define fac { number --> number } 0 -> 1 N -> (* N (fac (- N 1))))
(fac 5)'                  '=> 120'
t  "KLambda defun compat"   '(defun f2 (X) (* X X))
(f2 6)'                   '=> 36'
t  "expression still evaluates" '(+ 1 2)'    '=> 3'
t  "list literal via Shen reader" '(reverse [1 2 3])'    '=> \[3 2 1\]'
t  "set/value through Shen" '(set e2x 5)
(value e2x)'              '=> 5'
t  "malformed define errors, repl survives" '(define bad { number --> number } X -> )
(+ 2 2)'                  'No condition was true' '=> 4'
t  "(cd /; pwd) runs as subshell" '(cd /; pwd)'    '> /'
tn "(cd /; pwd) is not Shen eval" '(cd /; pwd)'    '=>'
t  "(echo quoted semicolon) is Shen" '(echo "a;b")'    'global not found: echo'

echo "== NEW: quoting and field splitting =="

t  "echo \"a b\" (one arg)"  'echo "a b"'               '> a b$'
t  "echo a b (two args)"     'echo a b'                 '> a b$'
t  "echo 'a b' (one arg)"    "echo 'a b'"               '> a b$'
t  "echo a\\ b (escaped ws)" 'echo a\ b'                '> a b$'
t  "unset var word removed"  'echo a $E2UNSETZZZ b'     '> a b$'
t  "quoted unset -> empty"   'echo "a${E2UNSETZZZ}b"'   '> ab$'
t  "field split in redirect target is an error" \
     'setenv E2AMBIG "a b"
ls > $E2AMBIG'                                            'ambiguous redirect'

echo "== NEW: redirection =="

t  "stdout > file"       "echo hi >$D/x
cat $D/x"                                               '> hi'
t  "append >>"           "echo one >$D/f
echo two >>$D/f
cat $D/f"                                                'one' 'two'
t  "stderr 2> file"      "nosuchcmd-zzz 2>$D/e
cat $D/e"                                                'exit 127' 'not found'
t  "2>&1 merges into captured stdout" 'echo hi 2>&1'    '> hi'
# 2>&1 BEFORE >file: the dup snapshots the current stdout (the capture
# tmpfile), THEN stdout goes to the file — the file must hold x and the
# capture must stay empty (x appears exactly once, via the cat).
tc "2>&1 >file ordering (plan F.5)" "echo x 2>&1 >$D/o
cat $D/o"                                               '> x' 1

echo "== NEW: pipelines and chains =="

t  "seq | head"          'seq 1 5 | head -3'            '> 1' '^2$' '^3$'
t  "pipe+head truncation" 'find . -maxdepth 1 -name AGENTS.md | head -1'  '\.\/AGENTS\.md'
t  "true && echo yes"    'true && echo yes'             '> yes'
t  "false || echo no"    'false || echo no'             '> no'
t  "echo a; echo b"      'echo a; echo b'               '> a' '^b'
t  "false exit tracking" 'false
echo $?'                                                 '> 1'

echo "== NEW: variables =="

t  "setenv + \$VAR"      'setenv E2FOO hello
echo $E2FOO'                                             '> hello'
t  "\${VAR}x"            'setenv E2V world
echo ${E2V}x'                                            '> worldx'
t  "export alias"        'export E2EX=v
echo $E2EX'                                              '> v'

echo "== NEW: subshell =="

t  "(cd /; pwd) isolated" '(cd /; pwd)
pwd'                                                     '> /' "$(pwd)"
t  "subshell in a chain" '(cd / && pwd)'                 '> /'

echo "== NEW: heredoc (sh-continue protocol) =="

t  "heredoc multi-line"  'cat << EOF
line one
line two
EOF
echo done'                                               'line one' '^line two$' '> done'
t  "heredoc EOF error"   'cat << EOF
unterminated body'                                       'unexpected EOF'

echo "== NEW: rejects =="

t  "backtick rejected"   'echo `x`'                     'error:.*backtick'
t  "\$( ) rejected"      'echo $(x)'                    'error:.*command substitution'
t  "bare & rejected"     'sleep 1 &'                    'error:.*background'

echo "== NEW: fd-dup edges (truncated / invalid N>&) =="

t  "2>& rejected as bad fd-dup"  'echo hi 2>&'          'error:.*bad fd-dup'
t  "2>&x rejected as bad fd-dup" 'echo hi 2>&x'         'error:.*bad fd-dup'
tn "2>& is not a background &"   'echo hi 2>&'          'background'
t  "2>&1 still a valid dup"       'echo hi 2>&1'        '> hi'
t  "2>&2 still a valid dup"       'echo hi 2>&2'        '> hi'

echo "== NEW: positional parameters (interactive) =="

t  "\$0 is the invocation path"  'echo X$0X'            "X\./shenshX"
t  "interactive \$# is 0"        'echo N$#N'            'N0N'
t  "interactive \$1 is empty"    'echo [$1]'            '>\ \[\]$'
t  "\$\$ is the shell PID (numeric)" 'echo P=$$'        'P=[0-9]+'
t  "\$- is i when interactive"   'echo F=$-'            'F=i'
t  "\$! empty (no background jobs)" 'echo B=[$!]'       'B=\[\]'

# cp <name> <cmd> <operands-string> <expect-ERE> [<expect-ERE>...]
#   -c mode: the cmd string is single-quoted through eval (its own quotes and
#   $-refs stay literal), the operands string is word-split by bash (first
#   operand names $0, the rest are $1..$9 — bash convention).  Every expect
#   pattern must match the combined output.
cp() {
    local name="$1" cmd="$2" operands="$3"
    shift 3
    local out rc
    # eval string after first expansion: "$BIN" "$BUNDLE" -c '<cmd verbatim>'
    # + operands.  \$BIN/\$BUNDLE stay backslashed (expanded BY eval, in double
    # quotes there); $cmd expands NOW into single quotes so eval re-parses it
    # as ONE literal word — its $-refs and double quotes survive untouched
    # for shensh to expand (cmds must not contain single quotes).
    out="$(eval "\"\$BIN\" \"\$BUNDLE\" -c '$cmd' $operands" 2>&1)"
    rc=$?
    out="$out
(exit $rc)"
    local ok=1 pat
    for pat in "$@"; do
        if ! printf '%s' "$out" | grep -qE -- "$pat"; then
            ok=0
            echo "FAIL $name"
            echo "  cmd:      $cmd $operands"
            echo "  expected: /$pat/"
            printf '%s' "$out" | grep -v -E 'Loaded|Perfect' | head -4 | sed 's/^/  /'
            break
        fi
    done
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1))
        echo "ok   $name"
    else
        fail=$((fail + 1))
    fi
}

echo "== NEW: positional parameters (shensh -c) =="

cp "-c \$0 \$1 \$2 \$#"   'echo $0 $1 $2 $#'      'myname aa bb'   'myname aa bb 2'
cp "-c default \$0 is argv0" 'echo [$0]'         ''              '\./shensh'
cp "-c quoted \"\$@\" separate fields" 'printf [%s][%s][%s] "$@"' 'nm x y z' '\[x\]\[y\]\[z\]'
cp "-c quoted \"\$*\" one field"    'printf [%s] "$*"'         'nm x y z'    '\[x y z\]'
cp "-c unquoted \$* re-splits"      'printf [%s][%s] $*'       'nm x y'      '\[x\]\[y\]'
cp "-c \$\$ numeric PID"            'echo P=$$'                 'nm'          'P=[0-9]+'
cp "-c \$- is c"                    'echo F=$-'                 'nm'          'F=c'
cp "-c \$! empty"                   'echo B=[$!]'               'nm'          'B=\[\]'
cp "-c false exits 1"               'false'                     'nm'          'exit 1'
cp "-c not-found exits 127"         'nosuchcmd-zze2e'           'nm'          'exit 127'

echo
echo "shensh-e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0

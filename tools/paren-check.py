#!/usr/bin/env python3
"""paren-check.py — Shen/SKLambda bracket & paren balance checker.

Checks every `(define NAME ...)` block in a Shen source file for balanced
parentheses and brackets, ignoring:
  - string literals ("...", with \\-escapes preserved as opaque)
  - block comments ( \\* ... *\\ )

Why a state machine (not regex): bracket lists [ ... ] nest like parens, and
strings can contain unbalanced ( ) [ ] and \\-escapes.  A naive count of just
( and ) gives false positives on e.g. `[fail "msg"]` and `(str "a)b")`.

Usage:
  python3 tools/paren-check.py shen/tc-hm-w.shen [more files...]
  # exit 0 if all defines balanced, exit 1 if any imbalance found

Output:
  per-define balance lines only for imbalanced defines, then a summary line.
"""

import re
import sys


def strip_strings_and_comments(s):
    """Return a copy of s with string literals and \\* *\\ comments replaced
    by their non-delimiter characters removed, preserving ( ) [ ] balance
    structure.  Operates as a single left-to-right state machine."""
    out = []
    i = 0
    n = len(s)
    in_str = False
    while i < n:
        c = s[i]
        if in_str:
            if c == "\\":
                # escape: keep nothing, skip the escaped char too
                i += 2
                continue
            if c == '"':
                in_str = False
                i += 1
                continue
            i += 1
            continue
        # not in string
        if c == '"':
            in_str = True
            i += 1
            continue
        if s[i:i + 2] == "\\*":
            j = s.find("*\\", i + 2)
            if j < 0:
                break  # unterminated block comment: drop the rest
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_define_block(body):
    """Return (open_count, underflow_pos).  Tracks both ( and [ as openers;
    ) and ] must match the top of the stack.  underflow_pos is None if no
    early close was seen."""
    stack = []
    for idx, ch in enumerate(body):
        if ch in "([":
            stack.append(ch)
        elif ch == ")":
            if not stack or stack[-1] != "(":
                return len(stack), idx
            stack.pop()
        elif ch == "]":
            if not stack or stack[-1] != "[":
                return len(stack), idx
            stack.pop()
    return len(stack), None


def check_file(path):
    """Check all (define NAME ...) blocks in one file.  Return list of
    (name, open_count, underflow_pos) for imbalanced defines."""
    problems = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"paren-check: cannot read {path}: {e}")
        return problems
    stripped = strip_strings_and_comments(src)
    # Split into top-level blocks starting at a `(define ` at line start.
    parts = re.split(r"\n(?=\(define )", stripped)
    for part in parts:
        m = re.match(r"\(define (\S+)", part)
        if not m:
            continue
        name = m.group(1)
        open_count, underflow = check_define_block(part)
        if open_count != 0 or underflow is not None:
            problems.append((name, open_count, underflow))
    return problems


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    any_bad = False
    for path in argv:
        problems = check_file(path)
        for name, open_count, underflow in problems:
            loc = f" underflow@char {underflow}" if underflow is not None else ""
            print(f"IMBALANCE {path} {name:30s} open={open_count}{loc}")
            any_bad = True
    if any_bad:
        print("HAS IMBALANCES")
        return 1
    print("ALL BALANCED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

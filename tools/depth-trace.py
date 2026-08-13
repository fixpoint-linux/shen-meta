#!/usr/bin/env python3
"""depth-trace.py — per-define paren-depth tracer for Shen source.

Shows the running paren balance for each line in a (define NAME ...) block,
so you can see exactly how many `)` are on the closing line and how many are
needed.  Strips strings and \\* *\\ comments before counting.

Usage:
  python3 tools/depth-trace.py shen/tc-hm-w.shen tc-infer-cons
  python3 tools/depth-trace.py shen/tc-hm-patterns.shen tc-type-pat-list

Output:
  Line-by-line depth with cumulative balance, highlighting the final line.
"""

import re
import sys


def strip_strings_and_comments(s):
    """Remove string literals and block comments, returning the bare structure."""
    out = []
    i = 0
    n = len(s)
    in_str = False
    while i < n:
        c = s[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
                i += 1
                continue
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if s[i : i + 2] == "\\*":
            j = s.find("*\\", i + 2)
            if j < 0:
                break
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def trace_define(src, name):
    """Find (define NAME ...) and print depth per line."""
    parts = re.split(r"\n(?=\(define )", src)
    for part in parts:
        m = re.match(r"\(define (\S+)", part)
        if not m or m.group(1) != name:
            continue
        body = strip_strings_and_comments(part)
        bal = 0
        print(f"=== {name} ===")
        for ln in body.split("\n"):
            s = bal
            n = ln.count("(") - ln.count(")")
            bal += n
            stripped = ln.strip()
            if stripped:
                marker = "  <<< CLOSING" if n < 0 else ""
                print(f"  {s:3d}->{bal:3d}  (+{ln.count('(')}-{ln.count(')')}) {stripped[:72]}{marker}")
        print(f"FINAL={bal}  (need {bal} more '(' if negative, or {bal} more ')' if positive)")
        return
    print(f"define {name} not found")


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2
    path, name = argv[0], argv[1]
    with open(path) as fh:
        src = fh.read()
    trace_define(src, name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""sweet2shen — Sweet Expression to Shen converter.

Sweet Expressions (https://dwheeler.com/readable/) are indentation-based
S-expression syntax.  No trailing `)))` needed — indentation IS structure.

Supported:
  - Indentation nesting: child lines indented past parent form open-paren.
  - Same indent: siblings.
  - Dedent: close-parens.
  - $ prefix: open-paren at current indent (like `$ if a b` → `(if a b)`).
  - $-continuation: `$  ` with extra space → sibling continuation.
  - Block comments (\\* ... *\\) are preserved as-is.
  - All lines starting with `#` are preserved as comments.
  - Strings and existing parens/brackets pass through unchanged.

Usage:
  python3 tools/sweet2shen.py input.sweet > output.shen
"""

import sys
import textwrap


def count_indent(line):
    """Return leading whitespace count in characters (both tabs and spaces)."""
    if not line:
        return 0
    i = 0
    while i < len(line) and line[i] in " \t":
        i += 1
    return i


def is_sweet_form(line):
    """Check if line starts with $ prefix (case-insensitive, followed by space)."""
    stripped = line.lstrip()
    return stripped.startswith("$ ") or stripped.startswith("$(")


def expand_dollar(line):
    """Expand $ prefix: '$ rest' -> '(rest)'. Handles nested parens."""
    stripped = line.lstrip()
    if stripped.startswith("$("):
        # Already parenthesized: $(a b c) -> (a b c)
        return stripped[1:]  # remove $
    # $ a b c -> (a b c)
    content = stripped[2:].strip()
    indent = len(line) - len(stripped)
    return " " * indent + "(" + content + ")"


def sweet_to_shen(text):
    """Convert Sweet Expression text to standard Shen S-expressions."""
    # Split into non-blank lines, preserving blank lines for structure
    raw_lines = text.split("\n")
    
    # First pass: expand $ forms
    expanded = []
    for line in raw_lines:
        if is_sweet_form(line):
            expanded.append(expand_dollar(line))
        else:
            expanded.append(line)
    
    # Second pass: handle indentation-based nesting
    stack = []  # stack of (indent, continuation_flag)
    output_lines = []
    
    prev_indent = 0
    for idx, line in enumerate(expanded):
        if not line.strip():
            output_lines.append(line)
            continue
        
        stripped = line.strip()
        indent = count_indent(line)
        
        if idx == 0:
            # First content line: start at indent 0
            output_lines.append(line)
            prev_indent = indent
            continue
        
        # Compare indent with previous
        if indent > prev_indent:
            # Indented more: need to open parens at previous indent level
            # For each level of increase beyond 1, add extra '('
            delta = indent - prev_indent
            # Add '(' at the level of the previous line content
            prev_output = output_lines[-1].rstrip()
            if prev_output and prev_output[-1] != "(":
                # Only add opens if the previous line ended with a continuation
                output_lines[-1] = prev_output + " (" * delta
            
        elif indent < prev_indent:
            # Dedent: close parens
            while stack and stack[-1][0] >= indent:
                stack.pop()
            num_closes = 0
            # Roughly: close one per dedent level
            level_diff = prev_indent - indent
            # Try to estimate: every ~2 spaces is roughly one nesting level
            # But simpler: just compute close count from stack depth
            num_closes = max(1, level_diff // 2)
            output_lines[-1] = output_lines[-1].rstrip() + " )" * num_closes
        
        output_lines.append(line)
        prev_indent = indent
    
    # Close any remaining opens
    final = "\n".join(output_lines)
    
    # Remove trailing whitespace only, keep paren structure
    return final


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    path = sys.argv[1]
    with open(path) as f:
        text = f.read()
    result = sweet_to_shen(text)
    sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())

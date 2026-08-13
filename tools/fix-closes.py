#!/usr/bin/env python3
"""fix-closes.py — auto-fix trailing close parens for one define.
Usage: python3 tools/fix-closes.py shen/tc-hm-w.shen tc-infer-cons
"""
import re, sys
def strip(s):
    out=[];i=0;in_str=False
    while i<len(s):
        c=s[i]
        if in_str:
            if c=='\\': i+=2; continue
            elif c=='"': i+=1; in_str=False; continue
            else: i+=1; continue
        if c=='"': in_str=True; i+=1; continue
        if s[i:i+2]=='\\*': j=s.find('*\\',i+2); i=j+2; continue
        out.append(c); i+=1
    return ''.join(out)

path,name=sys.argv[1:]
src=open(path).read()
parts=re.split(r'\n(?=\(define )', src)
for part in parts:
    m=re.match(r'\(define (\S+)',part)
    if not m or m.group(1)!=name: continue
    body=strip(part)
    lines=part.split('\n')
    # compute running depth on original (non-stripped) lines, counting ONLY the body lines
    # (skip the type-sig line)
    bal=0
    for li,ln in enumerate(body.split('\n')):
        bal+=ln.count('(')-ln.count(')')
    if bal==0: print(f'{name}: already balanced'); sys.exit(0)
    # Find the last line with closes, adjust it
    need=bal  # positive means need more )
    print(f'{name}: needs {need} more close(s), fixing terminal line...')
    # Find last non-blank line
    for i in range(len(lines)-1,-1,-1):
        if lines[i].strip():
            # add `need` closes to the end of this line
            if need>0: lines[i]=lines[i]+(')'*need)
            elif need<0:
                # remove -need closes
                to_remove=-need
                if lines[i].endswith(')'*to_remove):
                    lines[i]=lines[i][:-to_remove]
            break
    # Reconstruct
    new_src=src.replace(part,'\n'.join(lines))
    open(path,'w').write(new_src)
    print(f'{name}: fixed ({need:+d} closes)')
    sys.exit(0)
print(f'{name}: not found')

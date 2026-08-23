#!/usr/bin/env python3
"""gen-symbol-static.py — build the static symbol intern table for the C VM.

Reads globals.csexp (the reduced self-contained bundle) and emits two files:
  vm/symbol_static.h   — declarations + MPH parameters
  vm/symbol_static.c   — the static symbol array (indexed by MPH slot) + the
                         displacement table g[] + the hash/lookup functions

DESIGN (closed world): every VAL_SYMBOL carries a canonical char* so that
symbol pointer-equality is sound: a name is one
pointer iff pointer-eq == strcmp-eq.  The bundle's symbol literals are a FIXED
compile-time set ("the subset/meta-interp bundle"), so they live in a STATIC
table addressed by a MINIMAL PERFECT HASH (N keys -> N slots, O(1)).  Any name
NOT in the static set (OS .kl symbols loaded at runtime, gensym/newvar/intern)
is interned in the DYNAMIC store in val_symbol (checked AFTER the static MPH).

The MPH is a two-level displacement scheme:
  bucket = h(name, H2) % m
  index  = (h(name, H1) % N + g[bucket]) % N
where g[b] is a per-bucket offset chosen so the map is a bijection onto 0..N-1.
h() is the same djb2-xor variant used in val_symbol.  The generator searches
seeds deterministically and emits the first working (m, H1, H2, g[]) tuple, so
regeneration from the same bundle is reproducible.

Regenerate with:  python3 tools/gen-symbol-static.py
(wired into the Makefile as `gen-symbol-static`; the output is COMMITTED so
`make zincvm` builds standalone, and is only regenerated when globals.csexp is
newer — mirroring gen-prims.)
"""
import re, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CSEXP = os.path.join(ROOT, "globals.csexp")

OUT_C = os.path.join(ROOT, "vm", "symbol_static.c")
OUT_H = os.path.join(ROOT, "vm", "symbol_static.h")

# djb2-xor-seed, MUST match h() in val_symbol (vm/zincvm.c)
def h(s, seed):
    x = 5381
    for c in s.encode():
        x = ((x << 5) + x) ^ c
    x ^= seed
    return x & 0x7FFFFFFF

def extract_symbols(path):
    data = open(path).read()
    syms = set()
    for m in re.finditer(r"\[(\d+):s\]", data):
        n = int(m.group(1))
        val = data[m.end():m.end() + n]
        if len(val) == n:
            syms.add(val)
    return sorted(syms)

def build_mph(syms):
    """Return (m, H1, H2, g, sym_at_slot) or None.  Deterministic seed search."""
    N = len(syms)
    # seed candidates, deterministic
    H1_CANDS = [1, 7, 0x9E3779B9, 0x1B873593, 5381, 0x85EBCA6B]
    H2_CANDS = [2, 11, 0x85EBCA6B, 0xC2B2AE35, 13, 0x9E3779B9]
    M_CANDS = [N // 2, N // 3, max(512, N // 2), 1024, N, 2048]
    M_CANDS = sorted({m for m in M_CANDS if m > 0})

    for m in M_CANDS:
        for H1 in H1_CANDS:
            for H2 in H2_CANDS:
                buckets = {}
                for s in syms:
                    b = h(s, H2) % m
                    buckets.setdefault(b, []).append(s)
                order = sorted(buckets.keys(), key=lambda b: -len(buckets[b]))
                g = [0] * m
                occ = [False] * N
                ok_all = True
                for b in order:
                    keys = buckets[b]
                    base = [h(k, H1) % N for k in keys]
                    placed = False
                    for r in range(N):
                        seen = set()
                        good = True
                        for i in base:
                            idx = (i + r) % N
                            if occ[idx] or idx in seen:
                                good = False
                                break
                            seen.add(idx)
                        if good:
                            for i in base:
                                occ[(i + r) % N] = True
                            g[b] = r
                            placed = True
                            break
                    if not placed:
                        ok_all = False
                        break
                if ok_all and all(occ):
                    sym_at_slot = [None] * N
                    for s in syms:
                        idx = (h(s, H1) % N + g[h(s, H2) % m]) % N
                        assert sym_at_slot[idx] is None
                        sym_at_slot[idx] = s
                    assert all(sym_at_slot)
                    return (m, H1, H2, g, sym_at_slot)
    return None

def c_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

def main():
    if not os.path.exists(CSEXP):
        sys.exit("globals.csexp not found — run `make bundle` first")
    syms = extract_symbols(CSEXP)
    N = len(syms)
    print(f"extracted {N} distinct bundle symbols from {CSEXP}")

    r = build_mph(syms)
    if r is None:
        sys.exit("ERROR: could not construct a minimal perfect hash for this symbol set")
    m, H1, H2, g, sym_at_slot = r
    print(f"MPH: N={N} m={m} H1=0x{H1:x} H2=0x{H2:x} maxg={max(g)}")

    # sanity: verify bijection
    assert set(g) and max(g) < N
    slots = [(h(s, H1) % N + g[h(s, H2) % m]) % N for s in syms]
    assert len(set(slots)) == N, "not a bijection"

    hdr = f"""/* symbol_static.h — auto-generated by tools/gen-symbol-static.py. DO NOT EDIT.
 * Static symbol intern table for the closed-world (subset/meta-interp) bundle.
 * N={N} symbols, minimal-perfect-hash: index=(h(name,H1)%N + g[h(name,H2)%{m}])%N.
 */
#ifndef SYMBOL_STATIC_H
#define SYMBOL_STATIC_H

#define SYMBOL_STATIC_N {N}
#define SYMBOL_STATIC_M {m}
#define SYMBOL_STATIC_H1 0x{H1:08X}u
#define SYMBOL_STATIC_H2 0x{H2:08X}u

/* Return the canonical char* for `name` if it is a static (bundle) symbol,
   else NULL.  The returned pointer is a static-lifetime array element, so it
   is a stable, unique identity for the name (pointer-eq == strcmp-eq). */
const char *symbol_static_lookup(const char *name);

#endif
"""
    with open(OUT_H, "w") as f:
        f.write(hdr)

    # g[] table
    g_lines = []
    for i in range(0, m, 12):
        g_lines.append("    " + ", ".join(str(g[j]) for j in range(i, min(i + 12, m))) + ",")
    g_body = "\n".join(g_lines)

    # sym array
    sym_lines = []
    for i in range(0, N, 4):
        sym_lines.append("    " + " ".join(f'"{c_escape(sym_at_slot[j])}",' for j in range(i, min(i + 4, N))))
    sym_body = "\n".join(sym_lines)

    # note: the lookup needs to read the actual symbol to confirm strcmp; we
    # cannot reference the array before declaring it, so write it properly.
    src = f"""/* symbol_static.c — auto-generated by tools/gen-symbol-static.py. DO NOT EDIT.
 * Minimal-perfect-hash static symbol table for the closed-world bundle.
 * N={N} symbols.  Lookup: idx=(h(name,H1)%N + g[h(name,H2)%M])%N, then
 * strcmp confirms (MPH is a bijection on the static set, so a match is exact;
 * a non-static name whose hash lands on a slot simply fails strcmp -> NULL).
 */
#include "symbol_static.h"

static const char *const sym_static[{N}] = {{
{sym_body}
}};

static const unsigned int sym_g[{m}] = {{
{g_body}
}};

/* djb2-xor-seed — MUST match h() in val_symbol (vm/zincvm.c). */
static unsigned int sym_static_hash(const char *name, unsigned int seed) {{
    unsigned int x = 5381;
    const unsigned char *p = (const unsigned char *)name;
    while (*p) {{ x = ((x << 5) + x) ^ *p; p++; }}
    return (x ^ seed) & 0x7FFFFFFF;
}}

const char *symbol_static_lookup(const char *name) {{
    unsigned int b   = sym_static_hash(name, SYMBOL_STATIC_H2) % SYMBOL_STATIC_M;
    unsigned int base= sym_static_hash(name, SYMBOL_STATIC_H1) % SYMBOL_STATIC_N;
    unsigned int idx = (base + sym_g[b]) % SYMBOL_STATIC_N;
    const char *s = sym_static[idx];
    /* strcmp loop (avoid strcmp dependency): confirm identity */
    const char *a = s, *q = name;
    while (*a && *a == *q) {{ a++; q++; }}
    if (*a == 0 && *q == 0) return s;
    return (const char *)0;
}}
"""
    with open(OUT_C, "w") as f:
        f.write(src)

    print(f"wrote {OUT_H}")
    print(f"wrote {OUT_C}")

if __name__ == "__main__":
    main()

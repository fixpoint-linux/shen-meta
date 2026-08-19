# QBE GC-root verifier (`make qbe-gc-verify`)

A Soufflé Datalog checker that statically finds **GC-root violations** in the
QBE-native closures (`globals.qbe`) — the analogue of `tools/gc-verify` (which
checks the C VM `vm/zincvm.c`), but over the QBE IR instead of a C AST.

Opt-in, not gating. Requires `souffle` on `$PATH` and Python 3 (stdlib only).
Run from the repo root with:

```sh
make qbe-gc-verify     # globals.qbe must exist (make qbe-gen)
```

## What it checks

The QBE backend (`shen/qbe.shen`) lowers every bundled closure to a QBE
function `function $clo_X(l %out, l %a0, ...)`. Each `Value` temp is a
native-stack slot `%tN =l alloc8 40` (sizeof(Value)==40). The GC is
**precise-only** (`vm/gc.c` — shadow stack + typed walkers; the only C-stack
scan, `gc_stale_scan_stack`, is diagnostic and explicitly does not cover QBE
frame slots). The lowerer emits **no** shadow-stack pushes for these slots.

So a GC-triggered allocation mid-closure can collect a live `Value` reachable
only from an unrooted frame slot → dangling pointer → heap corruption.

The Datalog rule flags exactly that:

```
root_miss(f, sid, t) :- live_at(f, sid, t), collecting_call(f, sid).
```

- `gc_value(f,t)` — temp `t` holds a GC-managed `Value` (out of a producing
  call: `prim_*` / `clo_*` / `val_*_into` / `trap_*` / `copy_value`, or a phi
  joining such).
- `local_slot(f,t)` — `t` is an `alloc8 40` slot (params `%out`/`%aN` are
  caller-rooted and excluded).
- `live_at(f,sid,t)` — `t` is defined before call `sid` and read after it
  (linear per-function liveness — over-approximates across branches, so the
  counts are an **upper bound**).
- `collecting_call(f,sid)` — any call except `is_false` (the only non-collecting
  call in the output).

## Current result (2026-08-19)

`total_rm = 306,777` root-miss sites across **815 of 913** native closures.
Worst offenders: `shen.kmacros` 79,987, `shen.interp` 30,276,
`shen.tc_build_prim_table` 6,629, `shen.csexp_body` 3,075,
`shen.resolve_code` 2,247, `shen.debruijn` 1,912.

**This is why the QBE native closures are not GC-safe for real workloads.** The
differential tests (`make diff-test`) pass only because each is a tiny closure
that never fills the 2 MB nursery mid-execution (the driver roots the inputs).
Loading the Shen OS (`core.kl`, heavy allocation) corrupts → dangling-pointer
garbage → `No condition was true` during `interp-load-raw`. This blocks the
native REPL (`make qberepl`).

## Output

- `out/n_affected.csv` — number of closures with ≥1 root_miss.
- `out/total_rm.csv` — total root_miss sites.
- `out/rm_gt0.csv` — per-closure root_miss count (tab-separated `function count`).

## Verifying a fix

After the GC-rooting fix lands, re-run this checker:

- If the fix is **lowerer-emitted precise roots** (`gc_root_push_*` per live
  slot before collecting calls): `root_miss` should drop to 0 — the checker
  directly verifies it.
- If the fix is a **conservative C-stack scan** (making the native stack a root
  source): `root_miss` will still be non-zero (the checker models the
  precise-root contract), and the tool is instead a *prioritized list* of the
  live slots the conservative scan must cover — i.e. the upper bound a
  conservative scan would have to pin.

# Bundle Verifier — Shen safe-subset gate

A Soufflé Datalog verifier that mechanically checks the Shen meta-interpreter
bundle (`globals.csexp`) is in the **safe subset**. Unlike `tools/gc-verify/`
(verifier + candidate generator), this is a **sound gate**: a clean run proves
no safe-subset violation. See `docs/bundle-verify.md` for the design and the
Check A / Check B (type-safety, out of Datalog scope) split.

## Quick start

```sh
# Full run (requires souffle; parses ../../globals.csexp):
make run

# Self-test (Python stdlib, no souffle):
make selftest

# Refresh the expected/ baseline after a deliberate bundle change:
make snapshot
git diff expected/   # review before committing

# Clean up:
make clean
```

From the repo root, `make bundle-verify` delegates here (opt-in, non-gating).

## What it checks

| Relation | Checks |
|---|---|
| `bad_opcode` | no unknown opcodes (17-opcode ZINC set) |
| `dangling_global` | every `[global X]` resolves to a closure / allowed prim / keyword |
| `unknown_prim` | every `[prim X]` is in the `primitive?` allowlist (enforces util.shen↔types.shen sync) |
| `curried_call` | no adjacent apply/appterm (no partial-application crash) |
| `arity_mismatch` | every statically-resolvable call site supplies full arity |
| `unresolved_call` | call sites whose callee is a higher-order param (`[access N]`) |

## Arity model

The reduced bundle uses the `cur` closure-capture model: an N-arity defun
compiles to `(c(grab×(N-1) <Body>))` — the outer lambda becomes `cur`, inner
lambdas become `grab`. So **closure arity = leading_grab_count + 1** (the
first arg is the ZINC accumulator, not a grab). Verified against
`shen/zinc.shen` and `vm/zincvm.c` OP_APPLY/OP_GRAB.

`supplied_args` is computed by a forward-dataflow stack simulation in the
extractor (not Datalog) because arg-counting needs prim stack-consumption and
nested-call exclusion that Datalog can't express cleanly.

## Initial baseline (known, allowlisted findings)

The real-bundle baseline is NOT empty — it contains vetted, known rows:

- **`arity_mismatch` (2 rows)** — genuine **dormant currying bugs** caught by
  the full-arity gate (which `curried_call`'s adjacency heuristic misses):
  - `shen.kl->zinc,30,debruijn,2,1` — `debruijn` (2-arity) called with 1 arg.
  - `shen.debruijn.14.15.16.17,65,idx,2,1` — `idx` (2-arity) called with 1 arg.
  Both are dead code paths; `shen/interp.shen:251-259` explicitly warns that a
  curried `((debruijn []) N)` would fail at runtime under the C VM (no partial
  application). These are latent bugs, not false positives.
- **`dangling_global` (16 rows)** — 4 unique runtime symbols (`fail`, `ps`,
  `read-file`, `shen.f-error`) that the metacircular interp resolves at
  runtime, not the C VM's `global_table[]`. By-design.
- **`unresolved_call` (49 rows)** — `[access N]` higher-order parameter calls.
  The meta-interpreter's params are data, not callables; a full resolution
  needs points-to flow analysis (deferred).

## Soundness scope

**A clean run proves:** no unknown opcodes; no dangling globals; no
non-allowlisted prims; no partial-application/curried calls; all
statically-resolvable call sites full-arity; no safe-subset violations.

**It does NOT prove:** C VM correctness (gc-verify); `shen→kl` semantic
correctness (a compiler bug could emit structurally-valid but wrong bytecode);
GC/memory safety; type safety (Check B — HM inference needs unification,
outside Datalog; see docs/bundle-verify.md and the deferred in-Shen `tc +` /
algorithm-W workstream).

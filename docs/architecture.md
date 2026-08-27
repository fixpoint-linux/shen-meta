# Architecture

Source: `AGENTS.md`. The compiler pipeline, key files, design intent, and the
reduced self-contained bundle.

## Build & test

```sh
make              # build shensh + zincdec into zig/zig-out/bin/
make test         # zig build test -Doptimize=Debug (gc + vm suites)
make gate         # Debug + ReleaseSafe + ReleaseFast
make bundle       # serialize all safe wrappers → globals.csexp

# Trace execution of specific closures:
./shensh globals.csexp --trace + --trace reverse
```

## Pipeline

```
Shen source → kmacros → normalize-term → debruijn → zinc-c → compile-zinc → nat->csexp → Zig VM
```

## Key files (under `shen/` unless noted)

- `shen/interp.shen` — meta-circular ZINC VM (loads everything)
- `shen/normalize.shen` — KLambda normalization + debruijn indices
- `shen/zinc.shen` — KLambda → ZINC bytecode compiler
- `shen/compile.shen` — ZINC → canonical s-expression (csexp)
- `shen/primitives.shen` — 37 type-checked safe wrappers
- `zig/src/vm/` — the Zig VM (interp.zig, prims.zig, execplan.zig, marshal.zig, parser.zig, …)
- `zig/src/gc/` — custom moving generational collector (heap.zig, collect.zig, roots.zig)
- `shen/serialize-reduced.shen` — serialize the reduced bundle's global-table to csexp (`globals.csexp`)
- `shen/toplevel.shen` — `interp-eval` — compiles defun forms through interpreter
- `shen/load.shen` — flat-shen reader helpers (parse-string, skip-ws, strlen, …)
- `shen/util.shen` — `defun->lambda`, `primitive?` (single source of truth), `dedupe-globals`
- `shen/types.shen` — type definitions + DUPLICATE `primitive?` list (must stay synced!)

## Design intent (why static call sites skip safe wrappers)

The meta-circular interpreter (`interp` in `shen/interp.shen`) is written in Shen
and is meant to be PROVEN type-safe using the Shen sequent-calculus type rules,
and the native interpreter is meant to be GENERATED from that proven interpreter
(a static compiler that only compiles that subset, or by specialising the
interpreter). The Zig VM in `zig/src/vm/` is a hand-written stand-in for that
generated interpreter.

Consequence — call sites split into two kinds:

- **Static call sites** — code produced by the compiler is type-safe by
  construction (it comes from the proven interpreter). These need NO runtime type
  check and NO safe wrapper. `zinc-c`/`zinc-t` in `shen/zinc.shen` special-case
  `primitive?` heads to emit `[prim F]` — a direct primitive dispatch that
  BYPASSES the global table (and thus any `safe.X` wrapper registered via
  `set-toplevel`). This is intentional, NOT a bug.
- **Dynamic call sites** — boundaries, higher-order use, and untyped user input
  (e.g. `eval-kl` of `tc -` user code, `%%` escapes). These are NOT proven
  type-safe, so they must route through the Shen safe wrappers (`safe.X` in
  `shen/primitives.shen`) so a type error becomes a catchable `simple-error`.

`[global X]` → `safe.X` only fires on the dynamic path (a primitive used *as a
value*, higher-order, or explicit `(function X)`). Normal direct calls use
`[prim X]`. The C primitives have NO runtime type guards (the guard-enabled
`ZINCVM_DEBUG` build and its `PRIM_TYPE_ERROR` machinery were removed). Type
validation is owned entirely by the Shen safe-wrapper layer. This is safe ONLY
for a type-safe bundle.

## The reduced self-contained bundle (guard-free release VM)

The canonical bundle (`make bundle` → `globals.csexp`) is the **reduced
self-contained interpreter** (meta-interpreter `.shen` + the safe-subset
helpers). It self-hosts guard-free (exit 0). The full Shen OS is not bundled.

Always-on throw sites that are NOT type guards and stay in release: `simple-error`,
`fail`, `apply`/`appterm` non-callable + too-many-args, `env_pop`, `eval-kl` catch,
and `pos` out-of-bounds inside `trap-error` (semantic, needed for `strlen`/end-of-string).

## Partial application (metacircular interp only)

The metacircular interpreter (`shen/interp.shen`) supports partial application:
when a closure is called with fewer arguments than its arity, instead of entering
the closure body, it creates a new closure capturing the provided arguments. This
is implemented via the `arity`, `count-args`, and `drop-grabs` helpers in
`interp.shen`, with arity checks in the `apply` and `appterm` rules.

**The Zig VM does NOT support partial application** — it is intentionally simpler.
It runs only the subset of ZINC required for the meta-interpreter (the reduced
self-contained bundle), where all call sites are proven full-arity. If a bundled
closure calls another with a short argument list, the metacircular interp (which
runs ON the Zig VM) handles it — the VM never sees partial application directly.
This split is intentional: the metacircular interp runs full KLambda; the Zig VM
runs only the statically-proven subset.

## Self-hosting tests

| Test | Description | Status |
|---|---|---|
| 1-4 | +, reverse, factorial, open/close via inline OP_PRIM | Pass |
| A | toplevel-interp on `[]` → `[cons]` | Pass |
| B | toplevel-interp on `[number 42]` → `[number 42]` | Pass |
| C | interp `[] [cons] [] [] []` → `[cons]` | Pass |
| 5 | eval-kl `[+ 1 2]` via marshal chain | Pass |
| 6-7 | read-file-as-string, load via apply | Pass |
| 7b | read-from-string | Pass (returns [[+ 1 2]]) |
| 7b' | read-from-string typed define `{ A --> A }` | Pass (returns [[define id ...]]) — regression test for Bug #1 |
| 7c | read via string stream | Pass |
| 8-10 | id, newvar, defun->lambda (bundled in the reduced bundle) | Pass |

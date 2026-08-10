# Bundle Verifier — Soufflé Datalog for the Shen safe-subset (Check A)

Status: **PLAN — Check A (safe subset) in progress. Check B (type-safety) explicitly OUT of scope for Datalog.**

## Goal

Mechanically verify that the Shen meta-interpreter bundle (`globals.csexp`) is **in the safe
subset** — i.e. every closure's bytecode uses only known opcodes, references only resolvable
globals and allowlisted primitives, and every call site supplies **full arity** (no curried /
partial-application calls, which crash the C VM with `apply non-callable`). Unlike gc-verify,
this is a **sound gate** (conservative-complete for the subset), not just a candidate generator.

## Verdict (from feasibility assessment, 2026-08-10)

| Check | Tool | Verdict |
|---|---|---|
| **A — in the safe subset** | Soufflé Datalog | ✅ **Right tool.** Sound gate achievable. Splits into A1 (bundle) + A2 (source). |
| **B — type-safe** | Soufflé Datalog | ❌ **Wrong tool.** HM/ML polymorphic inference needs unification over an infinite type space; Datalog is finite-Herbrand fixpoint. Only a weak monomorphic tag-check is expressible (not a proof). Real proof = upstream `tc +` on source, or in-Shen algorithm-W. See "Check B" below. |

## Why two layers (A1 + A2)

By the time code reaches `globals.csexp`, source-level constructs (macros, `datatype`, pattern
shapes) are already flattened by `shen->kl`. So no single layer sees everything:

| Property | Visible at bundle (csexp)? | Visible at `.shen` source? |
|---|---|---|
| No curried calls / full arity | ✅ | ❌ |
| Valid opcode alphabet | ✅ | ❌ |
| Globals resolve, prims in allowlist | ✅ | ❌ |
| No `defmacro`/`datatype`/`freeze`/`thaw` | ❌ (erased) | ✅ |
| No `@p` / non-linear patterns | ❌ (compiled to `if`/`jmpf`) | ✅ |

**A1 + A2 together = a sound gate for safe-subset membership.**

## Check A1 — bundle-level (Datalog, ideal)

**Input:** `globals.csexp` (411 KB, ~1269 closures). Each closure `(name (c(<flat instr stream>)))`.
Wire format: atoms `[len:type]value` (type `s`/`n`/`S`/`b`); single-char opcodes
(`vm/zinctypes.h:66-83`).

**Opcode map** (from `vm/zinctypes.h`):
`a` access, `g` global, `f` jmpf, `j` jmp, `t` appterm, `p` apply, `m` pushmark, `c` cur,
`r` grab, `v` return, `e` let, `d` endlet, `n` number, `S` string, `s` symbol, `b` boolean,
`P` prim. `OP_COUNT=17`.

**Fact extractor** (`extract_bundle.py`, Python stdlib, mirrors gc-verify's `extract.py`
no-deps discipline). `parse_bundle` in `vm/zincvm.c` is the reference decoder.

**Facts:**
```
closure(name, arity)              # arity = count of `grab`
instr(name, idx, op)
operand(name, idx, kind, value)   # kind ∈ {n,s,S,b}
global_ref(name, idx, target)     # from [global X]
prim_ref(name, idx, prim)         # from [prim X]
call_site(name, idx, kind)        # kind ∈ {apply, appterm}
cur_lit(name, idx, sub_code_id)   # from [cur C] — inline lambda
pushmark(name, idx)
```

**Rules (sound gates):**
- `bad_opcode` — `instr(_,_,op) ∧ !opcode_valid(op)`.
- `dangling_global` — `global_ref(_,_,X) ∧ !closure(X) ∧ !prim(X) ∧ !keyword(X)`.
  Resolves against the bundle's own closures + `primitive?` (util.shen:53) + `instruction-keyword?`
  (util.shen:71).
- `unknown_prim` — `prim_ref(_,_,P) ∧ !prim_allowed(P)`. **Mechanically enforces the
  util.shen↔types.shen primitive-list sync** (currently convention-only).
- `curried_call` — two adjacent apply/appterm with no intervening value instruction.
  This is exactly what `zincdec --curried` does (`vm/zincdec.c:671-728`); Soufflé subsumes it.
- `arity_mismatch(caller, call_idx, callee, expected, supplied)` — for each
  `pushmark ... apply/appterm` block, count supplied args, resolve callee arity from
  `closure`/`cur_lit`, flag mismatch. Sound for callee kinds 1/2/4 (global, inline cur, prim).

**Diagnostic (empirical question):** count call sites whose preceding value-op is `[access N]`
(callee is a higher-order parameter). If empty, A1 needs **no flow analysis** and is a sound
gate. If non-empty, add Soufflé points-to flow analysis (which closures flow into which params).
**Expected: empty** — the meta-interpreter's params (`C`, `E`, `S`, `R`) are *data* (code lists,
env lists), not callables; concrete calls go to named globals (`lookup`, `lookup-global`, `interp`).

## Check A2 — source-level (Datalog, different extractor)

**Input:** the 9 `.shen` files. Extractor uses `read-file-raw` (`load.shen`) or a Python
s-expr reader → CSV.

**Rules (sound gates for what survives compilation):**
- `unsafe_construct` — head ∉ allowlist (define/lambda/let/if/and/or/do/set/where/`<-`/`%%`/
  newvar/function/protect/cons/`@p`/fst/snd/gensym/variable?). Flags `defmacro`, `datatype`,
  `freeze`, `thaw`, `cond`, `case`.
- `nonlinear_pattern` — pattern var repeats in one clause (silent-overwrite bug class,
  compiler.md:48-61).
- `tuple_pattern` — pattern ctor is `@p` (compiler.md:63-65).

## Check B — type-safety (NOT Datalog; deferred)

`docs/compiler.md:119` asks for HM/ML to *prove* the meta-interpreter type-safe. Datalog cannot
express HM unification. The only Datalog-feasible option is a **monomorphic tag-consistency**
check over the `zinc-value` universe (types.shen:49-123) — defense-in-depth, **not a proof**,
and it would reject polymorphic `id {A-->A}` (bundled).

**The real type-safety path (non-Datalog):**
1. Run host Shen `tc +` on `.shen` source BEFORE `shen->kl` strips signatures.
2. OR write an in-Shen algorithm-W HM checker on the `.kl` form (self-proving).
3. OR use an external ML/Haskell HM checker on an extracted form.

These belong in a separate workstream (roadmap item 2). Do NOT try to force Check B into Datalog.

### Why B-mono was deferred (2026-08-10)

The one Datalog-expressible reading of "type-safe" is a **monomorphic tag-consistency**
check (`B-mono`): at each primitive call, verify the statically-known tag of each argument
matches the primitive's expected input tag, over the `zinc-value` universe. It was assessed
against the canonical `globals.csexp` and **not built**, for three empirical reasons:

1. **Zero signal.** An optimistic local check found **0 true positives** and **~9,000
   uninferable sites** (37.5% of prim calls are preceded by `[access N]` env-slot loads —
   the interp's `C A E S R` params are by-design polymorphic zinc-values; you cannot
   monomorphise a metacircular interpreter against itself). Only ~192 sites had a locally
   visible literal argument, and all were already correct.
2. **Redundant with the sound gates.** The structural safe-subset (full-arity via A1,
   unsafe-construct/non-linear-pattern via A2) is already covered. B-mono's marginal catch
   space is narrower than the safe-subset layer and strictly weaker than Phase 5.
3. **Cost.** A primitive-tag table introduces a **third hand-curated primitive sync**
   (with `exec_primitive` and the `safe.X` wrappers) — reversing the mechanical-sync gain
   that `unknown_prim` exists to provide. Plus a per-slot tag-set stack simulation and a
   ~9,000-row baseline churn.

If a minimal `prim_tag_smell` check is ever wanted, it must be: local-only (literal args
preceding a monomorphic prim), named to signal "candidate, not gate", WARN-never-FAIL in CI,
and explicitly documented as **not a type check** (no polymorphism, no interprocedural flow,
no refined types). Otherwise Phase 5 provides the real proof and subsumes it.

## Architecture / reuse

Build `tools/bundle-verify/` as a **sibling** of `tools/gc-verify/`. Do NOT generalize the
gc-verify extractor (csexp parser ≠ clang AST). Copy the **governance pattern**: Makefile
`run`/`snapshot`/`selftest`/`clean` + `expected/` + `check_results.sh` (FAIL/WARN/OK) + the
"verifier + candidate generator, NOT an oracle" framing. Wire as opt-in `make bundle-verify`
(not part of `make`/`make test`/`make run-bundle`).

## Phased rollout

| Phase | Scope | Gate? |
|---|---|---|
| 0 | Scaffold `tools/bundle-verify/`: csexp extractor → CSV, skeleton .dl, Makefile + expected/ | — |
| 1 | A1 cheap checks: opcode alphabet, dangling globals, unknown prims, curried adjacency + **diagnostic query** (count `[access N]` call sites) | sound (cheap) + diagnostic |
| 2 | A1 sound full-arity check (callee kinds 1/2/4); flow analysis only if diagnostic non-empty | **sound gate** |
| 3 | A2 source-level checks (unsafe constructs, non-linear patterns, `@p` patterns) | **sound gate** |
| 4 | **DEFERRED** — B-mono assessed 2026-08-10, not built. Empirically 0 TP / ~9,000 uninferable sites on the canonical bundle; the safe-subset is already covered by the sound Check A gates, and the real type-safety proof is Phase 5 (non-Datalog). See Phase 5 row + "Why B-mono was deferred". | — |
| 5 | (separate, non-Datalog) Real type safety: `tc +` upstream, or in-Shen algorithm-W | proof |

## Soundness limits

**A clean Check A run proves:** no unknown opcodes; no dangling globals; no `[prim X]` outside
the allowlist; all call sites full-arity (unconditionally if diagnostic empty, else modulo flow
precision); no source constructs outside the subset; no non-linear / `@p` patterns.

**It does NOT prove:** C VM correctness (gc-verify's job); `shen->kl` semantic correctness (a
compiler bug could emit structurally-valid but wrong bytecode); GC/memory safety; type safety
(orthogonal).

## Key trap

Do NOT oversell B-mono as "type safety." The README must state explicitly: it checks tag
consistency over a finite universe; it is not HM and does not handle polymorphism.

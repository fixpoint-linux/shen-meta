# HM checker self-check (`make tc-hm-self`)

The HM type checker (Stages 1-4, `shen/tc-hm-*.shen`) is written in safe-subset
Shen and bundled into `globals.csexp`.  `make tc-hm-self` runs the checker on its
own 7 source files, closing the bootstrapping-trust loop: the checker is judged
by the exact same rules it applies to Group A (`make tc-hm`).

    make tc-hm        # checker on 6 Group A files (baseline: 58 OK / 0 FAIL)
    make tc-hm-self   # rebuilds bundle, then checker on its own 7 source files

## Results (as of commit 0b9e55e + this stage)

| File | defines | OK | FAIL |
|---|---|---|---|
| `shen/tc-hm-types.shen`   | 43 | 26 | 17 |
| `shen/tc-hm-w.shen`       | 33 |  6 | 27 |
| `shen/tc-hm-prims.shen`   |  6 |  6 |  0 |
| `shen/tc-hm-patterns.shen`| 23 |  5 | 18 |
| `shen/tc-hm-sig.shen`     | 14 |  4 | 10 |
| `shen/tc-hm.shen`         | 30 | 13 | 17 |
| `shen/tc-hm-runtime.shen` |  4 |  1 |  3 |
| **total**                 | **153** | **61** | **92** |

Only `tc-hm-prims.shen` (the hand-curated primitive table, concrete types only)
passes 6/6.  The other six files carry a large, uniform class of failures
documented below.

## Bugs fixed during this stage (not checker weakenings)

1. **`tc-fresh-tvar` arity** (`tc-hm-types.shen`).  Sig was `{ --> type }`
   (nullary) but the function is called as a 1-arg `(tc-fresh-tvar (intern ""))`
   at 16 call sites.  Changed to `{ symbol --> type }` with pattern `_ ->`.

2. **Type-variable id collision (non-termination).**  Fresh tvars (`tc-fresh-tvar`,
   global `tc-counter`, ids 0,1,2,…) collided with sig-parser tvars
   (`tc-sig-tvar`, `tc-sig-tvar-counter`, reset to 0 per sig, ids 0,1,2,…).
   When the first-checked define is polymorphic (e.g. `tc-empty? : (list A) -->
   boolean`), `tc-instantiate` → `tc-fresh-subs-for [0]` → `tc-fresh-tvar`
   produced `[[0 [tvar 0]]]` — a self-referential substitution that made
   `tc-apply-subst` / `tc-walk` loop forever.  This was masked in Group A only
   because `shen/types.shen`'s first two defines are monomorphic (advancing
   `tc-counter` past 0 before the first `forall` instantiation).  Fix: fresh
   tvars now use **negative ids** (`-1,-2,…`), so the two namespaces can never
   collide.  This is a termination fix, not a permissiveness change — the
   unification/inference algorithm is byte-identical.

## The remaining failures are a checker gap, not sig bugs

All 92 FAILs share a root cause: the checker's **type language cannot type
its own implementation**.  The checker represents every internal structure as an
*opaque ground* `[con X]` for custom lowercase sig names (`type`, `subst`, `env`,
`expr`, `tc-result`, `result`, `pat-result`, `bindings`, `infer-result`).  These
names are NOT in `tc-opaque-ground?` (which only knows `zinc-value`, `klambda`,
`zinc-code`, `zinc-instruction`, `absvector`, `stream`, `error`), and they are
leaves that do not unify with `(list A)` or `[con symbol]`.

Concretely, the checker's own bodies do four things its type system forbids:

1. **Decompose an opaque ground with `hd` / `tl` / `cons?`.**  e.g.
   `tc-type-tag : { type --> symbol }` calls `(hd T)` on `T : type`.  `hd` is
   typed `(list A) --> B`, so `[con type]` vs `[app list A]` → `type mismatch:
   con vs other`.  Every type/pattern accessor (`tc-type-tag`, `tc-tvar-id`,
   `tc-con-name`, `tc-arrow-dom`, `tc-app-con`, `tc-walk`, `tc-apply-subst`,
   `tc-instantiate`, `tc-parse-sig-type`, `tc-type-pattern-dispatch`, …) hits
   this.

2. **Compare an opaque ground to a concrete type via `=`.**  e.g.
   `tc-rule-arrow? : { expr --> boolean }` computes `(= X (intern "->"))` with
   `X : expr`; `=` unifies `[con expr]` with `[con symbol]` → `con mismatch:
   symbol vs expr`.

3. **Match `[]` / literal-head patterns against a custom opaque type.**  e.g.
   `tc-extract-name : { (list expr) --> symbol }` has pattern `[define Name | _]`;
   the literal head `define` cannot unify with the element type `[con expr]`.
   (The opaque-cons fallback in `tc-type-pat-cons2` only rescues *cons*
   patterns against the 7 hard-coded opaque grounds — not `[]`, not literal
   heads, and not custom names.)

4. **Unify a unary function type with a concrete con** (`type mismatch: arrow vs
   other`, the single largest category, ~30/92).  This arises when a value typed
   as a function arrow (e.g. an instantiated scheme, or the result of a lookup
   that the checker models permissively) is used where a concrete con is
   expected — e.g. an `if`-condition tested for `boolean`, or a `cn`/`hd`
   argument.  These flow from the same opaque-model gap: the checker cannot see
   that a function-valued expression will eventually reduce to a ground value.

These are **not** wrong sigs: the sigs are semantically correct (e.g.
`tc-type-tag` really does take a type and return a symbol).  The gap is that the
checker models its own data as opaque leaves while the implementation treats
them as cons cells.  Closing it would require extending the type language (or
`tc-opaque-ground?`), which is precisely the "weaken the checker" anti-goal —
so these are documented as known self-check exclusions, NOT fixed by loosening.

Note: `tc-infer-app-two` (`tc-hm-w.shen`) has a *separate* genuine arity bug — its
sig declared 5 args while the clause binds 6 (`PairArg`).  That was fixed in this
stage (sig now `{ env --> type --> type --> (list expr) --> subst -->
(list subst type) --> infer-result }`); it remains a FAIL only because the body
then hits the opaque `hd`/`tl` gap, so it stays in the exclusion bucket rather
than flipping to OK.

## Trust boundary

`make tc-hm-self` proves only **self-consistency**: that each define's body
respects its *declared* sig under the checker's own rules.  It does not prove
the sigs are semantically correct (they are hand-written axioms and remain the
trust root), nor that the checker's permissiveness (klambda-top, opaque-cons,
fresh-tvar-for-cons) is sound.  The 92 exclusions above mean the self-check
currently closes the loop on ~40% of the checker's own defines (61/153, all of
`tc-hm-prims.shen` plus the list/unification/formatting helpers), and documents
the accessor/inference layer as a known, uniform checker gap.

## Governance

Opt-in, not gating — mirrors `make bundle-verify`.  `tc-hm`
and `tc-hm-self` are NOT in `make` / `make test`.  A regression in the passing
subset is visible as a changing OK/FAIL count in `make tc-hm-self` output.

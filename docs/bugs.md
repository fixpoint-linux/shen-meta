# Bugs & known issues

## 1. Test 7e / typed-define: `read-from-string` hangs on `{ }` type annotations

**Status: FIXED.**

**Symptom:** `read-from-string "(define id {A --> A} X -> X)"` hung indefinitely. `read-from-string "(+ 1 2)"` worked fine. The `read-from-string-unprocessed` path (parse only) was instant.

**Root cause (stale `vm_error_jmp` in the trap-error handler path):**

The typed-define path runs `find-arities → store-arity → arity(id) → get → shen.<-dict → assoc`. Because `id` is not yet in the dict, `shen.<-dict` raises `simple-error "value id not found in dict"`. `arity` wraps this in `trap-error` whose handler returns `-1`.

The bug was in how that handler was executed. In `vm/zincvm.c`, the `trap-error` primitive's error path:

1. `te_pop()` restores the enclosing `vm_error_jmp` (sp 2→1).
2. Runs the handler via `vm_exec_env(...)`.
3. But `vm_error_pending` was left set by the `simple-error` (it is only cleared on the *first* entry to `trap-error`, at the top, not on the error path).
4. The handler's `vm_exec_env` therefore hit the rescue branch at the top of `vm_exec_env`:
   `if (vm_error_pending) { vm_error_pending = 0; setjmp(vm_error_jmp); }`
   — which **overwrites `vm_error_jmp`** with the handler's `setjmp` location, without `te_push()` (violating the documented invariant that every `setjmp(vm_error_jmp)` site pairs with `te_push`/`te_pop`).
5. When `vm_exec_env` returned, `vm_error_jmp` was left pointing into that returned (dangling) C frame.
6. The next error raised without an active `trap-error` (e.g. `simple-error "id has no attributes: arity"` during arity storage) `longjmp`'d to the dangling target, which looped forever (each `longjmp` returned to the stale `setjmp`, re-ran, and re-raised the same error).

**Fix (commit `3ed45b1` — final):** The whole error-handling design was refactored to
remove the root cause structurally. Instead of the global `vm_error_jmp` +
`error_jmp_stack` + `te_push()/te_pop()` + the rescue `setjmp(vm_error_jmp)` at the
top of `vm_exec_env`, the VM now uses a linked list of stack-allocated `CatchFrame`
structs. The rescue `setjmp` — which clobbered the global jmp_buf without pairing
with `te_push`, leaving a dangling target — is deleted; a `simple-error` raised in a
handler now propagates to the enclosing catch frame, and `vm_catch_chain` is
restored by plain frame unlink on every exit. An earlier intermediate fix (commit
`b2b1988`: clear `vm_error_pending` before running the handler) resolved the
immediate hang but was superseded by this refactor.

**Earlier (partial) fixes kept:** `overrides.kl` → `overrides-pure.kl` (removes `scm.*` dependencies), and switching the KLambda source to the standard Shen OS Kernel 41.2 distribution. These removed the broken `scm.*`-based `shen.<-dict`/`hash` that could not run in the C VM, but the hang persisted until the stale-jmp fix above.

**Regression test:** Added `read-from-string-typed-define` to the self-hosting suite: `(read-from-string "(define id { A --> A } X -> X)")` now returns `[[define id { A --> A } X -> X]]`. Note: it prints a benign `runtime: apply non-callable tag=5` warning during define macroexpansion (a NIL value is applied), which does not affect the result.

## 2. `=` cons-vs-symbol HACK — REMOVED

**Status:** Fixed.  
**Was:** `zinc-c` generated flat `(= [number 42] "number")` instead of `(= hd(hd(Code)) "number")`.  
**Resolution:** The zinc-c compiler now generates correct `hd`-wrapped comparisons.

## 3. `eval_kl` error swallowing

**File:** `vm/zincvm.c`  
**Symptom:** On error, `eval_kl` returns identity instead of re-raising.  
**Reason:** Shen's `load` doesn't wrap forms in `trap-error`.  
**Status:** Intentional but fragile. Now uses a `CatchFrame` (see AGENTS.md trap-error section).

## 4. `str` primitive — FIXED

**Status:** Fixed.  
**Fix:** `str_value()` handles all types with full `put-datum` representation.

## 5. Trap-error handler ping-pong — FIXED (da55d9b), then SUPERSEDED (3ed45b1)

**Symptom:** `get`'s handler's `simple-error` longjmp'd back to itself because `vm_error_jmp` wasn't restored.

**Root cause:** Single `vm_error_jmp` + manual save/restore couldn't handle nested trap-errors where the inner handler calls `simple-error`.

**Fix:** `error_jmp_stack[64]` + `te_push()`/`te_pop()`. `trap-error` pushes before `setjmp`. Handler pops FIRST so `simple-error` propagates outward. Also updated `eval-kl` and REPL code.

**Superseded:** The whole jmp_buf-stack design was replaced by the per-catch-site `CatchFrame` chain (commit `3ed45b1`); `te_push`/`te_pop` and `error_jmp_stack` no longer exist.

## 6. Error handling — remaining known limitations (post-CatchFrame refactor)

These are deliberate, preserved behaviors that the CatchFrame refactor (`3ed45b1`) did not change. Not regressions.

- **`eval-kl` swallows all pipeline errors** and returns the input unchanged (identity). `Shen`'s `load` path doesn't wrap forms in `trap-error`, so re-raising would expose pre-existing pipeline errors. This hides real user-code errors and compiler-pipeline bugs. A future fix would propagate a `VAL_ERROR` or rethrow via the catch chain and let callers wrap in `trap-error`.
- **C-level primitive type guards removed.** The guard-enabled debug build (`ZINCVM_DEBUG`, `PRIM_TYPE_ERROR`) was removed — the full OS bundle that needed it is gone. Primary ownership of catchable runtime errors is the Shen safe-wrapper layer (`shen/primitives.shen`): each `safe.X` validates its args and raises a catchable `simple-error` before the raw primitive is ever called. The release C VM has no primitive type guards (there is no debug build to enable them). Always-on (not safe-wrapper-protected, not type guards): `simple-error`, `fail`, `apply`/`appterm` non-callable + too-many-args, `env_pop`, `pos` out-of-bounds inside `trap-error` (semantic, needed for `strlen`/end-of-string), and eval-kl's catch.
- **The guard-free release VM only runs the REDUCED, type-safe bundle.** The canonical `make bundle` now produces `globals.csexp` = the **reduced self-contained interpreter** (meta-interpreter `.shen` + the type-safe `.kl` base `core/declarations/types/macros/load/toplevel/sys/dict/track/reader/writer`, excluding the heavy OS). It self-hosts guard-free (exit 0). The full Shen OS is **not** a second bundle (the full-OS bundle was removed): it is loaded from `.kl` at **runtime** by the C VM's `--repl` mode (`interp-load-raw` into the meta-interpreter, then `shen.initialise`/`shen.repl`). It is type-unsafe (`shen.initialise` does `+ - * /` on non-numbers), which is why it is interpreted rather than compiled into the guard-free release VM.
- **Close-the-loop (runtime `.kl` loading) is PARTIAL — defun registration does not yet work.** The bundled meta-interpreter reads and parses a `.kl` file at runtime via `(read-file-raw ...)` correctly (this required `pos` out-of-bounds to throw inside `trap-error` unconditionally — see above). But `(interp-load-raw "file.kl")` does NOT register the loaded `defun`: `interp-eval` swallows a compile error via `interp-eval-safe` and returns `loaded`, so the defun never appears in the global table. The failure is inside the bundled `kl->zinc` NON-primitive compile path (CPS continuation): compiling `[lambda V 42]` hits `apply non-callable tag=5` (nil) in `kl->zinc`'s bytecode (pc=36) before `toplevel-interp` runs. The eval-kl tests only exercise the primitive-headed path (which bypasses normalize/debruijn), so they pass. Two real fixes landed while debugging: bundling `idx`/`index_h` (they were val_prim placeholders — `util.shen` is loaded via `interp-load-raw`, which only compiles `defun` not `define`, so these compiler helpers were missing and `debruijn` couldn't resolve variable indices) — but another missing helper or a CPS-compile bug remains. Next step: find which global the non-primitive compile path applies as nil (the `(function id)` continuation) and bundle it, or fix the CPS compile.
- **Routing the eval-kl path through the safe wrappers (via the metacircular interp rules) was attempted and REVERTED.** Two mechanisms were tried: `((function X) ...)` compiled back to `[prim X]` (not `[global X]`) and introduced a nil-arg regression; `(apply X [args])` failed because `apply` is not a callable global in this context (`apply non-callable sym='apply'`). Both broke self-hosting. The interp rules are back to the original `(X ...)` form, so eval-kl'd dynamic code does NOT yet route through the safe wrappers — the design intent is documented in AGENTS.md but not implemented.
- **Safe wrappers now cover:** all the arithmetic (`+ - * /`, incl. division-by-zero), list (`hd`/`tl`/`fst`/`snd`/`cons`/`emptylist`), string (`n->string`/`string->n`/`tlstr`/`hdstr`/`str`), symbol (`intern`/`value`/`set`), vector (`absvector` incl. negative, `<-address`/`address->`), I/O (`open` incl. genuine open-failure, `close`, `read-byte`, `write-byte`), `get-time`, `pos`, `cn`, comparisons, `trap-error`, `simple-error`, `error-to-string`, and the type predicates. (`hdstr` and `read-file-as-string` required adding metacircular-interp `[prim ...]` rules so the eval-kl path can wrap them.)
- `val_error` messages are GC-allocated (no `strdup` leak). All error state is file-scope C statics (not thread-safe); the VM is single-threaded by design.

## 7. Self-hosting bootstrap: `.kl` defun registration now compiles correctly (4 fixes)

**Status: 4 root causes FIXED and committed. One blocker remains (OOM in `interp-load-raw`).**

`(interp-load-raw "file.kl")` now successfully parses a `.kl` defun, compiles it via the
self-hosted pipeline, and registers it in the meta-interpreter's global-table. Four
sequential compiler/closure-selection bugs were root-caused and fixed:

1. **`dedupe-globals` inverted (bcb3e80).** Kept the LAST (back = oldest = host `set-toplevel`)
   duplicate of a global name instead of the FIRST (front = newest = `shen-load`'d). The
   `shen-load` pipeline compiles every defun to flat/full-arity ZINC, but the curried
   host-compiled `set-toplevel` closures shadowed them, so the bundled `kl->zinc` crashed on
   any non-primitive body (`apply non-callable`). Rewrote `dedupe-globals` to keep the first
   occurrence via a `Bound`-style seen-set.
2. **`shen-kl-expr` miscompiled higher-order calls (d8125bb).** The data-fallback branch
   fired on `(UppercaseVar x)` heads, miscompiling `(K Aexp)` into the literal data `[K Aexp]`
   (a cons chain with no `apply`), silently breaking every CPS continuation in `normalize.shen`.
   Collapsed `shen-kl-expr` to always emit an application (bracket lists are already consified
   at read time).
3. **`compile-pattern` didn't linearize non-linear patterns (4c8e94b).** Repeat variable
   occurrences (e.g. `X` in `index_h`'s `X [X | Rest] C`) were compiled as fresh bindings
   instead of equality tests, so `idx` returned 0 for every variable and `debruijn` assigned
   `[lookup 0]` to all of them. Threaded a `Bound` assoc-list through the pattern compiler so
   repeat vars emit `[= Slot <prior>]`.
4. **`zinc-t` compiled `if`-branches non-tail (be5c882).** The metacircular `interp`'s body is a
   giant `cond`→`if` tree; `zinc-t`'s `[if X Y Z]` compiled branches with `zinc-c` (`apply`,
   non-tail) instead of `zinc-t` (`appterm`), killing TCO. Every interpreter step pinned its
   `E`/`S`/`R` cons-list snapshots, growing the heap. Fixed the branches to use `zinc-t`.
   Bundled `interp` now has 94 `appterm` / 37 `apply` (was 1 / 130).

**Verified correct (C-VM probe `ZINC_TEST_OS_LOAD`):** `idx X [X Y] → 0`, `idx Y [X Y] → 1`;
`normalize-term([+ X Y]) → [%% + X Y]`; `debruijn` → `[lookup 1] [lookup 0]`;
`zinc-c` → 2 grabs with distinct access; `toplevel-interp` → `[lambda [grab access 0 access 1
prim + return] []]`. `interp-eval-all` on the parsed `.kl` forms returns `loaded` and registers
the closure (`lookup-global my-add` finds it). `make test` 34/34.

**Bug 5 (RESOLVED e632649): `interp-load-raw` OOM — dead from-space pages never freed.** The
symptom: `interp-load-raw` exhausted the 4 GB GC heap reservation (`grow_heap: need 8192 MB but
reservation is 4096 MB`); `allocatedpages` (logged as `live_pages`) doubled at every FULL collect
(~137K → 268K → 530K → 1054K → 2098K). Reproduced even in the normal self-hosting run
(`./zinctest globals.csexp --gc-verbose`), so it was a general runtime issue, not OS-load-specific.

**Root cause:** `collect()` swapped semi-spaces and reset `allocatedpages=0` (gc.c:612) but NEVER
reset the dead from-space pages' `space[]` tags back to 0. Dead pages kept their tag forever.
During the next Phase 1 scavenge, `allocatepage`'s free-page test (gc.c:1542-1544) refuses any page
tagged `current_space` or `next_space`, so only never-allocated `space=0` pages are usable. When
`space=0` ran low, the scan-exhausted path (gc.c:1586) called `grow_heap`, which DOUBLES
`heappages` (gc.c:1457). Doubling `heappages` doubled `oldgen_collect_threshold() = heappages/4`
(gc.c:1498), so more garbage fit between collects → `live_pages` doubled at the next collect →
another `grow_heap` → geometric growth to OOM.

Diagnostics confirmed it was bookkeeping, NOT a stale pointer: `--gc-stale-scan` and
`--gc-dump-roots` both showed ZERO hits. Page-space distribution at the end of a FULL collect
showed only ~2000 `space=0` pages while half a million were dead-tagged `space=1` and half a
million dead-tagged `space=2`; the real reachable set was only ~6138 pages (~3 MB).

**Fix (e632649, 5 lines in `collect()`):** immediately before `current_space = next_space;`, loop
all pages and reset any page tagged `current_space` (the now-dead from-space) back to `space=0`
and clear `type_page`. After the fix `live_pages` stays stable at ~135K across all FULL collects,
no `grow_heap` fires, `interp-load-raw` of the probe `.kl` completes and `(my-add 2 3)` evaluates.
`make test` 34/34. Diagnostic probes live in `vm/zinctest.c` under
`#ifdef ZINC_TEST_OS_LOAD` (build with `-DZINCTEST -DZINC_TEST_OS_LOAD`).

## 8. OS-load: `stlib.kl` compiler O(n²) `append` — FIXED (tail-threaded zinc-c/zinc-t); now a kmacros `cond` blocker

**Status: perf blocker FIXED (tail-threaded `zinc-c`/`zinc-t`). Remaining: `stlib.kl` FAILS fast with `No condition was true`.**

**Symptom (pre-fix):** Ordered OS load reached `stlib.kl` (file 20) and aborted at the instruction
hard limit: `[HARD LIMIT] 5000000000 instructions, aborting at pc=16 frames=37`, after ~50 min of
burning instructions compiling the 231 KB `initialise-sources` defun. Files 0-19 loaded cleanly.

**Root cause (advisor-confirmed):** `stlib.initialise-sources` is a 339-deep left-nested
`(do X (do Y ...))` chain. `kmacros` rewrites each `(do X Y)` into `(let (newvar) X Y)`, so
post-normalization it is a 339-deep left-nested let-chain. `zinc-c`'s `[let X Y]` rule used nested
`append` — each nesting level copies the entire accumulator, so compiling the chain was O(n²):
~39M cons allocations ≈ ~400M metacircular instructions ≈ 3-4B C VM instructions. NOTE: Tier-3
`fold-append` in `util.shen` was NOT the primary culprit (only used for multi-arg calls); the
quadratic lived in the `[let X Y]` / `[if X Y Z]` append chains.

**Fix (uncommitted at this writing):** Rewrote `shen/zinc.shen` to tail-thread `zinc-c`/`zinc-t`
with a `Tail` accumulator (`zinc-c-tail`, `zinc-t-tail`) plus a `zinc-c-args` helper that compiles
arg lists left-to-right into Tail. Zero `append` calls remain in the compiler; the let-chain now
compiles in O(n). Registered `zinc-c-args`/`zinc-c-tail`/`zinc-t-tail` via `set-toplevel` in
`shen/interp.shen`. Implementation gotcha: `zinc-c-tail` `[lambda X]` must be
`[cur | [(zinc-t-tail X [return]) | Tail]]` — NOT `[[cur (...)] | Tail]` (double-wrap breaks the
`c(...)` closure-body unwrap in `parse_bundle`).

**Verification:** Only `zinc-c` and `zinc-t` closures differ from the baseline bundle; all other
427 bundled closures are byte-identical (semantics preserved on the reduced bundle). `make test`
34/34, `make run-bundle` (self-hosting + GC stress) pass. The OS-load
probe now gets past the hard limit quickly.

**Bonus correctness fix (same session):** `kmacros`' `[open X out]` rule
(`normalize.shen:44`) was a copy-paste typo — it compiled `(open X out)` into
`[%% open X in]`. Fixed to `[%% open X out]`. Verified: `(kmacros [open "f" out])`
now yields `[%% open f out]`, `(kmacros [open "f" in])` stays `[%% open f in]`.
The metacircular interp's `[prim open]` rule already handled `out` correctly
(`interp.shen:199`), so only the compile-side rule was wrong. The advisor also
flagged a `debruijn [let X Y Z]` value-drop bug — **investigated and NOT a bug**:
`[let X Y Z]` = var X / value Y / body Z, and the rule correctly debruijns the
value Y into the value slot and the body Z under `[X | Scope]`, dropping only the
var name (represented as `[lookup N]` in the body).

**Current blocker (OPEN):** The OS-load probe now FAILS fast on `stlib.kl` with
`tag=9 msg=[error "No condition was true"]` (not a hard-limit hang). "No condition was true" is
`kmacros`' empty-cond fallback (`normalize.shen:19` `[cond] -> [simple-error ...]`), so a `cond`
form in `stlib.kl` exhausted all `[cond [X Y] | Rest]` branches during kmacro expansion — i.e. the
safe-subset kmacros can't expand some `cond` shape that `stlib.kl` uses, or a `cond` branch's
pattern does not match the rule and falls through to the empty case. Next step: identify the exact
`cond`/source construct in `stlib.kl` that reaches the empty-cond fallback and extend kmacros.

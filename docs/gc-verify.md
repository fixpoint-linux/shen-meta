# GC-Safety Verifier (Soufflé Datalog)

Status: **DESIGN + Phases 0-3 DONE** (committed 876e7f6, 365c50f, + Phase 2, + Phase 3). Phase 4 (make gc-verify integration) + Phase 5 (calibration) pending. Not part of any build gate.

## Phase 3 status (memcpy_unbarriered)

Implemented and validated end-to-end (clang 22.1.8 + souffle 2.5). The
previously-vacuous `memcpy_unbarriered` skeleton is now three strata:
`reach_stmt` (positive TC over `next_stmt`) → `barrier_covers_alloc`
(positive) → `memcpy_unbarriered` (negates it). The extractor emits real
`stmt_memcpy`/`stmt_barrier` rows (intercepting `memcpy` and
`gc_dirty_vectors_add` calls before the generic call_graph path), filtering
memcpys whose dst is NOT a GC-managed local at extraction time. `nbytes` is
now a symbol (was `number` — the self-test skeleton wrote
`"env_len * sizeof(Value)"`, which would break Soufflé number parsing).

- **Regression fixtures pass** (now 6 total via `check_fixtures.sh`):
  `memcpy_unbarriered.c` fires (1), `memcpy_barriered.c` clean (0),
  `memcpy_charbuf.c` clean (0). The three Phase-2 root_miss fixtures still
  pass. All 52 Python unit tests pass (10 phase0 + 13 phase1 + 14 phase2 +
  15 phase3).
- **Real VM is clean where it should be:** all 17 historical barrier sites
  (commit 6a660f1) are NOT flagged. `out/memcpy_unbarriered.csv` on current
  `vm/zincvm.c` contains exactly 2 candidates, both **confirmed false
  positives** (correct code):
  1. `main:56 env_init` — freshly-allocated young-gen array (no old-gen
     write barrier needed). The deferred "fresh target" pruning (Phase 5)
     will suppress this.
  2. `parse_body:50 code` — `GC_TYPE_INSTR_ARRAY` (an Instr array, not a
     Value array); it does not need the Value write barrier. Fix: the
     extractor's `_is_gc_managed_type` should not treat `Instr*`/`Instr**`
     as barrier-relevant (it is GC-managed for root-miss liveness but not
     for write barriers). Calibration item.

These are exactly the over-flag categories the design predicted; both become
Phase 5 `definite_assigned`/type-table calibration entries.

## Phase 2 status (make-or-break)

Implemented and validated end-to-end (clang 22.1.8 + souffle 2.5):
- **Regression fixtures pass** (`check_fixtures.sh`, wired into `make gc-verify`):
  `val_lambda_env.c` fires (2), `trap_error_hc.c` fires (2), `rooted_ok.c`
  clean (0). This is the core value: historical bugs become permanent
  regression tests.
- **False-positive fix:** VarDecl-with-initializer now emits `gc_def` (kills
  backward liveness at the definition point). Without it, a var used after
  its definition appears spuriously live across an earlier alloc.
- **Souffle header fix:** all `.input`/`.output` use `headers=true`. Without
  it, souffle treats the header row as data (silently broken for symbol-only
  relations, hard error for `number` columns like `stmt_id`).

**Remaining over-flagging on current VM (~52 root_miss candidates):** the
intra-BB linear `next_stmt` approximation treats each function as one basic
block, so vars live in *other* switch cases appear live across an alloc. Most
candidates are safe-by-design (e.g. `val_lambda`'s local `Value v` is
unrooted intentionally; the code/env it stores are separately rooted via
`gc_root_push_ptr`). This is the `definite_assigned` / basic-block calibration
refinement — Phase 5. The tool is behaving correctly as a **candidate
generator**: it surfaces sites for review, and the calibration pass decides
which are genuine. See Phase 5 below.

## Goal

A static-analysis verifier that mechanically catches the **precise-root-miss** and
**missing-write-barrier** classes of GC-safety bugs in the hand-written C VM
(`vm/zincvm.c`, `vm/gc.c`, `vm/zinctypes.h`), so bugs that were fixed by manual
archaeology become a permanent regression suite.

**This is a verifier + candidate generator, NOT an oracle.** A clean run does not
prove the GC is correct; a flagged site is a review prompt, not a build break.

## Architecture

```
vm/*.c ──clang -Xclang -ast-dump=json──▶ extract.py ──CSV──▶ gc_safety.dl ──▶ root_miss
                                                                    └───────▶ memcpy_unbarriered
```

- **Extractor:** `clang -Xclang -ast-dump=json` consumed by a Python visitor.
  Picked over libclang bindings (version-pinned), tree-sitter-c (no type info),
  Clang LibTooling plugin (5-10x cost, hard clang build dep on a cosmocc project),
  and pure regex (can't build a CFG).
- **Analysis:** Soufflé Datalog (`/usr/local/bin/souffle`, already used by the
  graph-gardener), consuming CSV via `.decl ... .input`.
- **Location:** new `tools/gc-verify/` directory — keeps the clang/soufflé dep
  tree out of the main cosmocc build.
- **Build integration:** opt-in `make gc-verify` target. NOT added to
  `make`/`make test`/`make test-debug`/`make run-bundle`. Mirrors the existing
  `--gc-*` debug-flag opt-in convention.

## Fact schema (CSV → Soufflé)

```
function.csv       (name)
cfg_edge.csv       (f, from_stmt_id, to_stmt_id, kind)   # fall|true_br|false_br|case|back
stmt_allocs.csv    (f, stmt_id, callee)                  # call into may-collect set
stmt_pushes.csv    (f, stmt_id, root_kind, slot_expr)    # ROOT_PTR/VALUE/VALUE_ARRAY/VOLATILE/CALLFRAME
stmt_pops.csv      (f, stmt_id, count, pkind)            # pop_one|pop_to
stmt_memcpy.csv    (f, stmt_id, dst_expr, src_expr, nbytes:symbol)
stmt_barrier.csv   (f, stmt_id, target_expr)             # arg of gc_dirty_vectors_add
var_decl.csv       (f, name, type, is_gc_managed)
field_assign.csv   (f, stmt_id, base, field_path, rhs_kind)  # e.g. v.lambda.code = code;
call_graph.csv     (caller, callee)
```

**GC-managed type table** (hand-curated in extractor): `Value`, `Value*`,
`Instr*`, `Instr**`, `CallFrame*`, `ValueArray*`, field paths `.cons.car`,
`.cons.cdr`, `.lambda.code`, `.lambda.env`, `.vector.data`, `.stack.data`,
`.env`. Plus `void*` locals initialized from `returns_gc_pointer = {gc_alloc,
gc_alloc_oldgen, gc_alloc_atomic}`.

## Datalog rules (dependency-ordered strata)

1. **`may_collect`** — transitive closure of functions reaching `gc_alloc`,
   `gc_alloc_oldgen`, `gc_alloc_atomic`, `collect`, `collect_nursery`, `gcalloc_internal`.
2. **Backward GC-liveness** over the CFG (GC-managed vars only).
3. **`pushed_may` / `must_rooted`** — a value is rooted at an alloc site if pushed
   on the shadow stack on all paths. `gc_root_pop_to(wm)` is modeled as "kill all
   live pushes in this function" (handles longjmp unwind).
4. **`root_miss`** — violation: *GC-managed var live across an allocating call ∧
   not must_rooted*.
5. **`memcpy_unbarriered`** — raw memcpy into a fresh `GC_TYPE_VALUE_ARRAY`
   target with no `gc_barrier_value_array` before the next may-collect.

**Optimization:** ~80% of historical sites are straight-line within one switch
case, so the liveness ruleset can ship intra-BB-only first (much simpler), then
extend to inter-BB only for `trap-error`/`eval-kl` multi-branch sites.

## Soundness limits (document in README)

| Class | Catchable? | Why |
|---|---|---|
| Named locals + struct fields (root-miss) | ✅ | `val_lambda`, `trap-error hc`, `parse_body cc-slots`, `OP_APPLY` argbuf, marshal/demarshal named locals, `env_push` v, eval-kl chain, `va_push` |
| Missing write barriers | ✅ | all 17 memcpy sites fixed in the gc-write-barrier-pass commit |
| Register-cached unnamed temps (`-O1+`) | ❌ | `*(...).cons.car` has no source-level name; needs post-optimization LLVM IR (Phase 6 future work) |
| Collector invariant bugs (Bug 2 `freep`/`cp` drain skip) | ❌ | a bug in the GC, not mutator discipline; runtime tools (`--gc-verify-codechains`) only |
| Data flows through non-GC types (`char*` etc.) | ❌ | hand-curated type table is the contract |
| `void*` returns from `gc_alloc*` | ⚠️ | mitigated via `returns_gc_pointer` set |

## Validation strategy (core value)

`tools/gc-verify/fixtures/` holds the **BEFORE versions** of every historically
fixed bug. The tool must **fire on the buggy fixtures** and **be clean on current
`vm/zincvm.c`**. Fixtures:
- `val_lambda_env.c`, `trap_error_hc.c`, `parse_body_cc_slots.c`, `eval_kl_chain.c`,
  `va_push_memcpy.c`, marshal/demarshal named-locals, and one per fixed barrier site.

`tools/gc-verify/expected/` holds the curated clean-baseline allowlist.
`check_results.sh` diffs `out/*.csv` against `expected/`.

## Phased rollout & effort

| Phase | Scope | Effort | Gate |
|---|---|---|---|
| 0 | Scaffold: `tools/gc-verify/` skeleton, `extract.py` walks one fn (`val_lambda`), Soufflé loads empty `.dl` | 0.5 d | CSVs round-trip |
| 1 | Full AST walk of `vm/zincvm.c` + `vm/gc.c`; emit all CSVs; hand-verify call graph; compute `may_collect` | 1-2 d | spot-check 5 fns |
| 2 | **Make-or-break.** GC-liveness + `must_rooted` + `root_miss`. Fire on fixtures, clean on current code | 2-3 d | all 9 blockers reproduced, no false positives on real code |
| 3 | `memcpy_unbarriered` rule | 1 d | 3 barrier fixtures ✓ |
| 4 | `make gc-verify` + `check_results.sh` + AGENTS.md note | 0.5 d | end-to-end clean |
| 5 | CI non-gating; calibrate false positives into `definite_assigned` | ongoing | — |

**Total v1: ~5-7 days.** Biggest risks: `must_rooted` Soufflé stratification
(compute `unrooted_path` = may in a lower stratum, take complement); over-flagging
on first run (expect 10-30 candidates needing calibration); clang AST drift
(pin README to clang ≥ 14).

## Environment findings (2026-08-10)

- `/usr/local/bin/souffle` present on host (18.5MB), but **not sandbox-allowlisted**
  (sandbox `shell_list` rejects it).
- **No clang installed** on this host — only the musl gcc cross-toolchain
  (`x86_64-buildroot-linux-musl-gcc.br_real`). Full v1 requires `apt install clang`
  (analysis-time only; cosmocc release build untouched).

## Repo conventions

- Soufflé already used (graph-gardener). A `.dl` in this repo is consistent.
- Opt-in pattern mirrors every `--gc-*` debug flag — none are in `make gate`.
- Separate `tools/gc-verify/` dir, not `vm/`, keeps clang/soufflé deps out of the
  cosmocc build.
- AGENTS.md: one paragraph under "C VM conventions" → "GC" pointing at
  `tools/gc-verify/README.md` for the verifier + its soundness scope.

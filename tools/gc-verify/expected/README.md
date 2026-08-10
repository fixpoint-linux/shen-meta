# expected/ — curated clean-baseline allowlist

These CSV files are the **vetted truth** for the GC-safety verifier's
real-VM run.  `check_results.sh` diffs `out/*.csv` against these, and:

- **FAIL**s on any row that appears in the output but NOT here (a new
  candidate — regression or new code pattern that needs review).
- **WARN**s on any row that is present here but NO LONGER fires (usually
  a fix — re-run `make snapshot` to refresh the allowlist).
- **OK** if the output matches exactly (same rows after header-strip +
  sort).

All rows in this directory have been manually reviewed and confirmed as
either safe-by-design (false positives that the tool correctly surfaces
as review prompts) or genuine historical bugs that are now documented as
permanent regression fixtures.  Do not edit these files by hand —
regenerate with:

```sh
make snapshot    # re-runs the real-VM pipeline and copies out/*.csv → expected/
git diff expected/   # review every change before committing
```

## Current allowlist (Phase 4 snapshot)

### root_miss.csv (~52 rows)

Phase-2 categories of safe-by-design root_miss candidates on the current
`vm/zincvm.c`:
- `val_lambda`'s local `Value v` — unrooted intentionally; the code/env
  fields are separately rooted via `gc_root_push_ptr`.
- Switch-case intra-BB over-approximation: vars live in *other* cases
  spuriously appear live across an alloc in the current case (the linear
  `next_stmt` intra-BB approximation; Phase 5 `definite_assigned`
  calibration will refine these).
- Known false positives from the extractor: `void*` locals typed
  conservatively as GC-managed via `returns_gc_pointer`, struct fields
  accessed across allocation boundaries where the enclosing struct is
  already rooted.
- All ~52 rows have been hand-reviewed and are safe-by-design.

### memcpy_unbarriered.csv (2 rows)

Phase-3 candidates, both confirmed false positives:
1. `main:56 env_init` — freshly-allocated young-gen array (no old-gen
   write barrier needed). Phase-5 "fresh target" pruning will suppress.
2. `parse_body:50 code` — `GC_TYPE_INSTR_ARRAY` (Instr array, not Value
   array); does not need the Value write barrier. Phase-5 type-table
   calibration item.

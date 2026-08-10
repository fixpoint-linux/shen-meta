# expected/ — curated clean-baseline for the safe-subset verifier

These CSV files are the **vetted truth** for the bundle safe-subset
verifier's real-bundle run.  `check_results.sh` diffs `out/*.csv`
against these, and:

- **FAIL**s on any row that appears in the output but NOT here (a new
  violation — regression or new code pattern that needs review).
- **WARN**s on any row that is present here but NO LONGER fires (usually
  a fix — re-run `make snapshot` to refresh the baseline).
- **OK** if the output matches exactly (same rows after header-strip +
  sort).

All rows in this directory should be manually reviewed and confirmed as
either safe-by-design or genuine issues.  Do not edit these files by
hand — regenerate with:

```sh
make snapshot    # re-runs the real-bundle pipeline and copies out/*.csv → expected/
git diff expected/   # review every change before committing
```

## What a clean run proves

When ALL six output relations are EMPTY, the bundle is **proven** to be
in the safe subset:

| Relation | Proves |
|---|---|
| `bad_opcode` empty | No unknown opcodes — every bytecode char is in the 17-opcode ZINC set |
| `dangling_global` empty | Every `[global X]` resolves to a bundle closure, allowlisted primitive, or instruction keyword — no runtime "apply non-callable" from unresolvable globals |
| `unknown_prim` empty | Every `[prim X]` is in the `primitive?` allowlist — mechanically enforces the util.shen↔types.shen primitive-list sync |
| `curried_call` empty | No adjacent apply/appterm opcodes — no curried partial-application calls that would crash the C VM |
| `arity_mismatch` empty | Every statically-resolvable call site supplies the right number of arguments — no full-arity violations |
| `unresolved_call` empty | No call sites where the callee is a higher-order parameter (`[access N]`) — the bundle never calls through env slots |

**It does NOT prove:** C VM correctness (gc-verify's job); `shen→kl`
semantic correctness (a compiler bug could emit structurally-valid but
wrong bytecode); GC/memory safety; type safety (orthogonal, Check B).

## Initial baseline

The initial baseline (before the first `make snapshot`) is empty —
a clean gate means zero violations.  After `make snapshot`, the
orchestrator reviews any flagged rows and vets them manually.  Any
vetted rows become the permanent expected baseline.

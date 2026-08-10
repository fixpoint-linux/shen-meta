# GC-Safety Verifier

A static-analysis verifier that mechanically catches the **precise-root-miss**
and **missing-write-barrier** classes of GC-safety bugs in the hand-written C VM
(`vm/zincvm.c`, `vm/gc.c`, `vm/zinctypes.h`).

**This is a verifier + candidate generator, NOT an oracle.** A clean run does
not prove the GC is correct; a flagged site is a review prompt, not a build
break.

## Architecture

```
vm/*.c ──clang -Xclang -ast-dump=json──▶ extract.py ──CSV──▶ gc_safety.dl ──▶ root_miss
                                                                   └────────▶ memcpy_unbarriered
```

- **Extractor:** `clang -Xclang -ast-dump=json` consumed by a Python visitor.
- **Analysis:** Soufflé Datalog consuming CSV fact files.
- **Location:** `tools/gc-verify/` — keeps the clang/soufflé dep tree out of
  the main cosmocc build.

## Requirements

- **clang ≥ 14** (for `-Xclang -ast-dump=json` — the JSON AST format is stable
  from Clang 14 onward)
- **Soufflé** Datalog engine (`souffle` on `$PATH`)
- Python 3 (stdlib only — no pip deps)

## Quick start

```sh
# Full run (requires clang + souffle):
make run

# Self-test (Python only, no external deps):
make selftest

# Clean up generated facts + output:
make clean
```

## Soundness limits

| Class | Catchable? | Why |
|---|---|---|
| Named locals + struct fields (root-miss) | ✅ | `val_lambda`, `trap-error hc`, `parse_body cc-slots`, `OP_APPLY` argbuf, marshal/demarshal named locals, `env_push` v, eval-kl chain, `va_push` |
| Missing write barriers | ✅ | all 17 memcpy sites fixed in the gc-write-barrier-pass commit |
| Register-cached unnamed temps (`-O1+`) | ❌ | `*(...).cons.car` has no source-level name; needs post-optimization LLVM IR (Phase 6 future work) |
| Collector invariant bugs | ❌ | a bug in the GC, not mutator discipline; runtime tools (`--gc-verify-codechains`) only |
| Data flows through non-GC types (`char*` etc.) | ❌ | hand-curated type table is the contract |
| `void*` returns from `gc_alloc*` | ⚠️ | mitigated via `returns_gc_pointer` set |

## Environment

clang and souffle are required on the host. These are **analysis-time only**
dependencies; the cosmocc release build is untouched.

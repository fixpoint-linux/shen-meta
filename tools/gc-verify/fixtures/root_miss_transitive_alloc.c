// REGRESSION-FIXTURE: interprocedural root_miss — POSITIVE control
//
// Rule 3 (transitive_alloc_site): a GC-managed local `Value *code` is live
// across a call to `call_closure1`, which is NOT itself a may_collect seed
// but TRANSITIVELY calls gc_alloc.  stmt_allocs alone would not see this
// call as allocating; transitive_alloc_site (via call_site + may_collect TC)
// does.  `code` is NOT rooted → root_miss MUST fire.
//
// Expected verifier output: root_miss fires for the call_closure1 call site.

#include <stddef.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER, VAL_CONS,
} ValTag;

typedef struct Value {
    ValTag tag;
    union {
        long number;
        struct { struct Value *car; struct Value *cdr; } cons;
    };
} Value;

// ── Modeled GC API ──────────────────────────────────────────────────

extern void *gc_alloc(size_t bytes, int type_tag);

#define GC_TYPE_VALUE  1

// ── Indirect allocator: not a seed, but transitively allocates ──────
// call_closure1 → gc_alloc, so may_collect(call_closure1) via TC.

Value *call_closure1(Value *arg) {
    // May-collect allocation makes call_closure1 a may_collect function.
    Value *scratch = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    scratch->tag = arg->tag;
    return scratch;
}

// ── BUGGY caller — code live across the indirect alloc, NOT rooted ──

Value *transitive_bug(int n) {
    // GC-managed local, live across the call_closure1 call (used after).
    Value *code = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    code->tag = VAL_NUMBER;
    code->number = n;

    // NOT rooted before this call → root_miss should fire.
    Value *result = call_closure1(code);

    // code used after the allocating call.
    code->number += 1;
    (void)result;
    return code;
}

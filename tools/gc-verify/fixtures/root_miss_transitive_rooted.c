// REGRESSION-FIXTURE: interprocedural root_miss — NEGATIVE control
//
// Rule 3 (transitive_alloc_site): same transitive-alloc pattern as
// root_miss_transitive_alloc.c, but the GC-managed local `Value *code` IS
// pushed (gc_root_push_value) before the call_closure1 call.  So code is
// must_rooted → root_miss MUST NOT fire.
//
// Expected verifier output: root_miss does NOT fire.

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
extern void gc_root_push_value(void *vslot);
extern void gc_root_pop(void);

#define GC_TYPE_VALUE  1

// ── Indirect allocator: not a seed, but transitively allocates ──────

Value *call_closure2(Value *arg) {
    // Root arg across the alloc so this helper is itself clean (it is a
    // negative control — we only test that the CALLER's code is rooted).
    gc_root_push_value(&arg);
    Value *scratch = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    scratch->tag = arg->tag;
    gc_root_pop();
    return scratch;
}

// ── CORRECT caller — code is rooted before the transitive alloc ─────

Value *transitive_ok(int n) {
    Value *code = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    code->tag = VAL_NUMBER;
    code->number = n;

    // Root code before the allocating (indirect) call.
    gc_root_push_value(&code);

    Value *result = call_closure2(code);

    gc_root_pop();

    code->number += 1;
    (void)result;
    return code;
}

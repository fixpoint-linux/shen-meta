// REGRESSION-FIXTURE: rooted_ok — negative control (correctly rooted)
//
// A GC-managed variable that IS correctly pushed on the shadow stack
// (gc_root_push_value) before an allocating call that may trigger GC,
// and then used after the call.  The verifier MUST NOT flag this as a
// root_miss — the variable is properly rooted, so the GC will update
// it if the object is evacuated.
//
// This fixture guards against false positives: if the verifier flags
// this function, the must_rooted analysis is broken.

#include <stddef.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER,
    VAL_CONS,
} ValTag;

typedef struct Value {
    ValTag tag;
    union {
        long number;
        struct {
            struct Value *car;
            struct Value *cdr;
        } cons;
    };
} Value;

// ── Modeled GC API ──────────────────────────────────────────────────

extern void *gc_alloc(size_t bytes, int type_tag);
extern void gc_root_push_value(void *vslot);
extern void gc_root_pop(void);

#define GC_TYPE_VALUE  1

// ── Correctly rooted pattern ────────────────────────────────────────
//
// 1. gc_root_push_value(&val) — puts val on the shadow stack
// 2. gc_alloc(...) — may collect, but val is rooted
// 3. use(val) — val is still valid because the GC updated it
//
// The verifier MUST NOT emit root_miss for this function.

Value use_rooted_value(Value val) {
    // Push val on the shadow stack before the allocating call.
    gc_root_push_value(&val);

    // This allocation may trigger a nursery collection.
    // val is rooted → the GC will update &val if the object is evacuated.
    Value *p = (Value *)gc_alloc(10 * sizeof(Value), GC_TYPE_VALUE);

    // Use val after the allocation — safe because it was rooted.
    Value result = val;
    result.tag = VAL_NUMBER;

    // Cleanup.
    gc_root_pop();

    (void)p;
    return result;
}

// REGRESSION-FIXTURE: push_pop_balance — push without pop — POSITIVE
//
// Rule 1 (push_pop_balance): a gc_root_push_* that is never matched by a
// gc_root_pop_* on the path leaks/corrupts the shadow stack.  Here a push
// is issued and then a may-collect alloc follows, but no pop (the alloc is
// the final statement) → the verifier MUST flag "push_never_popped".
//
// Expected verifier output: push_pop_balance fires (push_never_popped).

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

#define GC_TYPE_VALUE  1

// ── BUGGY: push issued but never popped ─────────────────────────────

Value *unmatched_push(Value *arg) {
    gc_root_push_value(&arg);          // push

    // A may-collect alloc follows the push but nothing pops arg.
    // (The alloc is the final statement, so func_exit has depth 1.)
    Value *p = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    (void)arg;

    // No gc_root_pop() — shadow stack leaks → push_never_popped.
    return p;
}

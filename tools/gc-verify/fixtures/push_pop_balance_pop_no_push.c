// REGRESSION-FIXTURE: push_pop_balance — pop without push — POSITIVE
//
// Rule 1 (push_pop_balance): a gc_root_pop_* with nothing on the shadow
// stack corrupts the stack.  Here a pop is issued with no prior push →
// the verifier MUST flag "pop_without_push".
//
// Expected verifier output: push_pop_balance fires (pop_without_push).

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

extern void gc_root_pop(void);

#define GC_TYPE_VALUE  1

// ── BUGGY: pop with nothing pushed ──────────────────────────────────

void pop_no_push(void) {
    // No gc_root_push_* before this — pops an empty stack.
    gc_root_pop();
}

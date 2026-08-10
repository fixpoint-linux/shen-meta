// REGRESSION-FIXTURE: push_pop_balance — balanced — NEGATIVE
//
// Rule 1 (push_pop_balance): a gc_root_push_* properly matched by a
// gc_root_pop_* on the path keeps the shadow stack balanced.  Here a push
// and its matching pop straddle a may-collect alloc → the verifier MUST
// NOT flag either a "push_never_popped" or "pop_without_push".
//
// The pop is followed by a neutral allocating statement so the function
// exit has shadow-stack depth 0 (the pop's decrement lands on that stmt).
//
// Expected verifier output: push_pop_balance does NOT fire.

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

// ── CORRECT: push + alloc + matching pop ────────────────────────────

Value *balanced(Value *arg) {
    gc_root_push_value(&arg);          // push

    Value *p = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    p->tag = arg->tag;

    gc_root_pop();                     // matching pop

    // Neutral allocating statement so the exit sees shadow depth 0.
    Value *q = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    (void)q;

    return p;
}

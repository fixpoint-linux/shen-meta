// REGRESSION-FIXTURE: single-Value array store WITH write barrier
//
// Rule 4 (single_store_unbarriered): same pattern as
// single_store_unbarriered.c but correctly issues gc_dirty_vectors_add(env)
// after the store and before the next may-collect allocation → the verifier
// MUST NOT flag the store.
//
// Expected verifier output: single_store_unbarriered does NOT fire.

#include <stddef.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER, VAL_STRING, VAL_SYMBOL, VAL_BOOLEAN, VAL_CONS,
    VAL_NIL, VAL_LAMBDA, VAL_MARK, VAL_PRIM, VAL_ERROR, VAL_VECTOR,
} ValTag;

typedef struct Value {
    ValTag tag;
    union {
        long number;
        int boolean;
        struct { struct Value *car; struct Value *cdr; } cons;
        struct { struct Value *data; int len; } vector;
        const char *prim_name;
    };
} Value;

// ── Modeled GC API ──────────────────────────────────────────────────

extern void *gc_alloc(size_t bytes, int type_tag);
extern void gc_dirty_vectors_add(Value *v);

#define GC_TYPE_VALUE        1
#define GC_TYPE_VALUE_ARRAY  2

// ── CORRECT env_push — barrier between store and next alloc ─────────

Value *correct_env_push(Value *env, Value *arg, int env_len) {
    // Single-Value store into the GC-managed array.
    env[env_len] = *arg;

    // CORRECT: barrier before the next may-collect allocation.
    gc_dirty_vectors_add(env);

    Value *scratch = (Value *)gc_alloc(8 * sizeof(Value), GC_TYPE_VALUE);
    (void)scratch;

    return env;
}

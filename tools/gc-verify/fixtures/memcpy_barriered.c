// REGRESSION-FIXTURE: memcpy into GC-allocated array WITH write barrier
//
// Same as memcpy_unbarriered.c but correctly issues gc_dirty_vectors_add
// after the memcpy and before the next may-collect allocation.
//
// Expected verifier output: memcpy_unbarriered does NOT fire (clean).

#include <stddef.h>
#include <string.h>

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
extern int gc_in_oldgen(void *ptr);
extern int value_references_nursery(Value *v);

#define GC_TYPE_VALUE        1
#define GC_TYPE_VALUE_ARRAY  2

// ── CORRECT env_build — barrier between memcpy and scratch alloc ───

Value *correct_env_build(Value *src_env, int env_len, int nargs) {
    Value *new_env = gc_alloc((env_len + nargs) * sizeof(Value),
                              GC_TYPE_VALUE_ARRAY);
    if (env_len > 0)
        memcpy(new_env, src_env, env_len * sizeof(Value));

    // CORRECT: barrier before the next may-collect allocation.
    if (gc_in_oldgen(new_env) && value_references_nursery(src_env))
        gc_dirty_vectors_add(new_env);

    Value *scratch = gc_alloc(8 * sizeof(Value), GC_TYPE_VALUE);
    scratch[0] = *new_env;

    return new_env;
}

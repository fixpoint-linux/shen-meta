// REGRESSION-FIXTURE: single-Value array store with NO write barrier
//
// Rule 4 (single_store_unbarriered): a single-Value store into a
// GC-managed array (env[env_len] = arg) needs a write barrier, mirroring
// memcpy_unbarriered.  Here the store is followed by a may-collect
// allocation with no gc_dirty_vectors_add in between → the verifier MUST
// flag the store as unbarriered.
//
// Expected verifier output: single_store_unbarriered fires.

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

#define GC_TYPE_VALUE        1
#define GC_TYPE_VALUE_ARRAY  2

// ── BUGGY env_push — store without barrier before next alloc ────────

Value *buggy_env_push(Value *env, Value *arg, int env_len) {
    // Single-Value store into the GC-managed array — needs a barrier.
    env[env_len] = *arg;

    // BUG: no gc_dirty_vectors_add(env) before this may-collect alloc.
    // If arg references nursery objects, env[env_len] goes stale after a
    // nursery collection triggered below.
    Value *scratch = (Value *)gc_alloc(8 * sizeof(Value), GC_TYPE_VALUE);
    (void)scratch;

    return env;
}

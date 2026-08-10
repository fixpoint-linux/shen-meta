// REGRESSION-FIXTURE: memcpy into GC-allocated array with NO write barrier
//
// This models the historical missing-write-barrier bug: a fresh GC_VALUE_ARRAY
// allocation is populated via memcpy, but no gc_dirty_vectors_add barrier is
// issued before the next may-collect allocation.  If src_env references nursery
// objects and the next gc_alloc triggers a nursery collection, the memcpy'd
// values in new_env are stale.
//
// Expected verifier output: memcpy_unbarriered fires.

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

// ── BUGGY env_build — NO barrier between memcpy and scratch alloc ───

Value *buggy_env_build(Value *src_env, int env_len, int nargs) {
    Value *new_env = gc_alloc((env_len + nargs) * sizeof(Value),
                              GC_TYPE_VALUE_ARRAY);
    if (env_len > 0)
        memcpy(new_env, src_env, env_len * sizeof(Value));

    // BUG: no gc_dirty_vectors_add(new_env) before this alloc.
    // If src_env references nursery objects, new_env holds stale pointers
    // after a nursery collection triggered by the scratch alloc below.
    Value *scratch = gc_alloc(8 * sizeof(Value), GC_TYPE_VALUE);
    scratch[0] = *new_env;

    return new_env;
}

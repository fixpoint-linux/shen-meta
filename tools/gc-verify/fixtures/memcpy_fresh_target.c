// REGRESSION-FIXTURE: barrier_covers_alloc — NEGATIVE control
//
// A memcpy into a Value array immediately after its defining allocation,
// WITH a gc_dirty_vectors_add barrier between the memcpy and the next
// may-collect allocation.  barrier_covers_alloc covers it, so
// memcpy_unbarriered does NOT fire.
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

#define GC_TYPE_VALUE        1
#define GC_TYPE_VALUE_ARRAY  2

#define GC_VALUE_ARRAY(n) \
    ((Value *)gc_alloc((n) * sizeof(Value), GC_TYPE_VALUE_ARRAY))

// ── CORRECT: fresh target, no intervening alloc ─────────────────────

Value *build_env(Value *src_env, int env_len) {
    // Defining alloc at this VarDecl init.
    Value *new_env = GC_VALUE_ARRAY(env_len + 1);
    // Memcpy immediately after, no intervening alloc → fresh_target.
    memcpy(new_env, src_env, env_len * sizeof(Value));

    // Barrier after memcpy (covers it).
    gc_dirty_vectors_add(new_env);

    // Later alloc — but the memcpy is covered by both the barrier and
    // the fresh_target suppression, so memcpy_unbarriered does NOT fire.
    Value *scratch = gc_alloc(8 * sizeof(Value), GC_TYPE_VALUE);
    scratch[0] = new_env[0];

    return new_env;
}

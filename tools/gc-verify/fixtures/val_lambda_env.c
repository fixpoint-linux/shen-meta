// REGRESSION-FIXTURE: val_lambda — BEFORE fix (root-miss)
//
// This is a self-contained model of the historical val_lambda GC bug.
// The original code set v.lambda.code = code BEFORE the GC_VALUE_ARRAY
// allocation that could trigger collection.  When the nursery GC
// evacuated the code array (updating the rooted `code` parameter),
// the already-assigned v.lambda.code held a stale interior pointer.
//
// The fix: move v.lambda.code = code AFTER the env allocation.
// This file models the BROKEN (pre-fix) version.
//
// Expected verifier output: root_miss("val_lambda", ...) fires.
// Current fixed code (vm/zincvm.c:241-263): verifier must be clean.

#include <stddef.h>
#include <string.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER,
    VAL_STRING,
    VAL_SYMBOL,
    VAL_BOOLEAN,
    VAL_CONS,
    VAL_NIL,
    VAL_LAMBDA,
    VAL_MARK,
    VAL_PRIM,
    VAL_ERROR,
    VAL_VECTOR,
} ValTag;

typedef struct Instr Instr;

typedef struct Value {
    ValTag tag;
    union {
        long number;
        int boolean;
        struct {
            struct Value *car;
            struct Value *cdr;
        } cons;
        struct {
            Instr *code;
            int code_len;
            struct Value *env;
            int env_len;
        } lambda;
        struct {
            struct Value *data;
            int len;
        } vector;
        const char *prim_name;
    };
} Value;

// ── Modeled GC API (simplified) ─────────────────────────────────────

// These are opaque — the verifier only needs their names for may_collect.
extern void *gc_alloc(size_t bytes, int type_tag);
extern void *gc_alloc_oldgen(size_t bytes, int type_tag);
extern void *gc_alloc_atomic(size_t bytes);
extern void gc_root_push_ptr(void **slot);
extern void gc_root_pop(void);

#define GC_TYPE_VALUE        1
#define GC_TYPE_VALUE_ARRAY  2

#define GC_VALUE_ARRAY(n) \
    ((Value *)gc_alloc((n) * sizeof(Value), GC_TYPE_VALUE_ARRAY))

// ── BROKEN val_lambda (BEFORE fix) ──────────────────────────────────
//
// The bug: v.lambda.code is assigned BEFORE the GC_VALUE_ARRAY allocation
// that may trigger a nursery collection.  If GC moves the code array,
// the `code` parameter is updated (it's rooted), but v.lambda.code is NOT
// (v is a C local, not on the shadow stack).  Result: stale pointer.

Value val_lambda(Instr *code, int code_len, Value *env, int env_len) {
    Value v;
    memset(&v, 0, sizeof(v));
    v.tag = VAL_LAMBDA;

    // BUG: code assigned BEFORE the allocating call below.
    // v.lambda.code is NOT rooted — if GC fires inside GC_VALUE_ARRAY,
    // the code array may be evacuated but v.lambda.code won't be updated.
    v.lambda.code = code;
    v.lambda.code_len = code_len;

    if (env_len > 0) {
        // This GC_VALUE_ARRAY call may trigger a nursery collection.
        // The rooted `code` param is updated, but v.lambda.code is stale.
        v.lambda.env = GC_VALUE_ARRAY(env_len);
        memcpy(v.lambda.env, env, env_len * sizeof(Value));
        v.lambda.env_len = env_len;
        gc_root_pop();  // env
        gc_root_pop();  // code
    } else {
        v.lambda.env = NULL;
        v.lambda.env_len = 0;
    }

    return v;
}

// ── FIXED val_lambda (for reference, commented out) ─────────────────
//
// Value val_lambda_fixed(Instr *code, int code_len, Value *env, int env_len) {
//     Value v;
//     memset(&v, 0, sizeof(v));
//     v.tag = VAL_LAMBDA;
//     if (env_len > 0) {
//         gc_root_push_ptr((void **)&code);
//         gc_root_push_ptr((void **)&env);
//         v.lambda.env = GC_VALUE_ARRAY(env_len);
//         memcpy(v.lambda.env, env, env_len * sizeof(Value));
//         v.lambda.env_len = env_len;
//         gc_root_pop();  // env
//         gc_root_pop();  // code
//     } else { v.lambda.env = NULL; v.lambda.env_len = 0; }
//     // FIX: code assigned AFTER the allocating call.
//     v.lambda.code = code;
//     v.lambda.code_len = code_len;
//     return v;
// }

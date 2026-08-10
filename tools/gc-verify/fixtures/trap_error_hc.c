// REGRESSION-FIXTURE: trap-error handler.code captured before alloc (root-miss)
//
// This is a self-contained model of the historical trap-error GC bug.
// In the error-handling path of trap-error, `handler.lambda.code` was
// captured into a local pointer `hc` BEFORE the GC_VALUE_ARRAY allocation
// that could trigger a nursery collection.  When the GC evacuated the
// code array, the local `hc` held a stale interior pointer because it was
// not registered on the shadow stack.
//
// The fix (in vm/zincvm.c:1494): move `hc = handler.lambda.code` AFTER
// the GC_VALUE_ARRAY call so the pointer is fresh and need not be rooted.
//
// This file models the BROKEN (pre-fix) version.
//
// Expected verifier output: root_miss("trap_error_hc", ..., "hc") fires.

#include <stddef.h>
#include <string.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER,
    VAL_LAMBDA,
    VAL_CONS,
} ValTag;

typedef struct Instr Instr;

typedef struct Value {
    ValTag tag;
    union {
        long number;
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
    };
} Value;

// ── Modeled GC API ──────────────────────────────────────────────────

extern void *gc_alloc(size_t bytes, int type_tag);
extern void gc_root_push_value(void *vslot);
extern void gc_root_push_ptr(void **slot);
extern void gc_root_pop(void);
extern void gc_root_pop_to(size_t watermark);

#define GC_TYPE_VALUE_ARRAY  2
#define GC_VALUE_ARRAY(n) \
    ((Value *)gc_alloc((n) * sizeof(Value), GC_TYPE_VALUE_ARRAY))

// ── make_handler_env — the BROKEN (pre-fix) shape from vm/zincvm.c:1494 ─
//
// Pattern:
//   1. Instr *hc = handler->lambda.code;   // captures interior ptr into local
//   2. Value *henv = GC_VALUE_ARRAY(...);   // allocating call — may trigger GC
//   3. if (env_len > 0) memcpy(...);
//   4. henv[0].lambda.code = hc;            // uses hc AFTER the alloc
//
// hc is a LOCAL (NOT a parameter), so param_rooted does NOT apply.
// It is live across the GC_VALUE_ARRAY allocation but is NOT pushed on
// the shadow stack.  If nursery GC fires at step 2, henv is evacuated but
// hc remains stale (it was captured before the collection point).

Value *make_handler_env(Value *handler, int env_len) {
    // Step 1: capture handler's code pointer.  This creates a gc_use of
    // 'handler' (via the MemberExpr chain) and a gc_def of 'hc'.
    Instr *hc = handler->lambda.code;

    // Step 2: may-collect allocation.  hc is live across this (it will be
    // used at step 4) but NOT pushed on the shadow stack → root_miss.
    Value *henv = GC_VALUE_ARRAY(env_len + 1);

    if (env_len > 0)
        memcpy(henv, handler->lambda.env, env_len * sizeof(Value));

    // Step 3: use hc AFTER the allocating call.  This creates a gc_use of
    // 'hc', confirming it is live at the GC_VALUE_ARRAY call above.
    henv[0].lambda.code = hc;

    return henv;
}

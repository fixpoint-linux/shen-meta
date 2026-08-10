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

// ── BROKEN trap-error handler path (BEFORE fix) ─────────────────────
//
// Pattern: a GC-managed local pointer (Instr *hc) is assigned from a
// GC-managed field (handler.lambda.code), then an allocating call occurs
// (GC_VALUE_ARRAY), then hc is used.  hc is NOT pushed on the shadow
// stack, so if GC fires during the allocation, hc becomes stale.
//
// The verifier should flag hc as a root_miss at the gc_alloc call site.

Value *make_handler_env(Instr *hc, int hl, Value *handler, int env_len) {
    // hc is a GC-managed parameter (Instr *) — captured before the alloc.
    // In the buggy code, hc was a local variable assigned from
    // handler.lambda.code.  We model it as a parameter here so it's
    // clearly GC-managed.

    // BUG: hc is live here (it was passed in and will be used below),
    // but NOT pushed on the shadow stack before the allocation.
    Value *henv = GC_VALUE_ARRAY(env_len + 1);

    if (env_len > 0)
        memcpy(henv, handler->lambda.env, env_len * sizeof(Value));

    // Use hc after the allocating call — this is the stale-pointer scenario.
    // The verifier sees hc used here, so hc is live at the GC_VALUE_ARRAY
    // call above.  Since hc is not rooted, this is a root_miss.
    (void)hc;
    (void)hl;

    return henv;
}

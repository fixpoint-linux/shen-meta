// REGRESSION-FIXTURE: param_rooted suppression — NEGATIVE control
//
// A GC-managed pointer parameter `p` (Value *) is live across an
// allocating call with NO explicit gc_root_push.  Without param_rooted
// suppression, this would be flagged as root_miss.  But because `p` is
// a GC-managed POINTER parameter (Value *), its slot is rooted by the
// caller — the caller passed the address of a rooted slot.  The verifier
// MUST NOT flag this.
//
// Phase 7 (Fix 3c): the calling-convention assumption is that callers
// root the slot whose address they pass.  This is true for the C VM's
// shadow-stack protocol.
//
// NOTE: this fixture models the real-VM case where functions like
// exec_primitive take `Value *acc`, `Value *stack`, etc. as params and
// those slots are caller-rooted.  Without param_rooted, these ~100 FPs
// dominate the root_miss baseline.
//
// Expected verifier output: root_miss does NOT fire (clean).

#include <stddef.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER,
    VAL_CONS,
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

#define GC_TYPE_VALUE  1

// ── GC-managed VALUE POINTER param — caller-rooted ─────────────────
//
// `p` is a Value * parameter.  The caller passes the address of a slot
// it has already rooted, so `p` does not need its own gc_root_push here.
// root_miss must NOT fire because p is param_rooted.

Value *param_rooted_clean(Value *p, int n) {
    // Allocating call — p is live across this (used below).
    Value *q = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);

    // Use p after the alloc — p is caller-rooted → clean.
    Value *result = p;
    (void)q;
    (void)n;
    return result;
}

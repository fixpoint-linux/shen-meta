// REGRESSION-FIXTURE: branch precision — NEGATIVE control
//
// A GC-managed variable `v` is used ONLY in the true-branch of an if,
// while the allocating call is in the false-branch.  Because v is not
// live across the alloc on the false-branch path, and v is properly
// pushed before the alloc on the only path where it's live, root_miss
// MUST NOT fire.
//
// Phase 7: this tests that cfg_edge-based live_at correctly models
// branch divergence — a use in one branch does NOT make the var live
// in the other branch.
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
extern void gc_root_push_value(void *vslot);
extern void gc_root_pop(void);

#define GC_TYPE_VALUE  1

// ── Branch: v used in true-branch, alloc in false-branch ────────────
//
// v is pushed and used ONLY in the true-branch.
// The false-branch has an alloc but v is not live there.
// So live_at(v, alloc_sid) is false → root_miss clean.

Value branch_precision(int n, int flag, Value v) {
    if (flag) {
        // True branch: v is pushed, used after push, then popped.
        gc_root_push_value(&v);
        Value result = v;
        gc_root_pop();
        (void)n;
        return result;
    } else {
        // False branch: alloc happens here but v is NOT live.
        Value *p = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
        (void)p;
        Value zero = {VAL_NUMBER, {.number = 0}};
        return zero;
    }
}

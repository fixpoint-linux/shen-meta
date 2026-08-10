// REGRESSION-FIXTURE: must_rooted branch-join — POSITIVE control
//
// A GC-managed pointer variable `p` is pushed on the shadow stack only
// on ONE branch of an if-statement.  After the if, an allocating call
// occurs, and `p` is used.  At the join point, must_rooted is false
// because reaches_unrooted is true via the branch where p was NOT pushed.
// root_miss MUST fire at the alloc after the join.
//
// Phase 7: this tests the canonical must_rooted via reaches_unrooted
// complement — pushed on one branch only → must_rooted=false at join.
//
// Expected verifier output: root_miss FIRES.

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

// ── Pushed on only ONE branch; used after join + alloc ──────────────
//
// True-branch: push(p); false-branch: no push.
// After the if: alloc + use(p) → p is live at alloc but NOT must_rooted
// (because on the false-branch path, p is unrooted).  root_miss fires.

Value *must_rooted_join(int flag, Value *p) {
    if (flag) {
        // Push p on the shadow stack ONLY in the true-branch.
        gc_root_push_value(&p);
    }

    // Allocating call — p is live across this (used below).
    Value *q = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);

    // Use p after the alloc — p was only pushed on one branch,
    // so must_rooted(p, alloc_sid) is FALSE → root_miss fires.
    Value *result = p;
    (void)q;
    return result;
}

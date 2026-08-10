// REGRESSION-FIXTURE: straight-line root_miss — POSITIVE control
//
// A by-value GC-managed variable (Value v) is defined, then used
// across a subsequent may-collect allocation with NO push.
// Because v is NOT pushed on the shadow stack, and the alloc is NOT
// v's own defining alloc (v is a stack Value, the alloc is a separate
// gc_alloc), root_miss SHOULD still fire.
//
// This is the safe-by-design case that stays allowlisted — neither
// Fix 3a (defining_alloc) nor Fix 3b (CaseStmt scoping) suppresses it.
//
// Expected verifier output: root_miss fires.

#include <stddef.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER, VAL_CONS,
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

// ── Straight-line — Value v (by-value) + alloc + use(v) ─────────────

Value straight_line_bug(int n) {
    // v is a by-value GC-managed local (NOT a pointer).
    Value v;
    v.tag = VAL_NUMBER;
    v.number = n;

    // May-collect alloc — v is live across this (used below)
    // but NOT rooted → root_miss.
    Value *p = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);

    // Use v after the alloc.
    Value result = v;
    result.number += 1;
    (void)p;
    return result;
}

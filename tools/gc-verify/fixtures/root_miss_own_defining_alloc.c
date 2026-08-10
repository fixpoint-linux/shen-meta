// REGRESSION-FIXTURE: defining_alloc — NEGATIVE control (Fix 3a)
//
// A Value* local whose definition IS its own may-collect alloc
// (Value *e = GC_VALUE_ARRAY(...)).  At the alloc site, the var holds
// no pre-existing GC-managed pointer, so root_miss must NOT fire.
//
// Expected verifier output: root_miss does NOT fire (clean).

#include <stddef.h>
#include <string.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef enum {
    VAL_NUMBER, VAL_CONS, VAL_NIL,
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

#define GC_TYPE_VALUE        1
#define GC_TYPE_VALUE_ARRAY  2

#define GC_VALUE_ARRAY(n) \
    ((Value *)gc_alloc((n) * sizeof(Value), GC_TYPE_VALUE_ARRAY))

// ── defining_alloc pattern — alloc IS the definition ────────────────

void normal_init(int n) {
    // e is defined by its own gc_alloc initializer.
    // At the alloc site, e holds no pre-existing pointer → no root_miss.
    Value *e = GC_VALUE_ARRAY(n);

    // Use e after the definition.
    e[0].tag = VAL_NUMBER;
}

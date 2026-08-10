// REGRESSION-FIXTURE: memcpy into char* buffer (non-GC destination)
//
// memcpy into char* is safe — the destination is NOT a GC-managed pointer
// (it's allocated via gc_alloc_atomic, not gc_alloc with a GC type tag).
// The extractor must NOT emit a stmt_memcpy row for a non-GC dst.
//
// Expected verifier output: memcpy_unbarriered does NOT fire (clean).

#include <stddef.h>
#include <string.h>

// ── Modeled types (simplified from zinctypes.h) ─────────────────────

typedef struct Value {
    int tag;
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
extern void *gc_alloc_atomic(size_t bytes);

#define GC_TYPE_VALUE  1

// ── str_concat — memcpy into char* buffer (safe, non-GC dst) ───────

Value *str_concat(const char *msg, int len, Value *src_env) {
    char *buf = gc_alloc_atomic(len + 1);
    memcpy(buf, msg, len);
    buf[len] = '\0';

    // This alloc may collect, but buf is char* so no barrier needed.
    Value *scratch = gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    (void)src_env;

    return scratch;
}

// REGRESSION-FIXTURE: memcpy into Instr array — NEGATIVE control (Fix 1)
//
// Instr* arrays are GC-tag-traced, never barriered.  The verifier should
// NOT emit a stmt_memcpy row for this memcpy because Instr* is NOT in
// BARRIER_RELEVANT_TYPES.
//
// Expected verifier output: memcpy_unbarriered does NOT fire (clean).

#include <stddef.h>
#include <string.h>

// ── Modeled types ────────────────────────────────────────────────────

typedef struct Value Value;

typedef struct Instr {
    int op;
    int operand;
} Instr;

// ── Modeled GC API ──────────────────────────────────────────────────

extern void *gc_alloc(size_t bytes, int type_tag);
extern void gc_dirty_vectors_add(Value *v);

#define GC_TYPE_INSTR_ARRAY  3

void parse_body(Instr *src, int len) {
    // Instr* is NOT barrier-relevant — memcpy into it should be suppressed.
    Instr *code = (Instr *)gc_alloc(len * sizeof(Instr), GC_TYPE_INSTR_ARRAY);
    memcpy(code, src, len * sizeof(Instr));

    // A subsequent gc_alloc — but no stmt_memcpy row exists, so
    // memcpy_unbarriered cannot fire.
    void *scratch = gc_alloc(64, 0);
    (void)scratch;
}

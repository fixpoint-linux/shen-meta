// REGRESSION-FIXTURE: root_miss cross-case — NEGATIVE control (Fix 3b)
//
// A GC-managed variable is used only in case A, and a may-collect
// allocation occurs in case B.  Because next_stmt edges do NOT cross
// CaseStmt boundaries (Fix 3b), the var is NOT live at the alloc
// site in case B → root_miss does NOT fire.
//
// Expected verifier output: root_miss does NOT fire (clean).

#include <stddef.h>
#include <string.h>

// ── Modeled types ────────────────────────────────────────────────────

typedef enum {
    VAL_NUMBER, VAL_CONS,
} ValTag;

typedef struct Value {
    ValTag tag;
    union {
        long number;
    };
} Value;

typedef struct Instr {
    int op;
    int operand;
} Instr;

// ── Modeled GC API ──────────────────────────────────────────────────

extern void *gc_alloc(size_t bytes, int type_tag);

#define GC_TYPE_VALUE  1

void cross_case_fn(Instr *code, int tag) {
    switch (tag) {
        case 0: {
            // 'code' is used here (gc_use of code).
            int op = code->op;
            (void)op;
            break;
        }
        case 1: {
            // May-collect alloc in this case — 'code' is NOT live here
            // because next_stmt edges don't cross from case 0.
            Value *v = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
            (void)v;
            break;
        }
    }
}

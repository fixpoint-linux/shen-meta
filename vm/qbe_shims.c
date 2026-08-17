/*
 * qbe_shims.c — Value*-out-param ABI shims for QBE-generated code.
 *
 * Provides the pointer-based ABI the QBE backend targets.  Constructors write
 * a Value into a caller-supplied Value* slot (the activation-record temp).
 * prim_<F> wrappers dispatch through the REAL exec_primitive (zincvm.c),
 * so primitive semantics stay in lockstep with the interpreter.
 *
 * ZINC arg convention (critical): args evaluate RIGHT-TO-LEFT — rightmost
 * pushed first (ends at stack bottom), leftmost pushed last (on top).  A
 * 2-arg C prim pops a1 (top = leftmost) then a2 (below = rightmost).  So a
 * prim_<F>(out, a1, a2) shim for (- a1 a2) pushes a2 then a1, yielding
 * a1 - a2.  Even though + is commutative, we get the ordering right for the
 * non-commutative prims Slice 3 will generate.
 */
#include "qbe_shims.h"

/* ---- Value*-out-param constructors ---- */

void val_number_into(Value *out, long n)   { *out = val_number(n); }
void val_cons_into(Value *out, Value *a, Value *b) { *out = val_cons(*a, *b); }
void val_nil_into(Value *out)              { *out = val_nil(); }
void val_boolean_into(Value *out, int b)   { *out = val_boolean(b); }
void val_symbol_into(Value *out, const char *name) { *out = val_symbol(name); }
void global_get_into(Value *out, const char *name) { *out = defun_get(name); }

/* False is VAL_BOOLEAN(0) or VAL_NIL (Shen `if`/`and`/`or` treat both falsy). */
int is_false(Value *v) {
    return v->tag == VAL_NIL || (v->tag == VAL_BOOLEAN && !v->boolean);
}

/* ---- generic 2-arg primitive dispatch (RTL push) ---- */
static void prim2(const char *name, Value *out, Value *a1, Value *a2) {
    ValueArray stack;
    /* Roots: a1/a2 are pointers into the QBE frame's Value[] activation
       record; they must survive any GC triggered by va_push growing the
       temp stack.  gc_root_push_value rewrites interior pointers in place. */
    gc_root_push_value(a1);
    gc_root_push_value(a2);
    stack.data = GC_VALUE_ARRAY(8);
    stack.len = 0; stack.cap = 8;
    va_push(&stack, *a2);   /* rightmost first → bottom */
    va_push(&stack, *a1);   /* leftmost last → on top (a1 - a2 convention) */
    exec_primitive(name, out, &stack);
    gc_root_pop();          /* a2 */
    gc_root_pop();          /* a1 */
}

void prim_add(Value *out, Value *a1, Value *a2) { prim2("+", out, a1, a2); }
void prim_sub(Value *out, Value *a1, Value *a2) { prim2("-", out, a1, a2); }

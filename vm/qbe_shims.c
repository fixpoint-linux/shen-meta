/*
 * qbe_shims.c — Value*-out-param ABI shims for QBE-generated code.
 *
 * Provides the pointer-based ABI the QBE backend targets.  Constructors write
 * a Value into a caller-supplied Value* slot (the activation-record temp).
 * prim_<F> wrappers (qbe_prims_gen.c) dispatch through the REAL exec_primitive
 * (zincvm.c), so primitive semantics stay in lockstep with the interpreter.
 *
 * ZINC arg convention (critical): args evaluate RIGHT-TO-LEFT — rightmost
 * pushed first (ends at stack bottom), leftmost pushed last (on top).  A
 * k-arg C prim pops a1 (top = leftmost) then a2 (below = rightmost), ...
 * So a prim_<F>(out, a1, a2) shim for (- a1 a2) pushes a2 then a1, yielding
 * a1 - a2.  prim_dispatch below generalizes this to arity 0-3.
 */
#include "qbe_shims.h"

/* ---- Value*-out-param constructors ---- */

void val_number_into(Value *out, long n)   { *out = val_number(n); }
void val_string_into(Value *out, const char *data, long len) { *out = val_string(data, (int)len); }
void val_cons_into(Value *out, Value *a, Value *b) { *out = val_cons(*a, *b); }
void val_nil_into(Value *out)              { *out = val_nil(); }
void val_boolean_into(Value *out, int b)   { *out = val_boolean(b); }
void val_symbol_into(Value *out, const char *name) { *out = val_symbol(name); }
void val_lambda_into(Value *out, Instr *code, int code_len, Value *env, int env_len) {
    *out = val_lambda(code, code_len, env, env_len);
}
void global_get_into(Value *out, const char *name) { *out = defun_get(name); }
void copy_value(Value *dst, Value *src)    { *dst = *src; }

/* jmpf condition — exact OP_JMPF semantics (VAL_BOOLEAN(false) only). */
int is_false(Value *v) {
    return v->tag == VAL_BOOLEAN && !v->boolean;
}

/* ---- generic primitive dispatch (RTL push) ---- */
void prim_dispatch(const char *name, int nargs, Value *out, Value **args) {
    ValueArray stack;
    /* Roots: args[i] are pointers into the QBE frame's Value[] activation
       record; they must survive any GC triggered by GC_VALUE_ARRAY / va_push
       below.  gc_root_push_value rewrites interior pointers in place. */
    for (int i = 0; i < nargs; i++) gc_root_push_value(args[i]);
    stack.data = GC_VALUE_ARRAY(8);
    stack.len = 0; stack.cap = 8;
    /* Push right-to-left: rightmost arg first -> bottom, leftmost last -> top.
       args[0] = a1 = leftmost, args[nargs-1] = rightmost. */
    for (int i = nargs - 1; i >= 0; i--) va_push(&stack, *args[i]);
    exec_primitive(name, out, &stack);
    for (int i = 0; i < nargs; i++) gc_root_pop();
}

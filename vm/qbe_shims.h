/*
 * qbe_shims.h — Value*-out-param ABI surface for QBE-generated code.
 *
 * The QBE backend (Slice 3 lowerer) generates bytecode where every ZINC
 * temp is a `l` (long) = `Value*` pointer into a per-frame Value[] activation
 * record.  The C runtime functions here present that pointer-based ABI.
 *
 * Reuse-not-reimplement: exec_primitive / va_push / va_pop are the REAL
 * zincvm.c implementations, exposed here by dropping `static` in zincvm.c.
 * The prim_<F> shims below build a temp ValueArray, push args RIGHT-TO-LEFT
 * (ZINC convention: rightmost pushed first → ends at stack bottom, leftmost
 * pushed last → on top), and hand off to exec_primitive.  This guarantees
 * zero divergence from the proven primitive logic.
 */
#ifndef QBE_SHIMS_H
#define QBE_SHIMS_H

#include "zincvm.h"   /* Value, ValueArray, val_number/val_cons/..., defun_get */

/* ---- exposed from zincvm.c (static dropped) ---- */
int   exec_primitive(const char *name, Value *acc, ValueArray *stack);
void  va_push(ValueArray *a, Value v);
Value va_pop(ValueArray *a);

/* ---- Value*-out-param constructors ---- */
void val_number_into(Value *out, long n);
void val_cons_into(Value *out, Value *a, Value *b);
void val_nil_into(Value *out);
void val_boolean_into(Value *out, int b);
void val_symbol_into(Value *out, const char *name);
void global_get_into(Value *out, const char *name);
int  is_false(Value *v);

/* ---- prim shims (2-arg arithmetic for the (+ 1 2) slice; Slice 3
 *      generates the full 69 from vm/prims.def with the same pattern) ---- */
void prim_add(Value *out, Value *a1, Value *a2);
void prim_sub(Value *out, Value *a1, Value *a2);

#endif /* QBE_SHIMS_H */

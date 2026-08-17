/*
 * qbe_shims.h — Value*-out-param ABI surface for QBE-generated code.
 *
 * The QBE backend (Slice 3 lowerer) generates bytecode where every ZINC
 * temp is a `l` (long) = `Value*` pointer into a per-frame Value[] activation
 * record (one `alloc8 40` slot per temp).  The C runtime functions here
 * present that pointer-based ABI.
 *
 * Reuse-not-reimplement: exec_primitive / va_push / va_pop are the REAL
 * zincvm.c implementations, exposed here by dropping `static` in zincvm.c.
 * The prim_<F> shims (generated into qbe_prims_gen.h/.c) build a temp
 * ValueArray, push args RIGHT-TO-LEFT (ZINC convention: rightmost pushed
 * first -> ends at stack bottom, leftmost pushed last -> on top), and hand
 * off to exec_primitive.  This guarantees zero divergence from the proven
 * primitive logic.
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
void val_string_into(Value *out, const char *data, long len);
void val_cons_into(Value *out, Value *a, Value *b);
void val_nil_into(Value *out);
void val_boolean_into(Value *out, int b);
void val_symbol_into(Value *out, const char *name);
void val_lambda_into(Value *out, Instr *code, int code_len, Value *env, int env_len);
void global_get_into(Value *out, const char *name);
void copy_value(Value *dst, Value *src);

/* jmpf condition: matches the C VM's OP_JMPF exactly — jump only when the
 * value is VAL_BOOLEAN(false).  (VAL_NIL is NOT a false branch condition.) */
int  is_false(Value *v);

/* Generic primitive dispatch: build a temp ValueArray, push args RIGHT-TO-LEFT
 * (args[0] = a1 = leftmost, args[nargs-1] = rightmost), hand off to the REAL
 * exec_primitive.  All prim_<F> wrappers route through here. */
void prim_dispatch(const char *name, int nargs, Value *out, Value **args);

/* ---- prim shims (generated from vm/qbe-prims.list) ---- */
#include "qbe_prims_gen.h"

#endif /* QBE_SHIMS_H */

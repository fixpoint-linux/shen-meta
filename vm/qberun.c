/*
 * qberun.c — differential driver for the QBE native codegen.
 *
 * Initialises the C runtime (GC + globals), loads the reduced bundle
 * (globals.csexp) so the bundled closures are available, and drives the
 * QBE-compiled clo_* closures for AGENTS.md Tests 1-4 + the let regression
 * (Test 5).
 *
 * For each test, the driver computes BOTH:
 *   - the NATIVE result: the QBE-compiled clo_* extern (pointer-ABI), and
 *   - the REFERENCE (C VM) result: interp_ref(name, args) — loads the SAME
 *     bundled closure via defun_get (a safe.* wrapper or helper) and runs it
 *     through vm_exec_env with the same args, replicating exactly the apply
 *     path in zincvm.c (new_env = lambda.env ++ args).
 * and asserts qbe_equal(native, reference).  This proves the native QBE
 * closures produce the SAME result as the C VM interpreter on identical
 * inputs — a true differential, not a hardcoded expectation.
 *
 *   Test 1: (+ 1 2)              native @clo_plus         ref interp safe.+         -> 3
 *   Test 2: (reverse [1 2 3])    native @clo_reverse      ref interp reverse        -> [3 2 1]
 *   Test 3: (factorial 5)        native @clo_factorial    ref interp factorial      -> 120
 *   Test 4: (open "Makefile" in) -> (close stream)        native prim_open/close,
 *                                                         ref interp safe.open/close -> []
 *   Test 5: (qbe-let-test 5)     native @clo_qbe_let_test ref interp qbe-let-test   -> 2
 *
 * Build via `make diff-test` (see Makefile): cosmocc links vm/qberun.c +
 * vm/qbe_shims.c + vm/qbe_prims_gen.c + vm/zincvm.c (-DZINCTEST) + vm/gc.c
 * against the dual-arch QBE objects assembled from globals.qbe.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

#include "zincvm.h"
#include "qbe_shims.h"

/* QBE entry points (from globals.qbe).  `l %out` is the result Value*. */
extern void clo_plus(Value *out, Value *a0, Value *a1);
extern void clo_reverse(Value *out, Value *a0);
extern void clo_factorial(Value *out, Value *a0);
extern void clo_qbe_let_test(Value *out, Value *a0);
/* Defunctionalized-cur closures (Slice 5): native trap-error == C VM. */
extern void clo_strlen_acc(Value *out, Value *a0, Value *a1);
extern void clo_fresh_var(Value *out, Value *a0);

/* Minimal deep equality for numbers/nil/booleans/cons (the test values). */
static int qbe_equal(Value a, Value b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
    case VAL_NUMBER:  return a.number == b.number;
    case VAL_NIL:     return 1;
    case VAL_BOOLEAN: return a.boolean == b.boolean;
    case VAL_SYMBOL:  return strcmp(a.sym.name, b.sym.name) == 0;
    case VAL_STRING:  return a.str.len == b.str.len &&
                              memcmp(a.str.data, b.str.data, a.str.len) == 0;
    case VAL_CONS:
        return qbe_equal(*a.cons.car, *b.cons.car) &&
               qbe_equal(*a.cons.cdr, *b.cons.cdr);
    default: return 0;
    }
}


/* Call a bundled closure through the C VM interpreter (vm_exec_env) with the
 * given args, replicating exactly the apply path in zincvm.c:2348-2369:
 * new_env = lambda.env ++ [a0..a{k-1}], then vm_exec_env(code,...).
 * This is the true differential reference: SAME closure, SAME args, run by the
 * C VM interpreter, versus the native QBE clo_* closure.  Returns the result.
 * The result is left rooted (one shadow-stack slot); caller pops after
 * comparing. */
static Value interp_ref(const char *name, Value *args, int nargs) {
    Value closure = defun_get(name);
    if (closure.tag != VAL_LAMBDA) {
        fprintf(stderr, "qberun: interp_ref %s: not a bundled closure (tag=%d)\n",
                name, (int)closure.tag);
        Value bad; memset(&bad, 0, sizeof(bad)); bad.tag = VAL_NIL;
        return bad;
    }
    gc_root_push_value(&closure);
    int lel = closure.lambda.env_len;
    int new_len = lel + nargs;
    Value *ne = GC_VALUE_ARRAY(new_len);
    if (lel > 0 && closure.lambda.env)
        memcpy(ne, closure.lambda.env, lel * sizeof(Value));
    for (int i = 0; i < nargs; i++) {
        ne[lel + i] = args[i];
        if (gc_in_oldgen(ne) && value_references_nursery(&args[i]))
            gc_dirty_vectors_add(ne);
    }
    Value r = vm_exec_env(closure.lambda.code, closure.lambda.code_len, ne, new_len);
    gc_root_push_value(&r);             /* root output (may be nursery) */
    gc_root_pop();                      /* pop closure */
    return r;                           /* caller pops r */
}

static int fails = 0;
static void diff_check(const char *label, Value native, Value ref) {
    int ok = qbe_equal(native, ref);
    printf("diff %s: ", label);
    print_value(ref);
    printf("  %s\n", ok ? "MATCH" : "MISMATCH");
    if (!ok) fails++;
    gc_root_pop();                      /* pop ref from interp_ref */
}

int main(void) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();
    gc_init(256UL * 1024 * 1024);

    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    /* Load the reduced bundle: provides the bundled closures (safe wrappers
     * for +/open/close, plus reverse/factorial/qbe-sub2/qbe-let-test) that
     * interp_ref runs through the C VM interpreter as the reference. */
    {
        char *buf = read_file_or_stdin("globals.csexp");
        if (!buf) { fprintf(stderr, "qberun: cannot read globals.csexp\n"); return 1; }
        const char *p = buf;
        while (*p && isspace((unsigned char)*p)) p++;
        int n = vm_load_bundle(p);
        if (n == 0) { fprintf(stderr, "qberun: bundle load failed\n"); return 1; }
        free(buf);
    }

    /* ---- Test 1: (+ 1 2) -> 3 ---- */
    {
        Value a = val_number(1), b = val_number(2), out;
        gc_root_push_value(&a); gc_root_push_value(&b);
        clo_plus(&out, &a, &b);
        gc_root_pop(); gc_root_pop();
        int ok = (out.tag == VAL_NUMBER && out.number == 3);
        printf("test1 (+ 1 2): "); print_value(out);
        printf("  %s\n", ok ? "OK (expect 3)" : "FAIL");
        if (!ok) fails++;

        Value args1[2] = { a, b };
        Value ref = interp_ref("+", args1, 2);
        diff_check("(+ 1 2)", out, ref);
    }

    /* ---- Test 2: (reverse [1 2 3]) -> [3 2 1] ---- */
    {
        Value expect = val_cons(val_number(3),
                        val_cons(val_number(2),
                         val_cons(val_number(1), val_nil())));
        Value list123 = val_cons(val_number(1),
                         val_cons(val_number(2),
                          val_cons(val_number(3), val_nil())));
        Value out;
        gc_root_push_value(&list123);
        clo_reverse(&out, &list123);
        gc_root_pop();
        int ok = qbe_equal(out, expect);
        printf("test2 (reverse [1 2 3]): "); print_value(out);
        printf("  %s\n", ok ? "OK (expect [3 2 1])" : "FAIL");
        if (!ok) fails++;

        Value args2[1] = { list123 };
        Value ref = interp_ref("reverse", args2, 1);
        diff_check("(reverse [1 2 3])", out, ref);
    }

    /* ---- Test 3: (factorial 5) -> 120 ---- */
    {
        Value n = val_number(5), out;
        gc_root_push_value(&n);
        clo_factorial(&out, &n);
        gc_root_pop();
        int ok = (out.tag == VAL_NUMBER && out.number == 120);
        printf("test3 (factorial 5): "); print_value(out);
        printf("  %s\n", ok ? "OK (expect 120)" : "FAIL");
        if (!ok) fails++;

        Value args3[1] = { n };
        Value ref = interp_ref("factorial", args3, 1);
        diff_check("(factorial 5)", out, ref);
    }

    /* ---- Test 4: (open "Makefile" in) -> (close stream) -> [] ---- */
    {
        Value dir = val_symbol("in");
        Value path = val_string("Makefile", 8);
        Value stream, out;
        gc_root_push_value(&dir); gc_root_push_value(&path);
        prim_open(&stream, &path, &dir);
        prim_close(&out, &stream);
        gc_root_pop(); gc_root_pop();
        int ok = (out.tag == VAL_NIL);
        printf("test4 (open+close): "); print_value(out);
        printf("  %s\n", ok ? "OK (expect [])" : "FAIL");
        if (!ok) fails++;

        /* Reference: run the SAME bundled open/close closures through the C VM
         * interpreter (defun_get returns the safe.open/safe.close lambdas).
         * Native prim_open/prim_close == interp safe.open/safe.close. */
        Value open_args[2] = { path, dir };
        Value sref = interp_ref("open", open_args, 2);
        int s_ok = (sref.tag == VAL_STREAM);
        printf("diff (open \"Makefile\" in): "); print_value(sref);
        printf("  %s\n", s_ok ? "MATCH (stream)" : "MISMATCH");
        if (!s_ok) fails++;
        gc_root_pop();   /* pop sref */

        Value close_args[1] = { sref };
        Value cref = interp_ref("close", close_args, 1);
        diff_check("(close (open ...))", out, cref);
    }

    /* ---- Test 5: (qbe-let-test 5) = sub2((let Y (+ X 1) (+ Y Y))=12, 10) -> 2
         (letz pop-vs-peek regression: Y is a computed value used twice, so
         letz is genuinely emitted and cannot be inlined away) ---- */
    {
        Value x = val_number(5), out;
        gc_root_push_value(&x);
        clo_qbe_let_test(&out, &x);
        gc_root_pop();
        int ok = (out.tag == VAL_NUMBER && out.number == 2);
        printf("test5 (let Y (+ X 1) (+ Y Y) then sub2 10): "); print_value(out);
        printf("  %s\n", ok ? "OK (expect 2)" : "FAIL");
        if (!ok) fails++;

        Value args5[1] = { x };
        Value ref = interp_ref("qbe-let-test", args5, 1);
        diff_check("(qbe-let-test 5)", out, ref);
    }

    /* ---- Test 6: (strlen-acc "abc" 0) -> 3.
         Exercises the defunctionalized trap-error: the cur body `(pos Str N)`
         throws "pos out of bounds" on the terminating call (handler -> 0), and
         the env mapping (body access 1,2 == enclosing access 0,1). ---- */
    {
        Value str6 = val_string("abc", 3);
        Value n6 = val_number(0);
        Value out6;
        gc_root_push_value(&str6); gc_root_push_value(&n6);
        clo_strlen_acc(&out6, &str6, &n6);
        gc_root_pop(); gc_root_pop();
        int ok = (out6.tag == VAL_NUMBER && out6.number == 3);
        printf("test6 (strlen-acc \"abc\" 0): "); print_value(out6);
        printf("  %s\n", ok ? "OK (expect 3)" : "FAIL");
        if (!ok) fails++;

        Value args6[2] = { str6, n6 };
        Value ref6 = interp_ref("strlen-acc", args6, 2);
        diff_check("(strlen-acc \"abc\" 0)", out6, ref6);
    }

    /* ---- Test 7: (fresh-var (intern "X")) -> X1 (counter reset each side).
         Exercises the non-throwing trap path (body succeeds, handler unused)
         plus the gensym-counter value table round-trip. ---- */
    {
        Value p7 = val_symbol("X");
        Value out7;
        value_set("shen.*gensym*", val_number(0));
        gc_root_push_value(&p7);
        clo_fresh_var(&out7, &p7);
        gc_root_pop();
        int ok = (out7.tag == VAL_SYMBOL && strcmp(out7.sym.name, "X1") == 0);
        printf("test7 (fresh-var X): "); print_value(out7);
        printf("  %s\n", ok ? "OK (expect X1)" : "FAIL");
        if (!ok) fails++;

        value_set("shen.*gensym*", val_number(0));
        Value args7[1] = { p7 };
        Value ref7 = interp_ref("fresh-var", args7, 1);
        diff_check("(fresh-var X)", out7, ref7);
    }

    if (fails) { printf("DIFF-TEST FAILED: %d\n", fails); return 1; }
    printf("DIFF-TEST ALL PASS: native QBE == C VM interpreter for Tests 1-7\n");
    return 0;
}

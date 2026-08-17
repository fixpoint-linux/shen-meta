/*
 * qberun.c — differential driver for the QBE Slice-3 native codegen.
 *
 * Initialises the C runtime (GC + globals) and invokes the QBE-compiled
 * closures for AGENTS.md Tests 1-4, comparing each result against the
 * expected value (the same result `./zincvm globals.csexp` produces).
 *
 *   Test 1: (+ 1 2)            via @clo_plus          -> 3
 *   Test 2: (reverse [1 2 3])  via @clo_reverse       -> [3 2 1]
 *   Test 3: (factorial 5)      via @clo_factorial     -> 120
 *   Test 4: (open "Makefile" in) -> (close stream)    via prim_open/prim_close
 *
 * Build via `make qberun` (see Makefile): cosmocc links vm/qberun.c +
 * vm/qbe_shims.c + vm/qbe_prims_gen.c + vm/zincvm.c (-DZINCTEST) + vm/gc.c
 * against the dual-arch QBE objects assembled from globals.qbe.
 */
#include <stdio.h>
#include <stdint.h>

#include "zincvm.h"
#include "qbe_shims.h"

/* QBE entry points (from globals.qbe).  `l %out` is the result Value*. */
extern void clo_plus(Value *out, Value *a0, Value *a1);
extern void clo_reverse(Value *out, Value *a0);
extern void clo_factorial(Value *out, Value *a0);
extern void clo_qbe_let_test(Value *out, Value *a0);

/* Minimal deep equality for numbers/nil/booleans/cons (the test values). */
static int qbe_equal(Value a, Value b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
    case VAL_NUMBER:  return a.number == b.number;
    case VAL_NIL:     return 1;
    case VAL_BOOLEAN: return a.boolean == b.boolean;
    case VAL_CONS:
        return qbe_equal(*a.cons.car, *b.cons.car) &&
               qbe_equal(*a.cons.cdr, *b.cons.cdr);
    default: return 0;
    }
}

int main(void) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();
    gc_init(256UL * 1024 * 1024);

    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    int fails = 0;

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
    }

    /* ---- Test 5: (qbe-let-test 5) = sub2((let Y (+ 5 1) (+ Y Y))=12, 10) -> 2
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
    }

    if (fails) { printf("QBE TESTS FAILED: %d\n", fails); return 1; }
    printf("QBE TESTS ALL PASS (Tests 1-4 match zincvm)\n");
    return 0;
}

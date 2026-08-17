/*
 * qbesmoke.c — Slice-2 smoke driver: (+ 1 2) -> 3 via hand-written add12.qbe.
 * Kept as the minimal `make qbe-smoke` gate.
 */
#include <stdio.h>
#include <stdint.h>

#include "zincvm.h"
#include "qbe_shims.h"

extern void add12(Value *out);

int main(void) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();
    gc_init(256UL * 1024 * 1024);

    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    Value out;
    add12(&out);

    printf("add12 => ");
    if (out.tag == VAL_NUMBER) {
        printf("%ld\n", out.number);
        return (out.number == 3) ? 0 : 1;
    }
    printf("(non-number, tag=%d)\n", (int)out.tag);
    return 1;
}

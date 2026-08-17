/*
 * qberun.c — minimal driver for the QBE pointer-ABI smoke test.
 *
 * Initialises the C runtime (GC + globals) and invokes a QBE-compiled entry
 * point.  Slice 2's entry is `add12` (from vm/add12.qbe, symbol `add12` =
 * QBE `$add12` with the `$` stripped), which computes (+ 1 2) into a
 * Value* out-param.
 *
 * Build via `make qberun` (see Makefile): cosmocc links vm/qberun.c +
 * vm/qbe_shims.c + vm/zincvm.c (-DZINCTEST, to suppress zincvm's own main) +
 * vm/gc.c against the dual-arch QBE objects.
 */
#include <stdio.h>
#include <stdint.h>

#include "zincvm.h"
#include "qbe_shims.h"

/* QBE entry: `export function $add12(l %out)` → C symbol `add12`.
 * No return type in IL, so C prototype is void; `l %out` is a Value*. */
extern void add12(Value *out);

int main(void) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();
    gc_init(256UL * 1024 * 1024);

    /* Register typed walkers (mirrors zincvm.c main) so gc_scan_roots can
       trace defun_table closures / values_table values / traced_code. */
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

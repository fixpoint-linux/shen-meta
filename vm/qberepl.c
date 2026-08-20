/*
 * qberepl.c — run the Shen REPL on the QBE-NATIVE meta-interpreter.
 *
 * The reduced bundle (globals.csexp) is loaded so the C-runtime global tables
 * (namespace 1: defun_table for bundled closures; namespace 2: the Shen
 * `global-table` value, streams, shen.*gensym* etc.) are initialised.  But the
 * meta-interpreter itself (interp-eval / interp-load-raw / extract-kl /
 * kl->zinc / toplevel-interp) runs as QBE-compiled NATIVE closures (globals.qbe
 * linked against vm/qbe_shims.c + vm/qbe_prims_gen.c + vm/zincvm.c + vm/gc.c),
 * NOT through the C VM interpreter.
 *
 * Flow (mirrors zincvm.c --repl, but driving the native clo_* closures):
 *   1. Load the 22 Shen OS .kl files via native clo_interp_load_raw.
 *   2. Evaluate (shen.initialise) through the native meta-interpreter:
 *        marshal_to_tagged → clo_extract_kl → clo_kl_to_zinc →
 *        clo_toplevel_interp → demarshal_from_tagged
 *      (the same chain the C eval-kl primitive uses, but with the QBE-native
 *      closures instead of vm_exec_env on the C-VM-interpreted bytecode).
 *   3. Evaluate (shen.repl) the same way — it reads stdin, evaluates each
 *      form through the native interpreter, and prints results until EOF.
 *
 * Build via `make qberepl` (see Makefile): cosmocc links vm/qberepl.c +
 * vm/qbe_shims.c + vm/qbe_prims_gen.c + vm/zincvm.c (-DZINCTEST) + vm/gc.c
 * against the QBE objects assembled from globals.qbe.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

#include "zincvm.h"
#include "qbe_shims.h"

/* QBE-native entry points (from globals.qbe, pointer ABI: `l %out` first). */
extern void clo_interp_load_raw(Value *out, Value *a0);
extern void clo_extract_kl(Value *out, Value *a0);
extern void clo_kl_to_zinc(Value *out, Value *a0);
extern void clo_toplevel_interp(Value *out, Value *a0);
extern void clo_read_file_raw(Value *out, Value *a0);
extern void clo_interp_eval(Value *out, Value *a0);
extern void clo_kmacros(Value *out, Value *a0);

/* Replicate the eval-kl chain against the NATIVE interp closures.  `form` is a
   Shen application list (e.g. (shen.initialise)).  Returns the result rooted on
   the shadow stack (caller pops); intermediate values are rooted/unrooted
   around each allocating native call. */
static Value eval_native(Value form) {
    gc_root_push_value(&form);
    Value tagged = marshal_to_tagged(form);
    gc_root_push_value(&tagged);
    Value kl; clo_extract_kl(&kl, &tagged);
    gc_root_push_value(&kl);
    Value zinc; clo_kl_to_zinc(&zinc, &kl);
    gc_root_push_value(&zinc);
    Value tres; clo_toplevel_interp(&tres, &zinc);
    gc_root_push_value(&tres);
    Value result = demarshal_from_tagged(tres);
    gc_root_pop();  /* tres */
    gc_root_pop();  /* zinc */
    gc_root_pop();  /* kl */
    gc_root_pop();  /* tagged */
    gc_root_pop();  /* form */
    gc_root_push_value(&result);   /* caller pops */
    return result;
}

/* Load the Shen OS kernel .kl files into the meta-interpreter (namespace 2)
   via native clo_interp_load_raw.  Returns 0 on success (each file `loaded`). */
static int load_os(void) {
    static const char *os_order[] = {
        "vendor/ShenOSKernel-41.2/klambda/core.kl",
        "vendor/ShenOSKernel-41.2/klambda/declarations.kl",
        "vendor/ShenOSKernel-41.2/klambda/types.kl",
        "vendor/ShenOSKernel-41.2/klambda/macros.kl",
        "vendor/ShenOSKernel-41.2/klambda/load.kl",
        "vendor/ShenOSKernel-41.2/klambda/toplevel.kl",
        "vendor/ShenOSKernel-41.2/klambda/sys.kl",
        "vendor/ShenOSKernel-41.2/klambda/dict.kl",
        "vendor/ShenOSKernel-41.2/klambda/track.kl",
        "vendor/ShenOSKernel-41.2/klambda/reader.kl",
        "vendor/ShenOSKernel-41.2/klambda/writer.kl",
        "vendor/ShenOSKernel-41.2/klambda/yacc.kl",
        "vendor/ShenOSKernel-41.2/klambda/prolog.kl",
        "vendor/ShenOSKernel-41.2/klambda/sequent.kl",
        "vendor/ShenOSKernel-41.2/klambda/t-star.kl",
        "shen/overrides-pure.kl",
        "vendor/ShenOSKernel-41.2/klambda/extension-expand-dynamic.kl",
        "vendor/ShenOSKernel-41.2/klambda/extension-features.kl",
        "vendor/ShenOSKernel-41.2/klambda/extension-launcher.kl",
        "vendor/ShenOSKernel-41.2/klambda/extension-programmable-pattern-matching.kl",
        "vendor/ShenOSKernel-41.2/klambda/stlib.kl",
        "vendor/ShenOSKernel-41.2/klambda/init.kl",
        NULL };
    for (int i = 0; os_order[i] != NULL; i++) {
        Value path = val_string(os_order[i], (long)strlen(os_order[i]));
        gc_root_push_value(&path);
        CatchFrame cf;
        cf.parent = vm_catch_chain;
        cf.in_trap_error = 0;
        vm_catch_chain = &cf;
        int thrown = 0;
        if (setjmp(cf.buf) == 0) {
            Value out; clo_interp_load_raw(&out, &path);
            int ok = (out.tag == VAL_SYMBOL && strcmp(out.sym.name, "loaded") == 0);
            vm_catch_chain = cf.parent;
            gc_root_pop();   /* path */
            if (!ok) {
                fprintf(stderr, "qberepl: OS load returned non-loaded at %s (tag=%d)\n",
                        os_order[i], (int)out.tag);
                return 1;
            }
        } else {
            thrown = 1;
            fprintf(stderr, "qberepl: OS load THREW at %s: ", os_order[i]);
            print_value(cf.error_val);
            printf("\n");
            vm_catch_chain = cf.parent;
            gc_root_pop();   /* path */
            return 1;
        }
        (void)thrown;
    }
    return 0;
}

int main(int argc, char **argv) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();
    gc_init(256UL * 1024 * 1024);

    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    /* Load the reduced bundle: sets up the bundled closures (namespace 1) and
       the Shen `global-table` value + streams (namespace 2). */
    {
        char *buf = read_file_or_stdin("globals.csexp");
        if (!buf) { fprintf(stderr, "qberepl: cannot read globals.csexp\n"); return 1; }
        const char *p = buf;
        while (*p && isspace((unsigned char)*p)) p++;
        int n = vm_load_bundle(p);
        if (n == 0) { fprintf(stderr, "qberepl: bundle load failed\n"); return 1; }
        free(buf);
    }

    printf("=== QBE native Shen REPL ===\n");
    fflush(stdout);

    /* --condtest: run native kmacros on hand-built forms, to see whether
       normalize/cond handling (independent of the parser) throws on a
       terminating `(true ...)` clause. */
    if (argc >= 2 && strcmp(argv[1], "--condtest") == 0) {
        /* (if true 1 2) — should simplify to 1 via kmacros rule [if true X Y] */
        Value it = val_cons(val_symbol("if"), val_cons(val_symbol("true"),
                       val_cons(val_number(1), val_cons(val_number(2), val_nil()))));
        gc_root_push_value(&it);
        { CatchFrame cf; cf.parent=vm_catch_chain; cf.in_trap_error=0; vm_catch_chain=&cf;
          if (setjmp(cf.buf)==0) { Value out; clo_kmacros(&out,&it); vm_catch_chain=cf.parent;
            printf("kmacros (if true 1 2) -> "); print_value(out); printf("\n"); }
          else { vm_catch_chain=cf.parent; printf("kmacros (if true 1 2) THREW: "); print_value(cf.error_val); printf("\n"); } }
        gc_root_pop();
        /* (if false 1 2) — should simplify to 2 via kmacros rule [if false X Y] */
        Value iff = val_cons(val_symbol("if"), val_cons(val_symbol("false"),
                       val_cons(val_number(1), val_cons(val_number(2), val_nil()))));
        gc_root_push_value(&iff);
        { CatchFrame cf; cf.parent=vm_catch_chain; cf.in_trap_error=0; vm_catch_chain=&cf;
          if (setjmp(cf.buf)==0) { Value out; clo_kmacros(&out,&iff); vm_catch_chain=cf.parent;
            printf("kmacros (if false 1 2) -> "); print_value(out); printf("\n"); }
          else { vm_catch_chain=cf.parent; printf("kmacros (if false 1 2) THREW: "); print_value(cf.error_val); printf("\n"); } }
        gc_root_pop();
        /* (cond (true 1)) */
        Value c1 = val_cons(val_symbol("true"), val_cons(val_number(1), val_nil()));
        Value f1 = val_cons(val_symbol("cond"), val_cons(c1, val_nil()));
        gc_root_push_value(&f1);
        CatchFrame cf; cf.parent = vm_catch_chain; cf.in_trap_error = 0; vm_catch_chain = &cf;
        if (setjmp(cf.buf) == 0) {
            Value out; clo_kmacros(&out, &f1);
            vm_catch_chain = cf.parent;
            printf("kmacros (cond (true 1)) -> "); print_value(out); printf("\n");
        } else {
            vm_catch_chain = cf.parent;
            printf("kmacros (cond (true 1)) THREW: "); print_value(cf.error_val); printf("\n");
        }
        gc_root_pop(); /* f1 */
        /* (cond (false 1) (true 2)) */
        Value c2a = val_cons(val_symbol("false"), val_cons(val_number(1), val_nil()));
        Value c2b = val_cons(val_symbol("true"),  val_cons(val_number(2), val_nil()));
        Value f2 = val_cons(val_symbol("cond"), val_cons(c2a, val_cons(c2b, val_nil())));
        gc_root_push_value(&f2);
        CatchFrame cf2; cf2.parent = vm_catch_chain; cf2.in_trap_error = 0; vm_catch_chain = &cf2;
        if (setjmp(cf2.buf) == 0) {
            Value out; clo_kmacros(&out, &f2);
            vm_catch_chain = cf2.parent;
            printf("kmacros (cond (false 1) (true 2)) -> "); print_value(out); printf("\n");
        } else {
            vm_catch_chain = cf2.parent;
            printf("kmacros (cond (false 1) (true 2)) THREW: "); print_value(cf2.error_val); printf("\n");
        }
        gc_root_pop(); /* f2 */
        return 0;
    }

    /* --diag <file>: load a .kl file form-by-form via native read-file-raw +
       interp-eval, reporting the first form whose compile throws.  Pinpoints
       native-interp divergences (e.g. core.kl "No condition was true"). */
    if (argc >= 3 && strcmp(argv[1], "--diag") == 0) {
        Value p = val_string(argv[2], (long)strlen(argv[2]));
        gc_root_push_value(&p);
        Value forms; clo_read_file_raw(&forms, &p);
        gc_root_pop();
        gc_root_push_value(&forms);
        int idx = 0;
        int done = 0;
        while (!done) {
            if (forms.tag != VAL_CONS) break;
            Value form = *forms.cons.car;
            Value rest = *forms.cons.cdr;
            idx++;
            CatchFrame cf;
            cf.parent = vm_catch_chain; cf.in_trap_error = 0;
            vm_catch_chain = &cf;
            if (setjmp(cf.buf) == 0) {
                Value out; clo_interp_eval(&out, &form);
                vm_catch_chain = cf.parent;
            } else {
                printf("FORM %d THREW: ", idx);
                print_value(cf.error_val);
                printf("\n  form: "); print_value(form); printf("\n");
                vm_catch_chain = cf.parent;
                done = 1;
            }
            forms = rest;
        }
        gc_root_pop(); /* forms */
        return 0;
    }

    /* 1. Load the Shen OS kernel .kl into the meta-interpreter. */
    if (load_os()) return 1;
    printf("Shen OS loaded into meta-interpreter (native QBE).\n");
    fflush(stdout);

    /* 2. (shen.initialise) through the native interp. */
    {
        Value init_form = val_cons(val_symbol("shen.initialise"), val_nil());
        gc_root_push_value(&init_form);
        Value initr = eval_native(init_form);
        int err = (initr.tag == VAL_ERROR);
        if (err) { printf("shen.initialise -> error: "); print_value(initr); printf("\n"); }
        gc_root_pop();  /* initr (rooted by eval_native) */
        gc_root_pop();  /* init_form */
        if (err) return 1;
    }
    printf("Shen ready.\n\n");
    fflush(stdout);

    /* 3. (shen.repl) through the native interp.  Reads stdin; EOF exits.
       Intercept "error: empty stream" (EOF) to exit cleanly — the same
       repl_mode + repl_exit_jmp mechanism as zincvm.c's --repl.  Without it,
       shen.repl catches the EOF simple-error via trap-error and re-prompts
       forever on an empty stdin. */
    repl_mode = 1;
    if (setjmp(repl_exit_jmp) == 0) {
        Value repl_form = val_cons(val_symbol("shen.repl"), val_nil());
        gc_root_push_value(&repl_form);
        Value rr = eval_native(repl_form);
        (void)rr;
        gc_root_pop();  /* rr */
        gc_root_pop();  /* repl_form */
    }
    repl_mode = 0;

    printf("\nGoodbye.\n");
    return 0;
}

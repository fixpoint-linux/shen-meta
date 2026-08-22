/*
 * wasm-main.c — re-entrant line-eval entrypoint for the shen C VM compiled to
 * WebAssembly (wasm32).  The native zincvm main() drives a BLOCKING meta REPL
 * that loops on fgetc(stdin); blocking fgetc(stdin) does not work in wasm
 * (Node returns EOF immediately on a redirected stream, and a browser has no
 * blocking terminal).  This file instead exposes a synchronous, re-entrant
 * shen_eval_line() that runs the meta REPL's per-line loop body ONCE, so a JS
 * driver (Node harness, or xterm.js onData on Enter) can push input and pull
 * output without ever blocking.
 *
 * It replicates the body of meta_repl() in zincvm.c (lines 2582-2658) using
 * ONLY the public/extern API, because meta_repl/read_stdin_line/print_shen/
 * str_value/call_closure1/call_closure3/is_defun_form are all `static` in
 * zincvm.c and therefore unreachable from a second translation unit.
 *
 * No change to zincvm.c/gc.c runtime semantics: this is a NEW TU linked only
 * into the wasm build, and it does not touch the native zincvm binary.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>
#include <stdint.h>
#include "zincvm.h"   /* Value, ValueArray, val_*, defun_get, vm_exec_env, externs */
#include "gc.h"       /* gc_root_*, gc_in_oldgen, value_references_nursery, gc_dirty_vectors_add */

/* exec_primitive is non-static in zincvm.c (line 963) but NOT declared in
 * zincvm.h — forward-declare it here. */
extern int exec_primitive(const char *name, Value *acc, ValueArray *stack);

/* vm_catch_chain is extern (zincvm.h:80). */

/* ---- minimal ValueArray helpers (va_init/va_free/va_peek are static in
 *      zincvm.c, lines 405-430) ------------------------------------------ */
static void wasm_va_init(ValueArray *a) {
    a->data = GC_VALUE_ARRAY(64);
    a->len = 0; a->cap = 64;
}
static void wasm_va_free(ValueArray *a) { a->data = NULL; a->len = a->cap = 0; }
static void wasm_va_push(ValueArray *a, Value v) {
    /* This file only ever pushes a single argument, so the initial 64-slot
     * capacity is never exceeded; the grow path (with its GC root dance) is
     * therefore unnecessary here. */
    a->data[a->len++] = v;
}

/* ---- faithful copy of str_value() (static in zincvm.c, line 878) -------
 * Renders a Value the way the meta REPL prints results. */
static void wasm_str_value(Value v, char *buf, int *pos, int bufsize, int depth) {
    if (depth > 100) { *pos += snprintf(buf + *pos, bufsize - *pos, "..."); return; }
    switch (v.tag) {
        case VAL_SYMBOL:
            *pos += snprintf(buf + *pos, bufsize - *pos, "%s", v.sym.name);
            break;
        case VAL_STRING:
            *pos += snprintf(buf + *pos, bufsize - *pos, "\"%.*s\"", v.str.len, v.str.data);
            break;
        case VAL_NUMBER:
            *pos += snprintf(buf + *pos, bufsize - *pos, "%ld", v.number);
            break;
        case VAL_BOOLEAN:
            *pos += snprintf(buf + *pos, bufsize - *pos, "%s", v.boolean ? "true" : "false");
            break;
        case VAL_NIL:
            *pos += snprintf(buf + *pos, bufsize - *pos, "[]");
            break;
        case VAL_CONS: {
            Value *cur = &v;
            int first = 1;
            *pos += snprintf(buf + *pos, bufsize - *pos, "[");
            while (cur->tag == VAL_CONS && *pos < bufsize - 1) {
                if (!first) *pos += snprintf(buf + *pos, bufsize - *pos, " ");
                first = 0;
                wasm_str_value(*cur->cons.car, buf, pos, bufsize, depth + 1);
                cur = cur->cons.cdr;
            }
            if (cur->tag != VAL_NIL && *pos < bufsize - 1) {
                *pos += snprintf(buf + *pos, bufsize - *pos, " . ");
                wasm_str_value(*cur, buf, pos, bufsize, depth + 1);
            }
            *pos += snprintf(buf + *pos, bufsize - *pos, "]");
            break;
        }
        case VAL_ERROR:
            *pos += snprintf(buf + *pos, bufsize - *pos, "<error %s>", v.error.message);
            break;
        case VAL_LAMBDA:
            *pos += snprintf(buf + *pos, bufsize - *pos, "<lambda>");
            break;
        case VAL_PRIM:
            *pos += snprintf(buf + *pos, bufsize - *pos, "<prim %s>", v.prim.name);
            break;
        case VAL_VECTOR:
            *pos += snprintf(buf + *pos, bufsize - *pos, "<vector %d>", v.vector.len);
            break;
        case VAL_STREAM:
            *pos += snprintf(buf + *pos, bufsize - *pos, "<stream>");
            break;
        default:
            *pos += snprintf(buf + *pos, bufsize - *pos, "<unknown>");
            break;
    }
}

/* ---- faithful copies of call_closure1 / call_closure3 (static in
 *      zincvm.c, lines 2468 / 2489) ------------------------------------- */
static Value wasm_call_closure1(const char *name, Value arg) {
    Value g = defun_get(name);
    if (g.tag != VAL_LAMBDA) {
        fprintf(stderr, "meta-repl: %s not found in bundle (tag=%d)\n", name, g.tag);
        return val_nil();
    }
    gc_root_push_value(&g);
    gc_root_push_value(&arg);
    int env_len = g.lambda.env_len;
    Value *env = GC_VALUE_ARRAY(env_len + 1);
    if (env_len > 0) memcpy(env, g.lambda.env, env_len * sizeof(Value));
    env[env_len] = arg;
    if (gc_in_oldgen(env) && value_references_nursery(&arg))
        gc_dirty_vectors_add(env);
    gc_root_pop();  /* arg */
    gc_root_pop();  /* g */
    return vm_exec_env(g.lambda.code, g.lambda.code_len, env, env_len + 1);
}

static Value wasm_call_closure3(const char *name, Value a, Value b, Value c) {
    Value g = defun_get(name);
    if (g.tag != VAL_LAMBDA) {
        fprintf(stderr, "meta-repl: %s not found in bundle (tag=%d)\n", name, g.tag);
        return val_nil();
    }
    gc_root_push_value(&g);
    gc_root_push_value(&a);
    gc_root_push_value(&b);
    gc_root_push_value(&c);
    int env_len = g.lambda.env_len;
    Value *env = GC_VALUE_ARRAY(env_len + 3);
    if (env_len > 0) memcpy(env, g.lambda.env, env_len * sizeof(Value));
    env[env_len] = a; env[env_len+1] = b; env[env_len+2] = c;
    if (gc_in_oldgen(env)) {
        if (value_references_nursery(&a)) gc_dirty_vectors_add(env);
        if (value_references_nursery(&b)) gc_dirty_vectors_add(env);
        if (value_references_nursery(&c)) gc_dirty_vectors_add(env);
    }
    gc_root_pop();  /* c */
    gc_root_pop();  /* b */
    gc_root_pop();  /* a */
    gc_root_pop();  /* g */
    return vm_exec_env(g.lambda.code, g.lambda.code_len, env, env_len + 3);
}

/* ---- is_defun_form (static in zincvm.c, line 2515) -------------------- */
static int wasm_is_defun_form(Value f) {
    if (f.tag != VAL_CONS) return 0;
    Value h = *f.cons.car;
    return h.tag == VAL_SYMBOL && strcmp(h.sym.name, "defun") == 0;
}

/* ---- bootstrap (mirrors zincvm.c main(), lines 3068-3081 + bundle load) ----
 * Called once, lazily, on the first shen_eval_line().  Boots the collector,
 * registers the typed GC walkers, and loads the embedded globals.csexp bundle
 * (provided via emcc --embed-file so read_file_or_stdin finds it in MEMFS). */
static int booted = 0;
static int boot_ok = 0;

static void ensure_boot(void) {
    if (booted) return;
    booted = 1;
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));
    init_globals();
    gc_init(256UL * 1024 * 1024);
    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    char *buf = read_file_or_stdin("globals.csexp");
    if (!buf) { fprintf(stderr, "wasm: cannot load globals.csexp\n"); return; }
    int n = vm_load_bundle(buf);
    free(buf);
    if (n == 0) { fprintf(stderr, "wasm: bundle load returned 0 closures\n"); return; }
    boot_ok = 1;
}

/* Exported: ensure the VM is booted (idempotent).  Returns 1 on success. */
int shen_boot(void) {
    ensure_boot();
    return boot_ok;
}

/* Exported: evaluate ONE line of KLambda text (the meta REPL loop body, once).
 *
 *   line    — NUL-terminated KLambda text (e.g. "(+ 1 2)")
 *   out     — caller-provided output buffer (non-NULL, at least outcap bytes)
 *   outcap  — size of out
 *
 * Writes the result (NUL-terminated) into `out` and returns the number of
 * chars written (excluding the NUL), or -1 on a fatal error (boot failure /
 * parse failure is NOT fatal: it is reported in-band via "parse error" text).
 *
 * The returned string is the REPL result ONLY (no "=> " prefix, no prompt,
 * no banner) so the JS side can display it cleanly; the driver is free to
 * prepend its own prompt.  This is the synchronous, non-blocking replacement
 * for meta_repl's fgetc(stdin) loop. */
int shen_eval_line(const char *line, char *out, int outcap) {
    ensure_boot();
    if (!boot_ok) { if (out && outcap > 0) out[0] = '\0'; return -1; }
    if (!out || outcap <= 0) return -1;
    out[0] = '\0';

    int pos = 0;
    if (!line) return 0;

    /* skip blank / whitespace-only lines (matches meta_repl) */
    int only_ws = 1;
    for (const char *p = line; *p; p++)
        if (!isspace((unsigned char)*p)) { only_ws = 0; break; }
    if (only_ws) return 0;

    int n = (int)strlen(line);
    Value Str = val_string(line, n);
    Value Zero = val_number(0);
    Value Len = val_number((long)n);
    Value parsed = wasm_call_closure3("parse-exprs", Str, Zero, Len);
    if (parsed.tag != VAL_CONS || parsed.cons.car->tag != VAL_CONS) {
        pos += snprintf(out + pos, outcap - pos, "parse error");
        return pos;
    }
    Value exprs = *parsed.cons.car;  /* hd of [[Expr|Rest] FinalPos] */

    Value cur = exprs;
    while (cur.tag == VAL_CONS && pos < outcap - 1) {
        Value expr = *cur.cons.car;
        volatile int is_defun = wasm_is_defun_form(expr);

        CatchFrame cf;
        cf.parent = vm_catch_chain; cf.in_trap_error = 0;
        vm_catch_chain = &cf;
        volatile Value result; memset((void*)&result, 0, sizeof(result));
        result.tag = VAL_NIL;
        gc_root_push_value_volatile(&result);
        int err = 0;
        if (setjmp(cf.buf) == 0) {
            if (is_defun) {
                result = wasm_call_closure1("interp-eval", expr);
            } else {
                ValueArray s; wasm_va_init(&s);
                wasm_va_push(&s, expr);
                Value acc; memset(&acc, 0, sizeof(acc));
                exec_primitive("eval-kl", &acc, &s);
                wasm_va_free(&s);
                result = acc;
            }
        } else {
            err = 1;
            result = cf.error_val;
        }
        vm_catch_chain = cf.parent;

        if (is_defun) {
            if (!err && result.tag == VAL_SYMBOL) {
                pos += snprintf(out + pos, outcap - pos, "; registered ");
                wasm_str_value(result, out, &pos, outcap, 0);
            } else {
                pos += snprintf(out + pos, outcap - pos, "; defun registration failed: ");
                wasm_str_value(result, out, &pos, outcap, 0);
            }
        } else {
            wasm_str_value(result, out, &pos, outcap, 0);
        }
        gc_root_pop();  /* result */
        cur = *cur.cons.cdr;
    }
    return pos;
}

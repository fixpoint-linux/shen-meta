/*
 * shensh.c — native frontend for the shensh shell binary (Shen-as-shell).
 *
 * This is a SEPARATE binary from zincvm (the plain KL executor that loads
 * Shen OS via --repl). shensh boots the reduced bundle and runs a Shen
 * shell loop defined in shell/shell.kl (loaded via interp-load-raw).
 *
 * It replicates the GC init/bootstrap/vm_load_bundle sequence from
 * zincvm.c main() using ONLY the public/extern API, because zincvm.c's
 * statics (meta_repl, read_stdin_line, print_shen, call_closure1, etc.)
 * are not reachable from a second translation unit.
 *
 * No change to zincvm.c/gc.c runtime semantics: this is a NEW TU linked
 * only into the shensh binary, and it does not touch the native zincvm.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdarg.h>
#include "zincvm.h"   /* Value, ValueArray, val_*, defun_get, vm_exec_env, externs */
#include "gc.h"       /* gc_root_*, gc_in_oldgen, value_references_nursery, gc_dirty_vectors_add */

/* exec_primitive is non-static in zincvm.c (line 963) but NOT declared in
 * zincvm.h — forward-declare it here. */
extern int exec_primitive(const char *name, Value *acc, ValueArray *stack);

/* vm_catch_chain is extern (zincvm.h:80). */

/* ---- minimal ValueArray helpers (va_init/va_free/va_peek are static in
 *      zincvm.c, lines 405-430) ------------------------------------------ */
static void va_init(ValueArray *a) {
    a->data = GC_VALUE_ARRAY(64);
    a->len = 0; a->cap = 64;
}
static void va_free(ValueArray *a) { a->data = NULL; a->len = a->cap = 0; }
static void va_push(ValueArray *a, Value v) {
    /* This file only ever pushes a single argument, so the initial 64-slot
     * capacity is never exceeded; the grow path (with its GC root dance) is
     * therefore unnecessary here. */
    a->data[a->len++] = v;
}

/* ---- str_value with clamped sv_append (zincvm.c:900) -------------------
 * Renders a Value the way the meta REPL prints results. */
/* Bounds-safe append for str_value: clamp pos exactly like zincvm.c's
   sv_append.  snprintf returns the would-be length; unclamped, pos runs past
   bufsize once the buffer fills and the next buf+*pos write is OOB with a
   negative->huge size. */
static void sv_append(char *buf, int *pos, int bufsize, const char *fmt, ...) {
    if (bufsize <= 0 || *pos >= bufsize - 1) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + *pos, bufsize - *pos, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    int room = bufsize - 1 - *pos;
    *pos += (n > room) ? room : n;
}

static void str_value(Value v, char *buf, int *pos, int bufsize, int depth) {
    if (depth > 100) { sv_append(buf, pos, bufsize, "..."); return; }
    switch (v.tag) {
        case VAL_SYMBOL:
            sv_append(buf, pos, bufsize, "%s", v.sym.name);
            break;
        case VAL_STRING:
            sv_append(buf, pos, bufsize, "\"%.*s\"", v.str.len, v.str.data);
            break;
        case VAL_NUMBER:
            sv_append(buf, pos, bufsize, "%ld", v.number);
            break;
        case VAL_BOOLEAN:
            sv_append(buf, pos, bufsize, "%s", v.boolean ? "true" : "false");
            break;
        case VAL_NIL:
            sv_append(buf, pos, bufsize, "[]");
            break;
        case VAL_CONS: {
            Value *cur = &v;
            int first = 1;
            sv_append(buf, pos, bufsize, "[");
            while (cur->tag == VAL_CONS && *pos < bufsize - 1) {
                if (!first) sv_append(buf, pos, bufsize, " ");
                first = 0;
                str_value(*cur->cons.car, buf, pos, bufsize, depth + 1);
                cur = cur->cons.cdr;
            }
            if (cur->tag != VAL_NIL && *pos < bufsize - 1) {
                sv_append(buf, pos, bufsize, " . ");
                str_value(*cur, buf, pos, bufsize, depth + 1);
            }
            sv_append(buf, pos, bufsize, "]");
            break;
        }
        case VAL_ERROR:
            sv_append(buf, pos, bufsize, "<error %s>", v.error.message);
            break;
        case VAL_LAMBDA:
            sv_append(buf, pos, bufsize, "<lambda>");
            break;
        case VAL_PRIM:
            sv_append(buf, pos, bufsize, "<prim %s>", v.prim.name);
            break;
        case VAL_VECTOR:
            sv_append(buf, pos, bufsize, "<vector %d>", v.vector.len);
            break;
        case VAL_STREAM:
            sv_append(buf, pos, bufsize, "<stream>");
            break;
        default:
            sv_append(buf, pos, bufsize, "<unknown>");
            break;
    }
}

/* ---- print_shen (zincvm.c:3019) ---------------------------------------
 * Print a Shen-style representation of a value (uses str_value). */
static void print_shen(Value v) {
    /* Grow-until-fits: str_value clamps pos at bufsize-1 when truncated,
       so pos < cap-1 means the full representation fit.  Shell output can
       be arbitrarily large (file dumps), so no fixed cap. */
    int cap = 4096;
    char *pbuf = malloc(cap);
    if (!pbuf) { printf("<oom>\n"); fflush(stdout); return; }
    int pos = 0;
    for (;;) {
        pos = 0;
        str_value(v, pbuf, &pos, cap, 0);
        if (pos < cap - 1) break;
        cap *= 2;
        char *nb = realloc(pbuf, cap);
        if (!nb) { free(pbuf); printf("<oom>\n"); fflush(stdout); return; }
        pbuf = nb;
    }
    pbuf[pos] = '\0';
    printf("%s\n", pbuf);
    fflush(stdout);
    free(pbuf);
}

/* ---- read_stdin_line (zincvm.c:3060) -----------------------------------
 * Read one line from stdin (malloc'd buffer, caller must free). */
static char *read_stdin_line(void) {
    size_t cap = 128;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    size_t len = 0;
    for (;;) {
        int c = getchar();
        if (c == EOF) {
            if (len == 0) { free(buf); return NULL; }
            break;
        }
        if (c == '\n') break;
        if (len + 1 >= cap) {
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
        }
        buf[len++] = (char)c;
    }
    buf[len] = '\0';
    return buf;
}

/* ---- eval_form1: build [fn arg] and run exec_primitive("eval-kl") -------
 * Mirrors the convention used in eval-kl: the form is placed on the stack
 * and exec_primitive("eval-kl") resolves it through the metacircular interp
 * (namespace 2: interp-load-raw'd shell defuns are NOT in the C defun_table). */
static Value eval_form1(const char *fn, Value arg) {
    Value f = val_symbol(fn);
    Value form = val_cons(f, val_cons(arg, val_nil()));
    gc_root_push_value(&form);
    ValueArray s;
    s.data = GC_VALUE_ARRAY(1);
    s.len = 0; s.cap = 1;
    va_push(&s, form);
    Value acc;
    exec_primitive("eval-kl", &acc, &s);
    gc_root_pop();
    return acc;
}

/* ---- call_bundled_1: call a single-argument BUNDLED closure by name ----
 * Exact port of zinctest.c's call_bundled_1.  Reaches a closure in the C
 * global_table (namespace 1) directly via defun_get + vm_exec_env — this is
 * how the self-hosting tests drive interp-load-raw.  eval_kl CANNOT do this
 * (it resolves [global G] via the metacircular interp's namespace-2
 * lookup-global, which is empty for bundled closures).  Used to bootstrap
 * the shell source. */
static Value call_bundled_1(const char *name, Value arg) {
    Value fn = defun_get(name);
    if (fn.tag != VAL_LAMBDA) return val_nil();
    gc_root_push_value(&fn);
    gc_root_push_value(&arg);
    Value *env = GC_VALUE_ARRAY(fn.lambda.env_len + 1);
    if (fn.lambda.env_len > 0)
        memcpy(env, fn.lambda.env, fn.lambda.env_len * sizeof(Value));
    env[fn.lambda.env_len] = arg;
    if (gc_in_oldgen(env) && value_references_nursery(&arg))
        gc_dirty_vectors_add(env);
    CatchFrame cf;
    cf.parent = vm_catch_chain;
    cf.in_trap_error = 0;
    vm_catch_chain = &cf;
    Value result;
    if (setjmp(cf.buf)) {
        vm_catch_chain = cf.parent;
        gc_root_push_value(&cf.error_val);
        result = cf.error_val;
        gc_root_pop();
        gc_root_pop();  /* arg */
        gc_root_pop();  /* fn */
        return result;
    }
    result = vm_exec_env(fn.lambda.code, fn.lambda.code_len, env, fn.lambda.env_len + 1);
    vm_catch_chain = cf.parent;
    gc_root_push_value(&result);   /* root result before popping args */
    gc_root_pop();                 /* result */
    gc_root_pop();                 /* arg */
    gc_root_pop();                 /* fn */
    return result;
}

/* ---- call_closure3: call a bundled closure with three args (parse-exprs
 *      Str Pos Len).  Same namespace-1 defun_get convention as the others. */
static Value call_closure3(const char *name, Value a, Value b, Value c) {
    Value g = defun_get(name);
    if (g.tag != VAL_LAMBDA) return val_nil();
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

/* Is a parsed form a (defun ...) definition? */
static int is_defun_form(Value f) {
    if (f.tag != VAL_CONS) return 0;
    Value h = *f.cons.car;
    return h.tag == VAL_SYMBOL && strcmp(h.sym.name, "defun") == 0;
}

/* Evaluate a KLambda form via the eval-kl primitive (namespace 2 resolution). */
static Value eval_kl_form(Value form) {
    ValueArray s; s.data = GC_VALUE_ARRAY(1); s.len = 0; s.cap = 1;
    va_push(&s, form);
    Value acc; memset(&acc, 0, sizeof(acc));
    exec_primitive("eval-kl", &acc, &s);
    return acc;
}

/* Does the line (after leading whitespace) start with '(' ?  If so it is a
 * KLambda expression and shensh evaluates it through parse-exprs + eval-kl
 * (the meta_repl path, in C) rather than treating it as a shell command. */
static int line_is_klambda(const char *line) {
    while (*line && isspace((unsigned char)*line)) line++;
    return *line == '(';
}

/* Evaluate a whole KLambda line (possibly several forms) via parse-exprs +
 * eval-kl, printing each form's result.  Returns 1 if the line was handled. */
static void eval_klambda_line(const char *line, int linelen) {
    Value Str = val_string(line, linelen);
    Value Zero = val_number(0);
    Value Len = val_number((long)linelen);

    CatchFrame cf_parse;
    cf_parse.parent = vm_catch_chain; cf_parse.in_trap_error = 0;
    vm_catch_chain = &cf_parse;
    volatile Value parsed; memset((void*)&parsed, 0, sizeof(parsed));
    parsed.tag = VAL_NIL;
    gc_root_push_value_volatile(&parsed);
    int parse_err = 0;
    if (setjmp(cf_parse.buf) == 0) {
        parsed = call_closure3("parse-exprs", Str, Zero, Len);
    } else {
        parse_err = 1;
        parsed = cf_parse.error_val;
    }
    vm_catch_chain = cf_parse.parent;
    gc_root_pop();

    if (parse_err || parsed.tag != VAL_CONS || parsed.cons.car->tag != VAL_CONS) {
        printf("parse error: "); print_shen(parsed); printf("\n");
        return;
    }
    Value exprs = *parsed.cons.car;  /* hd of [[Expr|Rest] FinalPos] */
    Value cur = exprs;
    while (cur.tag == VAL_CONS) {
        Value expr = *cur.cons.car;
        volatile int is_defun = is_defun_form(expr);

        CatchFrame cf;
        cf.parent = vm_catch_chain; cf.in_trap_error = 0;
        vm_catch_chain = &cf;
        volatile Value result; memset((void*)&result, 0, sizeof(result));
        result.tag = VAL_NIL;
        gc_root_push_value_volatile(&result);
        int err = 0;
        if (setjmp(cf.buf) == 0) {
            if (is_defun) {
                result = call_bundled_1("interp-eval", expr);
            } else {
                result = eval_kl_form(expr);
            }
        } else {
            err = 1;
            result = cf.error_val;
        }
        vm_catch_chain = cf.parent;

        if (is_defun) {
            if (!err && result.tag == VAL_SYMBOL) { printf("; registered "); print_shen(result); }
            else { printf("; defun registration failed: "); print_shen(result); }
        } else {
            printf("=> "); print_shen(result);
        }
        gc_root_pop();  /* result */
        cur = *cur.cons.cdr;
    }
}

/* ---- main() ----------------------------------------------------------- */
int main(int argc, char **argv) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));
    init_globals();
    gc_init(256UL * 1024 * 1024);
    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    const char *bundle = argc > 1 ? argv[1] : "globals.csexp";
    char *src = read_file_or_stdin(bundle);
    if (!src || vm_load_bundle(src) == 0) {
        fprintf(stderr, "shensh: cannot load bundle %s\n", bundle);
        return 1;
    }
    free(src);

    /* Boot the shell source via the bundled interp-load-raw closure (C
       namespace 1 — reached directly, not through eval-kl).  This registers
       the shell defuns (sh-prompt, shell-eval-line, ...) into the Shen
       global-table (namespace 2), where the per-line eval-kl CAN find them. */
    Value boot = call_bundled_1("interp-load-raw", val_string("shell/shell.kl", (long)strlen("shell/shell.kl")));
    if (boot.tag != VAL_SYMBOL || strcmp(boot.sym.name, "loaded") != 0) {
        fprintf(stderr, "shensh: warning: failed to load shell/shell.kl (got ");
        print_shen(boot);
        fprintf(stderr, ") — continuing without shell\n");
    }

    /* REPL loop: prompt via eval_form1("sh-prompt", val_string("",0)) → print + read_stdin_line();
       each line → eval_form1("shell-eval-line", val_string(line, n)) → print_shen(result);
       wrap per-line in a CatchFrame exactly like meta_repl (zincvm.c:3086-3116) with
       gc_root_push_value_volatile(&result). EOF or *sh-exit* → break. */
    while (1) {
        Value prompt = eval_form1("sh-prompt", val_string("", 0));
        if (prompt.tag == VAL_ERROR) {
            fprintf(stderr, "shensh: prompt error: ");
            print_shen(prompt);
            break;
        }
        print_shen(prompt);
        fflush(stdout);

        char *line = read_stdin_line();
        if (!line) break;  /* EOF */

        /* skip blank / whitespace-only lines */
        int only_ws = 1;
        for (char *p = line; *p; p++) {
            if (!isspace((unsigned char)*p)) { only_ws = 0; break; }
        }
        if (only_ws) {
            free(line);
            continue;
        }

        /* KLambda expression lines (start with '(') go through the C
           parse-exprs + eval-kl path (meta_repl style) — parse-exprs is a
           namespace-1 bundled closure, unreachable from interpreted code. */
        if (line_is_klambda(line)) {
            eval_klambda_line(line, (int)strlen(line));
            free(line);
            continue;
        }

        /* Otherwise: a shell command line, handled by shell.kl. */
        Value result = eval_form1("shell-eval-line", val_string(line, (long)strlen(line)));
        free(line);

        if (result.tag == VAL_ERROR) {
            fprintf(stderr, "shensh: eval error: ");
            print_shen(result);
        } else {
            print_shen(result);
            /* Check if result signals exit to terminate the shell (either the
               symbol `exit` or the string "exit", returned by sh-builtin's
               exit branch after setting *sh-exit*). */
            int is_exit = (result.tag == VAL_SYMBOL && strcmp(result.sym.name, "exit") == 0) ||
                          (result.tag == VAL_STRING && result.str.len == 4 &&
                           memcmp(result.str.data, "exit", 4) == 0);
            if (is_exit) {
                break;
            }
        }
    }

    return 0;
}

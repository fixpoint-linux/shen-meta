/*
 * shensh.c — native frontend for the shensh shell binary (Shen-as-shell).
 *
 * This is a SEPARATE binary from zincvm (the plain KL executor that loads
 * Shen OS via --repl). shensh boots the reduced bundle and runs a Shen
 * shell loop defined in shell/shell.shen (typed Shen, loaded via
 * shen_load_source, which type-checks it with the bundled HM checker).
 *
 * It replicates the GC init/bootstrap/vm_load_bundle sequence from
 * zincvm.c main() using ONLY the public/extern API, because zincvm.c's
 * statics (meta_repl, read_stdin_line, print_shen, call_closure1, etc.)
 * are not reachable from a second translation unit.
 *
 * Boot: shensh.c boots globals.csexp, initialises the bundled HM checker
 * (tc-hm-init), then loads the shell in dependency order —
 * shell/shlex.shen, shell/shparse.shen, shell/shexpand.shen,
 * shell/shell.shen — each via shen_load_source (read -> HM-check ->
 * compile -> interp-eval into namespace 2).  Command lines are parsed and
 * expanded in Shen and executed by the C exec-plan primitive (fork/dup2/
 * execvp); /bin/sh is never invoked anywhere.
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

/* ---- print_raw_string (shpar-p2 U5) --------------------------------------
 * Print a VAL_STRING result RAW — fwrite the exact bytes, no quotes or
 * escaping: shell command output must appear exactly as the child wrote it
 * (this REPLACES quoted print_shen for command output; print_shen stays
 * for errors and non-string results).  When ensure_nl is set and the
 * output is non-empty without a trailing newline, one is added (the REPL
 * is line-oriented).  The prompt path passes ensure_nl=0 so the prompt
 * and the user's typed input share a line. */
static void print_raw_string_ex(Value v, int ensure_nl) {
    if (v.tag != VAL_STRING) { print_shen(v); return; }
    if (v.str.len > 0) fwrite(v.str.data, 1, v.str.len, stdout);
    if (ensure_nl && v.str.len > 0 && v.str.data[v.str.len - 1] != '\n')
        fputc('\n', stdout);
    fflush(stdout);
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
 * (namespace 2: shen_load_source'd shell defuns are NOT in the C defun_table). */
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

/* ---- call_bundled_0: call a nullary BUNDLED closure by name -----------------
 * Same namespace-1 defun_get + vm_exec_env convention as call_bundled_1, but
 * for { --> T } nullary closures (e.g. tc-hm-init).  Mirrors the --tc-hm driver
 * in zincvm.c (defun_get, VAL_LAMBDA check, env_len+1 slot with a val_number(0)
 * dummy operand, CatchFrame around vm_exec_env).  On a throw the error value is
 * caught and returned (caller decides whether to warn/abort).  If the named
 * closure is missing from the bundle, returns val_nil() (tag != VAL_LAMBDA and
 * != VAL_SYMBOL), so callers can distinguish "missing" from "returned done". */
static Value call_bundled_0(const char *name) {
    Value fn = defun_get(name);
    if (fn.tag != VAL_LAMBDA) return val_nil();
    gc_root_push_value(&fn);
    Value *env = GC_VALUE_ARRAY(fn.lambda.env_len + 1);
    if (fn.lambda.env_len > 0)
        memcpy(env, fn.lambda.env, fn.lambda.env_len * sizeof(Value));
    env[fn.lambda.env_len] = val_number(0);   /* dummy slot, see --tc-hm driver */
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
        gc_root_pop();  /* fn */
        return result;
    }
    result = vm_exec_env(fn.lambda.code, fn.lambda.code_len, env, fn.lambda.env_len + 1);
    vm_catch_chain = cf.parent;
    gc_root_pop();  /* fn */
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

/* Evaluate a KLambda form via the eval-kl primitive (namespace 2 resolution).
 * The form MUST stay rooted: GC_VALUE_ARRAY(1) below and the whole eval-kl
 * chain (extract-kl -> kl->zinc -> toplevel-interp) allocate, and an unrooted
 * form goes stale after any collection.  That was the REPL fragility: some
 * nested prim-call forms compiled from garbage ("zinc-c: unknown expression"
 * / "No condition was true") and could SEGV afterwards.  volatile +
 * shadow-stack root, mirroring eval_form1 / the parsed/result discipline. */
static Value eval_kl_form(Value form) {
    volatile Value f = form;
    gc_root_push_value_volatile(&f);
    ValueArray s; s.data = GC_VALUE_ARRAY(1); s.len = 0; s.cap = 1;
    va_push(&s, f);
    Value acc; memset(&acc, 0, sizeof(acc));
    exec_primitive("eval-kl", &acc, &s);
    gc_root_pop();
    return acc;
}

/* ---- boot globals for the shell positional parameters ----
 * These MUST be stored through the interpreter's own (set X V) path —
 * eval_kl_form on a (set ...) KLambda form — and NOT via the raw C
 * value_set().  The interp's [prim set] rule passes the interpreter's TAGGED
 * value representation ([string S] / [number N] cons cells) to the C set
 * primitive, so anything set by interpreted code (including the REPL) lands
 * TAGGED in the C values table; the interp's [prim value] rule then returns
 * that tagged form as the accumulator, which is what downstream interp rules
 * ([prim string?], [prim cons?], ...) pattern-match.  A raw C VAL_STRING
 * written by value_set reads back UNtagged and every tagged-pattern rule
 * misclassifies it (the observed failure: shell/shexpand.shen's shx-argv0 /
 * shx-flags / shx-posargs always fell to their defaults, so $0/$-/$1.. never
 * expanded, while REPL (set ...) values expanded fine).  Storing through
 * eval-kl lands exactly what a REPL (set ...) lands, which the shell sources
 * already read correctly. */
static void boot_set_kl_string(const char *name, const char *sval) {
    /* (set <name> "<sval>") */
    Value form = val_cons(val_symbol("set"),
                    val_cons(val_symbol(name),
                      val_cons(val_string(sval, (long)strlen(sval)),
                               val_nil())));
    gc_root_push_value(&form);
    eval_kl_form(form);
    gc_root_pop();
}

static void boot_set_kl_posargs(char **args, int n) {
    /* (set *sh-posargs* (cons "a1" (cons "a2" ... ()))) — built
       right-to-left so the form is ordinary KLambda the eval-kl compiler
       handles (cons is a primitive; () compiles to emptylist). */
    Value tail = val_nil();
    gc_root_push_value(&tail);
    for (int i = n - 1; i >= 0; i--) {
        Value s = val_string(args[i], (long)strlen(args[i]));
        gc_root_push_value(&s);   /* s live across the cons allocs below */
        Value cell = val_cons(val_symbol("cons"),
                              val_cons(s, val_cons(tail, val_nil())));
        gc_root_pop();            /* s */
        tail = cell;
    }
    Value form = val_cons(val_symbol("set"),
                    val_cons(val_symbol("*sh-posargs*"),
                             val_cons(tail, val_nil())));
    gc_root_push_value(&form);
    eval_kl_form(form);
    gc_root_pop();                /* form */
    gc_root_pop();                /* tail */
}

/* *sh-exit-code* is stored by shell.shen (sh-run-plan) through the interp's
 * (set ...), so the C values-table entry is the interpreter's TAGGED
 * [number N] cons, not a raw VAL_NUMBER.  Unwrap either form. */
static long sh_exit_code_num(void) {
    Value code = value_get("*sh-exit-code*");
    if (code.tag == VAL_NUMBER) return (long)code.number;
    if (code.tag == VAL_CONS) {
        Value h = *code.cons.car;
        if (h.tag == VAL_SYMBOL && strcmp(h.sym.name, "number") == 0) {
            Value rest = *code.cons.cdr;   /* the (N) tail of [number N] */
            if (rest.tag == VAL_CONS) {
                Value num = *rest.cons.car;
                if (num.tag == VAL_NUMBER) return (long)num.number;
            }
        }
    }
    return 0;
}

/* ---- shen_load_source: run a REAL Shen source file through the bundled
 *      subset-Shen compiler.  Mirrors serialize-reduced.shen's shen-load:
 *
 *      shen-load Path = (shen-eval-forms (shen->kl-forms (shen-read-file Path)))
 *
 *   All stages are BUNDLED closures in namespace 1 (C defun_table), reached
 *   via call_bundled_1 (NOT eval-kl, which resolves namespace 2 and would say
 *   'global not found').  shen-read-file parses .shen source into forms;
 *   shen->kl-forms compiles each form (define/pattern/guards/cond) to KLambda
 *   defuns; interp-eval registers each into the interp's namespace-2
 *   global-table so eval-kl can call them.  This is how the shell runs actual
 *   Shen source, not just flat KLambda.
 *
 *   TYPE-CHECK BY DEFAULT: before compiling, the bundled Hindley-Milner
 *   checker (tc-hm-file Path -> (list tc-result)) is run on the source.  Each
 *   define's result is [ok Name] (pass) or [fail Reason] (fail).  Any FAIL
 *   aborts the load (returns the fail reason) — the shell refuses to load
 *   ill-typed source rather than relying on runtime catch-alls.  Defines
 *   without a { ... --> ... } signature report "no type signature, skipping"
 *   as a fail (the checker does not infer top-level sigs yet).
 *
 *   Returns a symbol result ('loaded' on success, or an error symbol/Value);
 *   individual form failures are tolerated (each interp-eval is independent). */
static Value shen_load_source_ex(const char *path, int verbose) {
    /* stage 0: read the file into forms ONCE, then type-check.  (Previously
       tc-hm-file read the file internally and stage 1 below read it AGAIN;
       the second shen-read-file call was observed truncating the form list
       for some inputs — heap-state-dependent corruption in the native read
       path — while the first read in the pair is always clean.  Read once,
       then hand the SAME forms list to the type checker (tc-hm-forms) and
       the compiler (shen->kl-forms).)
       When verbose is set (the `shen-load` shell command) each define's
       [ok Name]/[fail Reason] is printed; when clear (boot) the check runs
       silently and only the final fail reason is returned on error. */
    Value p = val_string(path, (long)strlen(path));
    gc_root_push_value(&p);
    Value forms = call_bundled_1("shen-read-file", p);
    gc_root_pop();  /* p */
    if (forms.tag != VAL_CONS) {
        return val_symbol("shen-load: read failed");
    }
    gc_root_push_value(&forms);
    Value tcs = call_bundled_1("tc-hm-forms", forms);
    gc_root_push_value(&tcs);
    Value fail_res = val_nil();
    gc_root_push_value(&fail_res);
    if (tcs.tag == VAL_CONS) {
        Value r = tcs;
        int any_fail = 0;
        while (r.tag == VAL_CONS) {
            Value res = *r.cons.car;
            /* res is [ok Name] or [fail Reason] */
            int is_fail = 0;
            if (res.tag == VAL_CONS) {
                Value h = *res.cons.car;
                if (h.tag == VAL_SYMBOL && strcmp(h.sym.name, "fail") == 0) {
                    is_fail = 1;
                    fail_res = *(*res.cons.cdr).cons.car;
                }
            }
            if (verbose) print_shen(res);
            if (is_fail) any_fail = 1;
            r = *r.cons.cdr;
        }
        if (any_fail) {
            gc_root_pop();  /* fail_res */
            gc_root_pop();  /* tcs */
            gc_root_pop();  /* forms */
            return fail_res;
        }
    }
    gc_root_pop();  /* fail_res */
    gc_root_pop();  /* tcs */

    /* stage 2: compile Shen source forms -> KLambda defuns.  shen-read-file
       (the .shen extended reader) groups { A --> B } type sigs into one
       element so shen->kl's strip-sig can remove them, and handles
       [X | Rest] list syntax; the forms list is the one read in stage 0. */
    Value kls = call_bundled_1("shen->kl-forms", forms);
    gc_root_push_value(&kls);
    if (kls.tag != VAL_CONS && kls.tag != VAL_NIL) {
        gc_root_pop(); gc_root_pop();
        return val_symbol("shen-load: compile failed");
    }

    /* stage 3: register each defun into namespace 2 via interp-eval.
       interp-eval returns the defun's Name symbol on success, the form
       unchanged (e.g. shen.skip from a (tc -) line) for non-defun forms, or
       throws (caught by call_bundled_1 -> VAL_ERROR) if a defun fails to
       compile.  Individual form failures are tolerated (the loop continues),
       mirroring shen-eval-forms.  We return symbol 'loaded' when the final
       form did not error (success), or the error value if it did -- so the
       boot check can distinguish a clean load from a compile failure. */
    Value cur = kls;
    Value last = val_symbol("loaded");
    gc_root_push_value(&last);
    /* cur must stay rooted across interp-eval: it allocates (compiles the
       defun, updates the namespace-2 global-table), and a GC there would
       move the cons cell cur points at, leaving cur stale -> subsequent
       defuns silently dropped (the "missing define" corruption). */
    gc_root_push_value(&cur);
    while (cur.tag == VAL_CONS) {
        Value defun = *cur.cons.car;
        gc_root_push_value(&defun);
        last = call_bundled_1("interp-eval", defun);
        gc_root_pop();
        cur = *cur.cons.cdr;
    }
    gc_root_pop();  /* cur */
    gc_root_pop();  /* last */
    Value ret = (last.tag == VAL_ERROR) ? last : val_symbol("loaded");
    gc_root_pop();  /* kls */
    gc_root_pop();  /* forms */
    return ret;
}

/* Default verbose wrapper for the `shen-load` shell command: prints each
   define's type-check result.  Boot uses shen_load_source_ex(.., 0). */
static Value shen_load_source(const char *path) {
    return shen_load_source_ex(path, 1);
}

/* Does the line (after leading whitespace) start with '(' ?  If so it is
 * EITHER a KLambda expression (shensh evaluates it through parse-exprs +
 * eval-kl, the meta_repl path, in C) or a SHELL SUBSHELL — the grammar
 * from shpar-p2 treats '(' at command position as a subshell
 * ((cd /; pwd), (ls | head), ...).  KLambda has no ; | & operators, so a
 * '(' line containing any of those outside quotes is a subshell, not
 * KLambda.  A bare (cd /) with no chain/pipeline still parses as KLambda
 * (KLambda probe) — documented v1 divergence. */
static int line_is_klambda(const char *line) {
    while (*line && isspace((unsigned char)*line)) line++;
    if (*line != '(') return 0;
    int q = 0;   /* 0 = unquoted, '\'' or '"' inside quotes */
    for (const char *p = line; *p; p++) {
        if (q == '\'')      { if (*p == '\'') q = 0; }
        else if (q == '"')  { if (*p == '"')  q = 0; }
        else {
            if (*p == '\'') q = '\'';
            else if (*p == '"') q = '"';
            else if (*p == ';' || *p == '|' || *p == '&') return 0;
        }
    }
    return 1;
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
    /* cur must stay rooted across each form's eval: eval_kl_form /
       call_bundled_1 allocate (compile + interp + global-table update), and
       the exprs spine cells were only reachable through `parsed`'s root,
       which was popped above — a collection mid-loop left cur pointing at
       dead/moved cells, so the NEXT form was compiled from garbage (the
       observed multi-error batches and SEGV-after-failed-compile).  volatile:
       cur is live across the setjmp inside the loop. */
    volatile Value cur = exprs;
    gc_root_push_value_volatile(&cur);
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
    gc_root_pop();  /* cur */
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

    /* Initialise the HM type-checker state ONCE, BEFORE the shell sources
       load, so their boot-time tc-hm-forms checks are real (with the prim
       table built).  tc-hm-init (shen/tc-hm-runtime.shen) builds
       tc-prim-table (via tc-build-prim-table) and zeroes the tc-* counters
       and tc-global-sig-table.  Without this, tc-prim-lookup returns a
       fresh unknown tvar for every prim and body/arg type errors silently
       pass (only direct-return mismatches are caught).  Running it first
       also means tc-global-sig-table accumulates across the boot loads —
       the shell files load in dependency order (shlex -> shparse ->
       shexpand -> shell) so later files see earlier files' sigs.  A
       missing/failed init is non-fatal — warn and continue. */
    Value tcinit = call_bundled_0("tc-hm-init");
    if (tcinit.tag != VAL_SYMBOL || strcmp(tcinit.sym.name, "done") != 0) {
        fprintf(stderr, "shensh: warning: tc-hm-init did not complete (got ");
        print_shen(tcinit);
        fprintf(stderr, ") — type-checker may be uninitialised; continuing\n");
    }

    /* Boot the shell sources via shen_load_source (read -> HM-check ->
       shen->kl compile -> interp-eval into namespace 2, where eval_form1 /
       eval-kl reach).  Dependency order matters: shparse uses shlex's
       sp-prepend-list; shexpand uses the sp-* string helpers; shell.shen
       (the driver) calls sp-lex/sp-parse/shx-plan — each file's defines
       land in tc-global-sig-table as it loads, so HM cross-file sigs work.
       Each load is warn-and-continue: KLambda lines and shen-load still
       work without the shell grammar, though shell commands would fail. */
    static const char *const boot_files[] = {
        "shell/shlex.shen",
        "shell/shparse.shen",
        "shell/shexpand.shen",
        "shell/shell.shen",
    };
    for (size_t bi = 0; bi < sizeof boot_files / sizeof boot_files[0]; bi++) {
        Value boot = shen_load_source_ex(boot_files[bi], 0);
        if (boot.tag != VAL_SYMBOL || strcmp(boot.sym.name, "loaded") != 0) {
            fprintf(stderr, "shensh: warning: failed to load %s (got ",
                    boot_files[bi]);
            print_shen(boot);
            fprintf(stderr, ") — continuing without it\n");
        }
    }

    /* ---- positional-parameter globals ($0 $1..$9 $# $@ $* $$ $! $-,
       expanded by shell/shexpand.shen).  Set BEFORE any line runs:
         *sh-argv0*   = how the shell was invoked: argv[0]; in -c mode the
                        first operand after the command string when given
                        (bash convention: that operand names $0 and the
                        remaining operands are $1..$9).
         *sh-posargs*  = list of positional-arg strings (empty interactive).
         *sh-flags*    = $- option flags: "i" interactive, "c" -c mode —
                        the only two states shensh actually has.
       Stored via eval_kl_form (see boot_set_kl_* above) so the values land
       in the interpreter's TAGGED representation — a raw value_set() write
       is invisible to the shell sources' [prim string?]/[prim cons?]
       readers and $0/$-/$1.. silently fall to their defaults. */
    const char *cmd_string = NULL;   /* -c MODE: the command string */
    char **pos_args = NULL; int n_pos_args = 0;
    const char *argv0 = argv[0];
    if (argc > 3 && strcmp(argv[2], "-c") == 0) {
        cmd_string = argv[3];
        int first_pos = 4;
        if (argc > 4) { argv0 = argv[4]; first_pos = 5; }
        pos_args = &argv[first_pos];
        n_pos_args = argc - first_pos;
    } else if (argc > 2 && strcmp(argv[2], "-c") == 0) {
        fprintf(stderr, "shensh: -c requires a command string\n");
        return 2;
    }
    boot_set_kl_string("*sh-argv0*", argv0);
    boot_set_kl_string("*sh-flags*", cmd_string ? "c" : "i");
    boot_set_kl_posargs(pos_args, n_pos_args);

    if (cmd_string) {
        /* -c MODE: run the ONE command string through the same
           shell-eval-line path the REPL uses (no prompt), print its output
           raw, and exit with the last command's exit status (POSIX sh -c).
           The result stays rooted while printed. */
        volatile Value cresult; memset((void *)&cresult, 0, sizeof(cresult));
        cresult.tag = VAL_NIL;
        gc_root_push_value_volatile(&cresult);
        cresult = eval_form1("shell-eval-line",
                             val_string(cmd_string, (long)strlen(cmd_string)));
        if (cresult.tag == VAL_ERROR) {
            fprintf(stderr, "shensh: ");
            print_shen(cresult);
            gc_root_pop();
            return 126;
        }
        if (cresult.tag == VAL_SYMBOL &&
            strcmp(cresult.sym.name, "sh-continue") == 0) {
            fprintf(stderr, "shensh: heredoc: unexpected EOF\n");
            gc_root_pop();
            return 1;
        }
        print_raw_string_ex(cresult, 1);
        gc_root_pop();
        return (int)sh_exit_code_num();
    }

    /* REPL loop: prompt via eval_form1("sh-prompt", val_string("",0)) → read_stdin_line();
       each line → eval_form1("shell-eval-line", val_string(line, n));
       VAL_STRING results print RAW (command output — no quotes); symbol
       sh-continue enters the heredoc accumulate loop (see below); print_shen
       stays for errors and non-string results.  Wrap per-line in a CatchFrame
       exactly like meta_repl (zincvm.c:3086-3116) with the result rooted
       (volatile + shadow stack) across any heredoc re-evaluation.
       EOF or *sh-exit* → break. */
    while (1) {
        Value prompt = eval_form1("sh-prompt", val_string("", 0));
        if (prompt.tag == VAL_ERROR) {
            fprintf(stderr, "shensh: prompt error: ");
            print_shen(prompt);
            break;
        }
        print_raw_string_ex(prompt, 0);   /* raw prompt, no newline */

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

        /* `shen-load <path>` builtin (handled in C so it can reach the
           namespace-1 bundled Shen compiler): load a real .shen source file
           into namespace 2, exactly like shen-load in serialize-reduced.shen. */
        if (strncmp(line, "shen-load", 9) == 0 && (line[9] == ' ' || line[9] == '\t')) {
            const char *p = line + 9;
            while (*p == ' ' || *p == '\t') p++;
            Value r = shen_load_source(p);
            print_shen(r);
            free(line);
            continue;
        }

        /* Otherwise: a shell command line, handled by shell/shell.shen.
           The result stays rooted (volatile + shadow stack) across the
           heredoc re-evaluations below — each eval_form1 allocates. */
        volatile Value result; memset((void *)&result, 0, sizeof(result));
        result.tag = VAL_NIL;
        gc_root_push_value_volatile(&result);
        result = eval_form1("shell-eval-line", val_string(line, (long)strlen(line)));

        /* Heredoc continuation: shell-eval-line returned the symbol
           sh-continue — the line ends inside an unterminated heredoc.
           Read further lines, buffer = buffer + "\n" + line, and re-eval
           the whole buffer until the delimiter closes (the lexer/parser
           stay on the Shen side; this loop never parses).  Blank lines
           are legitimate heredoc body, so nothing is skipped here.
           EOF while still pending is an error and resets the buffer. */
        while (result.tag == VAL_SYMBOL &&
               strcmp(result.sym.name, "sh-continue") == 0) {
            printf("> "); fflush(stdout);
            char *more = read_stdin_line();
            if (!more) {
                fprintf(stderr, "shensh: heredoc: unexpected EOF\n");
                result = val_string("", 0);
                break;
            }
            size_t nlen = strlen(line) + 1 + strlen(more) + 1;
            char *nb = (char *)malloc(nlen);
            if (!nb) {
                free(more);
                fprintf(stderr, "shensh: out of memory\n");
                result = val_string("", 0);
                break;
            }
            snprintf(nb, nlen, "%s\n%s", line, more);
            free(line);
            line = nb;
            free(more);
            result = eval_form1("shell-eval-line",
                                val_string(line, (long)strlen(line)));
        }
        free(line);

        int is_exit = 0;
        if (result.tag == VAL_ERROR) {
            fprintf(stderr, "shensh: eval error: ");
            print_shen(result);
        } else if (result.tag == VAL_STRING) {
            /* Command output prints RAW (see print_raw_string_ex) — the
               display string built by shell.shen is exactly what the
               program wrote (plus a synthesized "exit N"/"error: ..." when
               there is no output). */
            print_raw_string_ex(result, 1);
        } else {
            print_shen(result);
            /* the exit builtin also signals via the symbol `exit` after
               setting *sh-exit* */
            is_exit = (result.tag == VAL_SYMBOL &&
                       strcmp(result.sym.name, "exit") == 0);
        }
        gc_root_pop();  /* result */
        if (is_exit) {
            break;
        }
    }

    return 0;
}

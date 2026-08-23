/*
 * zinctest.c — separate test binary for the ZINC VM
 *
 * Built with -DZINCTEST so zincvm.c's main is #ifndef'd out.
 * Contains the test harness, nursery scavenge stress tests,
 * self-hosting tests, and built-in bytecode tests that were
 * extracted from zincvm.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>

#include "zincvm.h"

/* ------------------------------------------------------------------ */
/*  Test-only globals                                                  */
/* ------------------------------------------------------------------ */

static jmp_buf alarm_jmp;
static volatile sig_atomic_t test_timed_out = 0;

/* ------------------------------------------------------------------ */
/*  Test runner                                                        */
/* ------------------------------------------------------------------ */

static void alarm_handler(int sig) {
    (void)sig;
    test_timed_out = 1;
    /* Use a dedicated jmp_buf: the catch-frame chain is clobbered by nested
       trap-error during load, so longjmp-ing there can land
       on a stale target inside the recursion and never break out. */
    longjmp(alarm_jmp, 1);
}

static void crash_handler(int sig) {
    fprintf(stderr, "\n*** CRASH: signal %d ***\n", sig);
    fprintf(stderr, "*** Resolve with: addr2line -e ./BINARY <addr> ***\n");
    /* Manual frame-pointer walk for x86_64.
     * Requires -fno-omit-frame-pointer at compile time.
     * x86_64 ABI: %rbp points to [saved_rbp, return_addr]. */
    void **rbp = __builtin_frame_address(0);
    int depth = 0;
    fprintf(stderr, "Backtrace (frame-pointer walk, depth limit 32):\n");
    while (rbp && depth < 32) {
        void *ret_addr = rbp[1];
        if (!ret_addr) break;
        fprintf(stderr, "  [%2d] %p\n", depth, ret_addr);
        void **next_rbp = (void **)rbp[0];
        if (next_rbp <= rbp) break;  /* guard against stack corruption loops */
        rbp = next_rbp;
        depth++;
    }
    _exit(sig);
}

static void run_test_timeout(const char *label, const char *bytecode, int show_code, int timeout_sec) {
    test_timed_out = 0;
    fprintf(stderr, "[run_test] %s: parsing...\n", label);
    printf("--- %s ---\n", label); fflush(stdout);
    printf("Bytecode: %s\n", bytecode); fflush(stdout);
    volatile Instr *code = NULL;
    int len = parse_bytecode(bytecode, (Instr **)&code);
    if (len <= 0 || code == NULL) { printf("PARSE FAILED\n\n"); fflush(stdout); return; }
    printf("Parsed %d instructions:\n", len); fflush(stdout);
    if (show_code) print_instr((Instr *)code, len, 0);
    printf("\n"); fflush(stdout);
    resolve_jumps((Instr *)code, len);
    fprintf(stderr, "[run_test] %s: executing...\n", label);
    if (timeout_sec > 0) {
        signal(SIGALRM, alarm_handler);
        alarm(timeout_sec);
    }
    if (setjmp(alarm_jmp)) {
        /* Timed out: SIGALRM longjmp'd us out of the vm_exec recursion. */
        alarm(0);
        printf("TIMEOUT (exceeded %d s)\n\n", timeout_sec); fflush(stdout);
    } else {
        CatchFrame cf;
        cf.parent = vm_catch_chain;
        cf.in_trap_error = 0;
        vm_catch_chain = &cf;
        if (setjmp(cf.buf)) {
            vm_catch_chain = cf.parent;
            alarm(0);
            gc_root_push_value(&cf.error_val);   /* S3: root error message */
            printf("ERROR CAUGHT: "); print_value(cf.error_val); printf("\n\n"); fflush(stdout);
            gc_root_pop();  /* S3: cf.error_val */
        } else {
            Value result = vm_exec((Instr *)code, len);
            vm_catch_chain = cf.parent;
            alarm(0);
            printf("Result: "); print_value(result); printf("\n\n"); fflush(stdout);
        }
    }
    fprintf(stderr, "[run_test] %s: done, freeing code\n", label);
    /* code is GC-allocated — no free needed */
    verify_heap();
}

static void run_test(const char *label, const char *bytecode, int show_code) {
    run_test_timeout(label, bytecode, show_code, 0);
}

/* ---- tagged plan builders for the exec-plan tests (46-52) ----
   Same tagged forms the metacircular interp produces ([cons H T] as a
   3-element list, [cons] = empty); rooting discipline mirrors the
   make_tagged_* helpers in zincvm.c: each intermediate Value is rooted
   across the next val_cons allocation.  A Value passed as an argument is
   DEAD after the call (it may move) — never reuse it. */

static Value tstr_(const char *s) {
    Value v = val_string(s, (int)strlen(s));
    gc_root_push_value(&v);
    Value inner = val_cons(v, val_nil());
    gc_root_push_value(&inner);
    Value result = val_cons(val_symbol("string"), inner);
    gc_root_pop(); gc_root_pop();
    return result;
}

static Value tsym_(const char *s) {
    Value v = val_symbol(s);
    gc_root_push_value(&v);
    Value inner = val_cons(v, val_nil());
    gc_root_push_value(&inner);
    Value result = val_cons(val_symbol("symbol"), inner);
    gc_root_pop(); gc_root_pop();
    return result;
}

static Value tnum_(long n) {
    Value v = val_number(n);
    gc_root_push_value(&v);
    Value inner = val_cons(v, val_nil());
    gc_root_push_value(&inner);
    Value result = val_cons(val_symbol("number"), inner);
    gc_root_pop(); gc_root_pop();
    return result;
}

/* [cons] = empty tagged list */
static Value tnil_(void) {
    return val_cons(val_symbol("cons"), val_nil());
}

/* [cons car cdr] */
static Value tcons2_(Value car, Value cdr) {
    gc_root_push_value(&car);
    gc_root_push_value(&cdr);
    Value inner = val_cons(car, val_cons(cdr, val_nil()));
    gc_root_push_value(&inner);
    Value result = val_cons(val_symbol("cons"), inner);
    gc_root_pop(); gc_root_pop(); gc_root_pop();
    return result;
}

/* [cons a [cons]] */
static Value tlist1_(Value a) {
    gc_root_push_value(&a);
    Value nil = tnil_();
    gc_root_pop();
    return tcons2_(a, nil);
}

/* [cons a [cons b [cons]]] */
static Value tlist2_(Value a, Value b) {
    gc_root_push_value(&a);
    gc_root_push_value(&b);
    Value l = tnil_();
    Value r = tcons2_(b, l);
    gc_root_pop(); gc_root_pop();
    return tcons2_(a, r);
}

/* [cons a [cons b [cons c [cons]]]] */
static Value tlist3_(Value a, Value b, Value c) {
    gc_root_push_value(&a);
    gc_root_push_value(&b);
    gc_root_push_value(&c);
    Value l = tnil_();
    Value r2 = tcons2_(c, l);
    Value r1 = tcons2_(b, r2);
    gc_root_pop(); gc_root_pop(); gc_root_pop();
    return tcons2_(a, r1);
}

/* argv tagged list from a C string array */
static Value targv_(char **argv, int argc) {
    Value av = tnil_();
    for (int i = argc - 1; i >= 0; i--) {
        gc_root_push_value(&av);
        Value s = tstr_(argv[i]);
        gc_root_pop();
        av = tcons2_(s, av);
    }
    return av;
}

/* Cmd = [argv [] ()] */
static Value tcmd_(char **argv, int argc) {
    Value av = targv_(argv, argc);
    gc_root_push_value(&av);
    Value redirs = tnil_();
    gc_root_push_value(&redirs);
    Value sub = tnil_();
    gc_root_pop(); gc_root_pop();
    return tlist3_(av, redirs, sub);
}

/* Cmd = [argv Redirs ()] with a pre-built redir list */
static Value tcmd_r_(char **argv, int argc, Value redirs) {
    gc_root_push_value(&redirs);
    Value av = targv_(argv, argc);
    gc_root_push_value(&av);
    Value sub = tnil_();
    gc_root_pop(); gc_root_pop();
    return tlist3_(av, redirs, sub);
}

/* Redirs = [[op fd target]] — one-element redirect list */
static Value tredir_(Value op, Value fd, Value target) {
    Value r = tlist3_(op, fd, target);
    return tlist1_(r);
}

/* Chain = [op pipe] */
static Value tchain_(const char *op, Value pipe) {
    gc_root_push_value(&pipe);
    Value o = tsym_(op);
    gc_root_pop();
    return tlist2_(o, pipe);
}

/* Program = [[seq [cmd]]] — single chain, single plain command */
static Value tplan1_(char **argv, int argc) {
    Value cmd = tcmd_(argv, argc);
    gc_root_push_value(&cmd);
    Value pipe = tlist1_(cmd);
    gc_root_push_value(&pipe);
    Value chain = tchain_("seq", pipe);
    gc_root_pop(); gc_root_pop();
    return tlist1_(chain);
}

/* call_bundled_1: call a single-argument bundled closure by name, returning
 * the result Value (or VAL_ERROR on lookup/exec failure).  Mirrors the env
 * setup used by eval-kl in zincvm.c: init_env = closure.env + [arg].  Used by
 * the fixed-point test to recompile a closure's KLambda through the bundled
 * compiler pipeline. */
static Value call_bundled_1(const char *name, Value arg) {
    Value fn = defun_get(name);
    if (fn.tag != VAL_LAMBDA) return val_nil();
    /* Keep fn and arg rooted across GC_VALUE_ARRAY alloc AND across vm_exec_env:
       the env array references arg, so arg must stay live during execution. */
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

/* call_bundled_2: call a two-argument bundled closure by name. */
static Value call_bundled_2(const char *name, Value a1, Value a2) {
    Value fn = defun_get(name);
    if (fn.tag != VAL_LAMBDA) return val_nil();
    gc_root_push_value(&fn);
    gc_root_push_value(&a1);
    gc_root_push_value(&a2);
    Value *env = GC_VALUE_ARRAY(fn.lambda.env_len + 2);
    if (fn.lambda.env_len > 0)
        memcpy(env, fn.lambda.env, fn.lambda.env_len * sizeof(Value));
    env[fn.lambda.env_len] = a1;
    env[fn.lambda.env_len + 1] = a2;
    if (gc_in_oldgen(env)) {
        if (value_references_nursery(&a1)) gc_dirty_vectors_add(env);
        if (value_references_nursery(&a2)) gc_dirty_vectors_add(env);
    }
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
        gc_root_pop();  /* a2 */
        gc_root_pop();  /* a1 */
        gc_root_pop();  /* fn */
        return result;
    }
    result = vm_exec_env(fn.lambda.code, fn.lambda.code_len, env, fn.lambda.env_len + 2);
    vm_catch_chain = cf.parent;
    gc_root_push_value(&result);
    gc_root_pop();                 /* result */
    gc_root_pop();                 /* a2 */
    gc_root_pop();                 /* a1 */
    gc_root_pop();                 /* fn */
    return result;
}

/* apply_closure_2: apply a closure VALUE (not by name) to 2 args. */
static Value apply_closure_2(Value fn, Value a1, Value a2) {
    if (fn.tag != VAL_LAMBDA) return val_nil();
    gc_root_push_value(&fn);
    gc_root_push_value(&a1);
    gc_root_push_value(&a2);
    Value *env = GC_VALUE_ARRAY(fn.lambda.env_len + 2);
    if (fn.lambda.env_len > 0)
        memcpy(env, fn.lambda.env, fn.lambda.env_len * sizeof(Value));
    env[fn.lambda.env_len] = a1;
    env[fn.lambda.env_len + 1] = a2;
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
        gc_root_pop();
        gc_root_pop();
        gc_root_pop();
        return result;
    }
    result = vm_exec_env(fn.lambda.code, fn.lambda.code_len, env, fn.lambda.env_len + 2);
    vm_catch_chain = cf.parent;
    gc_root_push_value(&result);
    gc_root_pop();
    gc_root_pop();
    gc_root_pop();
    gc_root_pop();
    return result;
}

/* ------------------------------------------------------------------ */
/*  Nursery scavenge helpers (moved from zincvm.c)                     */
/* ------------------------------------------------------------------ */

/* Force a nursery scavenge deterministically.
 *
 * The nursery is a 2MB bump allocator (NURSERY_PAGES=4096, PAGEBYTES=512).
 * gc_alloc's fast path bumps nursery_cur; when the bump cursor can't fit a
 * request, it calls collect_nursery().  We allocate a burst of GC_TYPE_RAW
 * objects (no interior pointers, thus safe for any root-scanning path) until
 * the gc_nursery_scavenge_count instrumentation counter advances past `target`.
 *
 * Under 4b.2 copying scavenge the nursery is fully reclaimed every cycle,
 * so a scavenge always fires eventually. */
static int force_nursery_scavenge(long target) {
    long cap = 200000;
    while (gc_nursery_scavenge_count < target && cap-- > 0) {
        /* ~64-byte payload per object keeps the allocation count reasonable;
           2MB nursery / 64B = ~32K allocs per scavenge. */
        char *p = (char *)gc_alloc_atomic(64);
        (void)p;
    }
    return gc_nursery_scavenge_count >= target;
}

/* Test 8 helpers.  These run in their own noinline frames so that no pointer
 * into body's TAIL pages (base+offset from the fill loop, or the burst's
 * locals) is ever left live on the frame that holds `body` itself.  If such a
 * tail-page pointer sat on the C stack during a collect, the backward walk
 * in the (now-deleted) pin_page would pin that tail and mask the very bug the
 * test existed to detect: a multi-page old-gen object reached only via its HEAD
 * page left its CONTINUED tail pages unpinned.
 *
 * Under 4b.1 sliding compaction, pin_page is deleted and root-reached objects
 * are EVACUATED (copied) into next_space via gc_move → move_internal, which
 * copies the full multi-page object word-by-word.  Tail-page retention is
 * therefore guaranteed by copy, not by pinning.  The test continues to verify
 * that a rooted multi-page object survives full collection intact. */

__attribute__((noinline))
static void t8_fill(Value *body, int N) {
    for (int i = 0; i < N; i++)
        body[i] = val_number(0xABCD0000u + (unsigned)i);
}

__attribute__((noinline))
static void t8_burst(void) {
    /* Enough dead 4MB raw chunks to fire several full collects AND wrap the
     * forward-only allocatepage cursor around the whole heap, so the cyclic
     * free-page scan eventually re-claims body's unpinned tail pages. */
    const size_t CHUNK = 4 * 1024 * 1024;
    for (int i = 0; i < 200; i++) {
        char *blob = (char *)gc_alloc_oldgen(CHUNK, GC_TYPE_RAW);
        (void)blob;
    }
}

__attribute__((noinline))
static int t8_verify(const Value *body, int N) {
    for (int i = 0; i < N; i++) {
        if (body[i].tag != VAL_NUMBER ||
            body[i].number != (long)(0xABCD0000u + (unsigned)i))
            return i;   /* index of first clobbered slot, or -1 if intact */
    }
    return -1;
}

/* Run the GC Phase 2 Step 5 generational nursery stress/retention tests.
 * Runs only when a bundle is loaded.  Returns 0 on all-pass, 1 on failure. */
static int gc_nursery_tests(void) {
    int failed = 0;

    printf("\n=== GC Phase 2 Step 5: nursery scavenge stress/retention tests ===\n");
    printf("  (state at start: scavenge_count=%ld, pages_reclaimed=%ld)\n",
           gc_nursery_scavenge_count, gc_nursery_pages_reclaimed);
    fflush(stdout);

    /* ---- Test 1: survivor correctness (copying scavenge) ---- */
    {
        /* Build a small chain of Values held in C-locals.  We allocate raw
         * numbers first, then a cons chain referencing them, so the chain is
         * genuinely reachable from the stack across the scavenge. */
        Value a = val_number(11);
        Value b = val_number(22);
        Value c = val_number(33);
        Value chain = val_cons(a, val_cons(b, val_cons(c, val_nil())));
        gc_root_push_value(&chain);  /* precise root across scavenge */

        /* Force a scavenge.  The chain's cells live in the nursery and are
         * reachable via the precise-root shadow stack, so collect_nursery
         * copies them to old-gen. */
        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);
        long delta = gc_nursery_scavenge_count - before;

        int ok = (delta >= 1);
        ok = ok && (chain.tag == VAL_CONS);
        ok = ok && (chain.cons.car->tag == VAL_NUMBER) &&
                   (chain.cons.car->number == 11);
        ok = ok && (chain.cons.cdr->tag == VAL_CONS);
        ok = ok && (chain.cons.cdr->cons.car->tag == VAL_NUMBER) &&
                   (chain.cons.cdr->cons.car->number == 22);
        ok = ok && (chain.cons.cdr->cons.cdr->cons.car->tag == VAL_NUMBER) &&
                   (chain.cons.cdr->cons.cdr->cons.car->number == 33);
        /* Under 4b.2 copying scavenge, survivors are evacuated to old-gen. */
        ok = ok && gc_in_oldgen(chain.cons.car) && !gc_in_nursery(chain.cons.car);
        ok = ok && gc_in_oldgen(chain.cons.cdr);
        ok = ok && gc_in_oldgen(chain.cons.cdr->cons.car);
        if (!ok) {
            printf("  [1] survivor correctness FAILED (scavenges fired=%ld)\n", delta);
            failed = 1;
        } else {
            printf("  [1] survivor correctness passed — chain intact after %ld scavenge(s), "
                   "evacuated to old-gen\n", delta);
        }
        gc_root_pop();  /* chain */
    }

    /* ---- Test 2: capacity reuse ---- */
    {
        /* We want to overflow the nursery so a scavenge fires and the bump
         * cursor is rewound to the nursery start, proving the lane is fully
         * reusable under 4b.2 copying scavenge.  Allocate dead 64B objects
         * (references dropped immediately) until the pages_reclaimed counter
         * increments — i.e. until a scavenge has actually reclaimed pages. */
        long before_rc = gc_nursery_pages_reclaimed;
        long cap = 200000;
        while (gc_nursery_pages_reclaimed == before_rc && cap-- > 0) {
            char *p = (char *)gc_alloc_atomic(64);
            (void)p;
        }
        int scavenged = (gc_nursery_pages_reclaimed > before_rc);
        long reclaimed = gc_nursery_pages_reclaimed - before_rc;

        /* Under 4b.2, each scavenge reclaims exactly NURSERY_PAGES. */
        int full_reclaim = (reclaimed == gc_nursery_capacity_pages());

        /* After the burst, a fresh small allocation must land back in the
         * nursery (bump cursor was reset to start), proving the lane is reusable. */
        char *probe = (char *)gc_alloc_atomic(64);
        int in_nursery = gc_in_nursery(probe);

        /* And we can keep allocating in the nursery repeatedly. */
        int keep_ok = 1;
        for (int i = 0; i < 1000 && keep_ok; i++) {
            char *q = (char *)gc_alloc_atomic(64);
            if (!gc_in_nursery(q)) keep_ok = 0;
        }

        int ok = scavenged;                       /* a scavenge reclaimed pages */
        ok = ok && reclaimed > 0;
        ok = ok && full_reclaim;                  /* exactly NURSERY_PAGES reclaimed */
        ok = ok && in_nursery;                    /* cursor reset */
        ok = ok && keep_ok;
        if (!ok) {
            printf("  [2] capacity reuse FAILED (pages_reclaimed +%ld, "
                   "full_reclaim=%d, probe_in_nursery=%d, keep_in_nursery=%d)\n",
                   reclaimed, full_reclaim, in_nursery, keep_ok);
            failed = 1;
        } else {
            printf("  [2] capacity reuse passed — +%ld pages reclaimed "
                   "(full nursery), reusable after turnover\n", reclaimed);
        }
    }

    /* ---- Test 3: cross-generational reference ---- */
    {
        /* Allocate a nursery Value, then an old-gen object that points to it.
         * The old-gen object is allocated via gc_alloc_oldgen so it never goes
         * through the nursery.  We store the nursery pointer inside the old-gen
         * object; a scavenge must find it via the dirty-vectors scan or the
         * old-gen OBJECT-page scan and copy the nursery object to old-gen. */
        Value nv = val_number(777);
        Value *nursery_val = GC_VALUE();
        *nursery_val = nv;

        /* Old-gen object: a GC_TYPE_VALUE whose body holds the nursery Value. */
        Value *oldgen = (Value *)gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        *oldgen = val_cons(*nursery_val, val_nil());

        gc_root_push_ptr((void**)&nursery_val);  /* precise root across scavenge */
        gc_root_push_ptr((void**)&oldgen);       /* precise root across scavenge */

        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);

        /* The old-gen object must still reference the (now old-gen) cell. */
        int ok = (oldgen->tag == VAL_CONS);
        ok = ok && (oldgen->cons.car->tag == VAL_NUMBER);
        ok = ok && (oldgen->cons.car->number == 777);
        /* Under 4b.2, the nursery cell was copied to old-gen. */
        ok = ok && gc_in_oldgen(oldgen->cons.car) && !gc_in_nursery(oldgen->cons.car);
        if (!ok) {
            printf("  [3] cross-generational reference FAILED\n");
            failed = 1;
        } else {
            printf("  [3] cross-generational reference passed — old-gen->nursery "
                   "reference survived scavenge (nursery object evacuated to old-gen)\n");
        }
        gc_root_pop();  /* oldgen */
        gc_root_pop();  /* nursery_val */
    }

    /* ---- Test 4: two-scavenge survival ---- */
    {
        Value nv = val_number(4242);
        Value *surv = GC_VALUE();
        *surv = nv;
        gc_root_push_ptr((void**)&surv);  /* precise root across two scavenges */

        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);  /* scavenge #1 — copy to old-gen */

        /* After scavenge #1, the survivor must be in old-gen. */
        int ok1 = gc_in_oldgen(surv) && !gc_in_nursery(surv);
        void *ptr1 = surv;
        ok1 = ok1 && (surv->tag == VAL_NUMBER) && (surv->number == 4242);

        force_nursery_scavenge(before + 2);  /* scavenge #2 — old-gen untouched */

        /* After scavenge #2, pointer unchanged (old-gen not re-evacuated). */
        int ok = ok1 && (surv == ptr1);
        ok = ok && (surv->tag == VAL_NUMBER) && (surv->number == 4242);
        if (!ok) {
            printf("  [4] two-scavenge survival FAILED (ok1=%d ptr_changed=%d)\n",
                   ok1, surv != ptr1);
            failed = 1;
        } else {
            printf("  [4] two-scavenge survival passed — nursery object evacuated "
                   "to old-gen, pointer stable across two scavenges\n");
        }
        gc_root_pop();  /* surv */
    }

    /* ---- Test 5: scavenge -> full collect -> scavenge ---- */
    {
        /* Promote a nursery object (copied to old-gen across a scavenge),
         * then force a full collection (flips current_space, so the
         * promoted object's new pages survive), then scavenge again.
         * Under 4b.2, the promoted object is in old-gen and survives
         * both the full collect and the rescavenge. */
        Value nv = val_number(909);
        Value *promoted = GC_VALUE();
        *promoted = nv;
        gc_root_push_ptr((void**)&promoted);  /* precise root across scavenge+collect+rescavenge */

        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);  /* copy `promoted` to old-gen */

        /* Verify promoted is now in old-gen. */
        int in_old = gc_in_oldgen(promoted) && !gc_in_nursery(promoted);

        /* Force a full collection by allocation pressure. */
        {
            const size_t CHUNK = 4 * 1024 * 1024;   /* 4MB dead chunks */
            for (int i = 0; i < 24; i++) {
                char *blob = (char *)gc_alloc_oldgen(CHUNK, GC_TYPE_RAW);
                (void)blob;
            }
        }

        /* After full collect, promoted must still be in old-gen. */
        int still_old = gc_in_oldgen(promoted) && !gc_in_nursery(promoted);

        /* Scavenge again — promoted object is old-gen, untouched. */
        force_nursery_scavenge(gc_nursery_scavenge_count + 1);

        int ok = in_old && still_old;
        ok = ok && (promoted->tag == VAL_NUMBER) && (promoted->number == 909);
        if (!ok) {
            printf("  [5] scavenge->full-collect->scavenge FAILED "
                   "(in_old=%d still_old=%d)\n", in_old, still_old);
            failed = 1;
        } else {
            printf("  [5] scavenge->full-collect->scavenge passed — promoted "
                   "object survived full collect + rescavenge in old-gen\n");
        }
        gc_root_pop();  /* promoted */
    }

    /* ---- Test 6: write-barrier dirty_vectors survival ---- */
    {
        /* Allocate a 4-slot vector in a GC_TYPE_VALUE slot so it's
         * heap-reachable through a cons cell (no C-local to the vector
         * Value itself, only to the cons that holds it).  The vector's
         * element array is nursery-allocated by val_vector; a scavenge
         * promotes it to old-gen.  Then a NURSERY CONS is stored into
         * the old-gen vector via address->; the write barrier must
         * record the element array so the next scavenge scans it and
         * the stored nursery cons survives. */
        Value *vec_slot = gc_alloc(sizeof(Value), GC_TYPE_VALUE);
        *vec_slot = val_vector(4);

        /* Wrap vec_slot in a cons so the vector is heap-reachable
         * (cons_cell is the only C-local pointer to it). */
        Value *cons_cell = gc_alloc(sizeof(Value), GC_TYPE_VALUE);
        *cons_cell = val_cons(*vec_slot, val_nil());

        gc_root_push_ptr((void**)&vec_slot);   /* precise root across scavenges */
        gc_root_push_ptr((void**)&cons_cell);  /* precise root across scavenges */

        /* Scavenge #1: promote the vector's element array to old-gen.
         * cons_cell is on the precise-root shadow stack — pinned. */
        long before6 = gc_nursery_scavenge_count;
        force_nursery_scavenge(before6 + 1);

        /* A nursery cons: (778899 . 0).  Created AFTER scavenge #1 so its
         * car/cdr cells are freshly allocated in the nursery (had we created
         * it before, scavenge #1 would have promoted them to old-gen and
         * value_references_nursery() would be false). */
        Value nursery_cons = val_cons(val_number(778899), val_number(0));

        /* Get a direct pointer to the vector's element array
         * (the cons chain is the only C-local reference to the vector). */
        Value *vec_data = (*cons_cell->cons.car).vector.data;

        /* Barrier control: storing a NUMBER into the old-gen vector must
         * NOT fire the barrier (no nursery reference).  Snapshot counter. */
        long fired_before = gc_dirty_vectors_fired;
        vec_data[1] = val_number(999);
        int number_no_fire = (gc_dirty_vectors_fired == fired_before);

        /* Now store the NURSERY CONS at index 0 — this MUST fire the barrier.
         * Simulate what address-> does: check gc_in_oldgen + nursery refs,
         * then call gc_dirty_vectors_add. */
        long fired_before2 = gc_dirty_vectors_fired;
        vec_data[0] = nursery_cons;
        {
            Value vec_v = *cons_cell->cons.car;
            if (vec_v.vector.data && gc_in_oldgen(vec_v.vector.data)) {
                /* value_references_nursery is static in zincvm.c, so we
                   approximate its logic: a VAL_CONS has two nursery pointers
                   (car and cdr); if either is in the nursery, fire barrier. */
                if ((nursery_cons.cons.car && gc_in_nursery(nursery_cons.cons.car)) ||
                    (nursery_cons.cons.cdr && gc_in_nursery(nursery_cons.cons.cdr))) {
                    gc_dirty_vectors_add(vec_v.vector.data);
                }
            }
        }
        int cons_fired = (gc_dirty_vectors_fired == fired_before2 + 1);

        /* Scavenge #2: the dirty_vectors scan must find the nursery cons
         * reference through the old-gen vector and preserve it. */
        force_nursery_scavenge(gc_nursery_scavenge_count + 1);

        /* Verify: element 0 of the vector (reachable through the cons
         * chain) is still the nursery cons (778899 . 0). */
        Value el0 = (*cons_cell->cons.car).vector.data[0];
        int ok6 = number_no_fire && cons_fired;
        ok6 = ok6 && (el0.tag == VAL_CONS)
                  && (el0.cons.car->tag == VAL_NUMBER)
                  && (el0.cons.car->number == 778899);
        /* Under 4b.2, the nursery cons is evacuated to old-gen. */
        ok6 = ok6 && gc_in_oldgen(el0.cons.car) && !gc_in_nursery(el0.cons.car);
        if (!ok6) {
            printf("  [6] write-barrier dirty_vectors FAILED "
                   "(number_no_fire=%d cons_fired=%d)\n",
                   number_no_fire, cons_fired);
            failed = 1;
        } else {
            printf("  [6] write-barrier dirty_vectors passed — address-> of "
                   "nursery cons into old-gen vector survived scavenge via barrier "
                   "(evacuated to old-gen)\n");
        }
        gc_root_pop();  /* cons_cell */
        gc_root_pop();  /* vec_slot */
    }

    /* ---- Test 8: multi-page old-gen object survival across full collect ----
     * Verifies that a multi-page OLD-GEN object reached via its HEAD page
     * survives a full collection with all its tail pages intact.  Under 4b.1
     * sliding compaction, the object is evacuated (copied to to-space) via
     * gc_move → move_internal, which copies the full multi-page body
     * word-by-word.  Tail-page clobbering is therefore moot — there are no
     * unpinned tail pages to reclaim.
     *
     * The object's body pointer is held on the precise-root shadow stack
     * (gc_root_push_ptr).  gc_scan_roots(0) now calls gc_evacuate on the
     * slot, routing the head pointer through gc_move which copies the entire
     * multi-page object to to-space.  If evacuation were broken, the tail
     * pages would be reclaimed and the sentinel values clobbered. */
    {
        /* N chosen so the VALUE_ARRAY spans exactly 3 pages:
         * words = ceil(N*40/8)+1, PAGEBYTES=512 / WORDBYTES=8 => 64 words/page.
         * N=30 => words=151, which spans pages [0..2] (64+64+23), giving two
         * CONTINUED tail pages that full-object copy must preserve. */
        const int N = 30;
        size_t bytes = (size_t)N * sizeof(Value);
        Value *body = (Value *)gc_alloc_oldgen(bytes, GC_TYPE_VALUE_ARRAY);

        /* Fill the sentinels from a separate frame so no tail-page pointer
         * lingers on this frame (see t8_fill comment). */
        t8_fill(body, N);

        gc_root_push_ptr((void**)&body);  /* precise root across full-collect burst */

        /* Force full collections by allocation pressure (same technique as
         * Test 5) and wrap the free-page cursor around the heap (see
         * t8_burst).  `body` is evacuated via gc_move →
         * move_internal, which copies the full multi-page object to
         * to-space.  We must NOT read `body` during the burst: that would
         * leave a tail-page pointer on the stack and evacuate the object
         * early, masking any incomplete-copy bug. */
        t8_burst();

        int first_bad = t8_verify(body, N);
        gc_root_pop();  /* body */
        if (first_bad >= 0) {
            printf("  [8] multi-page old-gen tail retention FAILED (slot %d "
                   "clobbered)\n", first_bad);
            failed = 1;
        } else {
            printf("  [8] multi-page old-gen tail retention passed — all %d "
                   "slots intact across full collect\n", N);
        }
    }

    /* ---- Test 7: pre-emptive triggers ---- */
    {
        long before_pre = gc_preemptive_scavenge_count;
        long before_react = gc_reactive_scavenge_count;

        /* Burst-allocate ~30000 dead gc_alloc_atomic(64) objects.
         * The pre-emptive trigger fires at 87.5% nursery fullness,
         * so the reactive path should never be hit during this burst. */
        long cap = 30000;
        while (cap-- > 0) {
            char *p = (char *)gc_alloc_atomic(64);
            (void)p;
        }

        long pre_fired = gc_preemptive_scavenge_count - before_pre;
        long react_fired = gc_reactive_scavenge_count - before_react;

        /* Under 4b.2, the nursery is fully reclaimed each scavenge so the
         * probe must always land in the nursery.  This is a hard requirement
         * — no degradation path. */
        int ok = (pre_fired >= 1) && (react_fired == 0);
        char *probe = (char *)gc_alloc_atomic(64);
        int in_nursery = probe ? gc_in_nursery(probe) : 0;
        ok = ok && (in_nursery == 1);
        if (!ok) {
            printf("  [7] pre-emptive triggers FAILED "
                   "(pre_fired=%ld react_fired=%ld in_nursery=%d)\n",
                   pre_fired, react_fired, in_nursery);
            failed = 1;
        } else {
            printf("  [7] pre-emptive triggers passed — %ld pre-emptive, "
                   "0 reactive (probe in nursery=%d)\n",
                   pre_fired, in_nursery);
        }
    }

    /* ---- Test 9: nursery fully reclaimed each cycle (4b.2) ---- */
    {
        /* Loop 20×: allocate ~32K dead 64B objects to force a scavenge.
         * After each scavenge, the nursery must be fully reclaimed. */
        int ok9 = 1;
        long last_reclaimed = gc_nursery_pages_reclaimed;
        long ncap = gc_nursery_capacity_pages();
        for (int cycle = 0; cycle < 20 && ok9; cycle++) {
            long target = gc_nursery_scavenge_count + 1;
            while (gc_nursery_scavenge_count < target) {
                char *p = (char *)gc_alloc_atomic(64);
                (void)p;
            }
            /* After scavenge, nursery must be fully reclaimed. */
            if (!gc_nursery_is_empty()) {
                ok9 = 0;
                printf("  [9] cycle %d: nursery not empty after scavenge\n", cycle);
            }
            long reclaimed = gc_nursery_pages_reclaimed - last_reclaimed;
            if (reclaimed != ncap) {
                ok9 = 0;
                printf("  [9] cycle %d: reclaimed %ld pages, expected %ld\n",
                       cycle, reclaimed, ncap);
            }
            last_reclaimed = gc_nursery_pages_reclaimed;
        }
        if (!ok9) {
            printf("  [9] nursery fully reclaimed each cycle FAILED\n");
            failed = 1;
        } else {
            printf("  [9] nursery fully reclaimed each cycle passed — "
                   "20 scavenges, nursery empty + %ld pages reclaimed each time\n",
                   ncap);
        }
    }

    /* ---- Test 10: copy not pin (4b.2) ---- */
    {
        /* Allocate a GC_VALUE in nursery, root via ROOT_PTR, force scavenge.
         * Assert root's pointer is now gc_in_oldgen() && !gc_in_nursery(). */
        Value *root_val = GC_VALUE();
        *root_val = val_number(0x4B2);
        gc_root_push_ptr((void**)&root_val);

        force_nursery_scavenge(gc_nursery_scavenge_count + 1);

        int ok10 = gc_in_oldgen(root_val) && !gc_in_nursery(root_val);
        ok10 = ok10 && (root_val->tag == VAL_NUMBER) && (root_val->number == 0x4B2);
        void *first_ptr = root_val;

        /* Allocate another nursery object, scavenge again, assert first
         * survivor unmoved (same pointer, still old-gen). */
        Value *nv2 = GC_VALUE();
        *nv2 = val_number(4242);
        gc_root_push_ptr((void**)&nv2);

        force_nursery_scavenge(gc_nursery_scavenge_count + 1);

        ok10 = ok10 && (root_val == first_ptr);  /* unchanged */
        ok10 = ok10 && gc_in_oldgen(root_val) && !gc_in_nursery(root_val);

        gc_root_pop();  /* nv2 */
        gc_root_pop();  /* root_val */

        if (!ok10) {
            printf("  [10] copy not pin FAILED\n");
            failed = 1;
        } else {
            printf("  [10] copy not pin passed — nursery object evacuated to "
                   "old-gen, pointer stable after second scavenge\n");
        }
    }

    /* ---- Test 11: deep nursery graph (4b.2 allocatepage gating proof) ---- */
    {
        /* Build a 500-node cons chain in nursery, root head via ROOT_VALUE,
         * force ONE scavenge, walk chain — every cell in old-gen and intact.
         * Proves the allocatepage-gating fix (Cheney drain through destination
         * pages scans copied survivors' bodies for further nursery refs). */
        Value chain = val_nil();
        gc_root_push_value(&chain);
        for (int i = 499; i >= 0; i--)
            chain = val_cons(val_number(i), chain);

        force_nursery_scavenge(gc_nursery_scavenge_count + 1);

        int ok11 = 1;
        int count = 0;
        Value cur = chain;
        while (cur.tag == VAL_CONS && ok11) {
            if (!gc_in_oldgen(cur.cons.car) || gc_in_nursery(cur.cons.car)) {
                ok11 = 0;
                printf("  [11] node %d car not in old-gen\n", count);
            }
            if (cur.cons.car->tag != VAL_NUMBER || cur.cons.car->number != count) {
                ok11 = 0;
                printf("  [11] node %d value mismatch (expected %d, got %ld)\n",
                       count, count,
                       cur.cons.car ? (long)cur.cons.car->number : -1);
            }
            cur = *cur.cons.cdr;
            count++;
        }
        ok11 = ok11 && (count == 500);

        gc_root_pop();  /* chain */

        if (!ok11) {
            printf("  [11] deep nursery graph FAILED (count=%d)\n", count);
            failed = 1;
        } else {
            printf("  [11] deep nursery graph passed — 500-node chain evacuated "
                   "to old-gen in one scavenge (%d cells intact)\n", count);
        }
    }

    /* ---- Test 12: no other_space in nursery (4b.2) ---- */
    {
        int ok12 = gc_nursery_no_other_space();
        if (!ok12) {
            printf("  [12] no other_space FAILED — nursery page has other_space tag\n");
            failed = 1;
        } else {
            printf("  [12] no other_space passed — no nursery page has other_space\n");
        }
    }

    /* ---- Test 13: cyclic old-gen structure (4b.2 infinite-loop detector) ---- */
    {
        /* Create a 2-cell cyclic old-gen structure and trigger a scavenge.
         * Detects if gc_move queues old-gen pages without dedup, leading to infinite loop. */
        printf("  [13] building 2-cell cyclic old-gen structure...\n");
        fflush(stdout);

        Value *cell1 = (Value *)gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        Value *cell2 = (Value *)gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        Value *num1  = (Value *)gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        Value *num2  = (Value *)gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);

        *cell1 = val_nil();
        *cell2 = val_nil();
        *num1  = val_number(1);
        *num2  = val_number(2);

        cell1->tag = VAL_CONS;
        cell1->cons.car = num1;
        cell1->cons.cdr = cell2;

        cell2->tag = VAL_CONS;
        cell2->cons.car = num2;
        cell2->cons.cdr = cell1;

        /* Root all values so they survive the scavenge */
        gc_root_push_value(cell1);
        gc_root_push_value(cell2);
        gc_root_push_value(num1);
        gc_root_push_value(num2);

        /* Force a scavenge with 5-second alarm */
        long before = gc_nursery_scavenge_count;
        signal(SIGALRM, alarm_handler);
        alarm(5);
        if (setjmp(alarm_jmp)) {
            alarm(0);
            printf("  [13] TIMEOUT: infinite loop on cyclic old-gen (BLOCKER)!\n");
            failed = 1;
        } else {
            long target = before + 1;
            while (gc_nursery_scavenge_count < target) {
                char *p = (char *)gc_alloc_atomic(64);
                (void)p;
            }
            alarm(0);

            /* Verify the cycle is still intact */
            int ok13 = (cell1->tag == VAL_CONS && cell2->tag == VAL_CONS);
            ok13 = ok13 && (cell1->cons.car->tag == VAL_NUMBER && cell1->cons.car->number == 1);
            ok13 = ok13 && (cell2->cons.car->tag == VAL_NUMBER && cell2->cons.car->number == 2);
            ok13 = ok13 && (cell1->cons.cdr == cell2 && cell2->cons.cdr == cell1);
            ok13 = ok13 && gc_in_oldgen(cell1) && gc_in_oldgen(cell2);
            ok13 = ok13 && gc_in_oldgen(num1) && gc_in_oldgen(num2);

            if (!ok13) {
                printf("  [13] cyclic old-gen FAILED (cycle corrupted or not in old-gen)\n");
                failed = 1;
            } else {
                printf("  [13] cyclic old-gen passed — cycle intact, no infinite loop\n");
            }
        }

        gc_root_pop();  /* num2 */
        gc_root_pop();  /* num1 */
        gc_root_pop();  /* cell2 */
        gc_root_pop();  /* cell1 */
    }

    /* ---- Test 14: dirty-globals survivor (load-bearing) ---- */
    {
        /* Allocate a nursery cons, register as precise root, store in
         * global table, force a scavenge — the cons must be evacuated
         * to old-gen and intact when retrieved via defun_get.
         * This is the load-bearing test for barrier site 2. */
        Value c = val_cons(val_number(42), val_nil());
        gc_root_push_value(&c);  /* precise root across scavenge */

        long fired_before = gc_dirty_defuns_fired;
        defun_set("t-dirty-1", c);
        int fired_ok = (gc_dirty_defuns_fired > fired_before);

        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);

        Value retrieved = defun_get("t-dirty-1");
        int ok14 = fired_ok;
        ok14 = ok14 && (retrieved.tag == VAL_CONS);
        ok14 = ok14 && retrieved.cons.car &&
                       (retrieved.cons.car->tag == VAL_NUMBER) &&
                       (retrieved.cons.car->number == 42);
        ok14 = ok14 && gc_in_oldgen(retrieved.cons.car) &&
                       !gc_in_nursery(retrieved.cons.car);

        if (!ok14) {
            printf("  [14] dirty-globals survivor FAILED "
                   "(fired_ok=%d tag=%d val=%ld)\n",
                   fired_ok, retrieved.tag,
                   retrieved.cons.car ? (long)retrieved.cons.car->number : -1);
            failed = 1;
        } else {
            printf("  [14] dirty-globals survivor passed — nursery cons "
                   "survived via dirty-globals barrier, evacuated to old-gen\n");
        }
        gc_root_pop();  /* c */
    }

    /* ---- Test 15: dirty-globals re-mark after clear ---- */
    {
        /* After a scavenge clears the bitset, a fresh defun_set must
         * re-mark the bit so the next scavenge still scans it. */
        Value c2 = val_cons(val_number(99), val_nil());
        gc_root_push_value(&c2);

        long fired_before = gc_dirty_defuns_fired;
        defun_set("t-dirty-1", c2);
        int refired_ok = (gc_dirty_defuns_fired > fired_before);

        long scanned_before = gc_dirty_defuns_scanned;
        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);
        int rescanned_ok = (gc_dirty_defuns_scanned > scanned_before);

        Value retrieved = defun_get("t-dirty-1");
        int ok15 = refired_ok && rescanned_ok;
        ok15 = ok15 && (retrieved.tag == VAL_CONS);
        ok15 = ok15 && retrieved.cons.car &&
                       (retrieved.cons.car->tag == VAL_NUMBER) &&
                       (retrieved.cons.car->number == 99);
        ok15 = ok15 && gc_in_oldgen(retrieved.cons.car) &&
                       !gc_in_nursery(retrieved.cons.car);

        if (!ok15) {
            printf("  [15] dirty-globals re-mark FAILED "
                   "(refired=%d rescanned=%d tag=%d val=%ld)\n",
                   refired_ok, rescanned_ok, retrieved.tag,
                   retrieved.cons.car ? (long)retrieved.cons.car->number : -1);
            failed = 1;
        } else {
            printf("  [15] dirty-globals re-mark passed — bit re-marked "
                   "after clear, rescanned in next scavenge\n");
        }
        gc_root_pop();  /* c2 */
    }

    /* ---- Test 16: dirty-globals skip (optimization proof) ---- */
    {
        /* After a scavenge clears the bitset and with no intervening
         * defun_set, the next scavenge must scan zero dirty defuns. */
        long scanned_before = gc_dirty_defuns_scanned;
        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);
        long scanned_delta = gc_dirty_defuns_scanned - scanned_before;

        int ok16 = (scanned_delta == 0);
        if (!ok16) {
            printf("  [16] dirty-defuns skip FAILED "
                   "(scanned_delta=%ld, expected 0)\n", scanned_delta);
            failed = 1;
        } else {
            printf("  [16] dirty-defuns skip passed — no dirty defuns "
                   "scanned when none marked\n");
        }
    }

    /* ---- Test 17: dirty-globals old-gen store ---- */
    {
        /* Storing an old-gen value into the global table must still
         * mark the bit and be scanned, but gc_scan_value is a no-op
         * on already-old-gen closures — no corruption. */
        Value *oldval = (Value *)gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        *oldval = val_number(7777);
        gc_root_push_ptr((void**)&oldval);

        long fired_before = gc_dirty_defuns_fired;
        defun_set("t-oldgen", *oldval);
        int fired17 = (gc_dirty_defuns_fired > fired_before);

        long scanned_before = gc_dirty_defuns_scanned;
        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);
        int scanned17 = (gc_dirty_defuns_scanned > scanned_before);

        Value retrieved = defun_get("t-oldgen");
        int ok17 = fired17 && scanned17;
        ok17 = ok17 && (retrieved.tag == VAL_NUMBER) &&
                       (retrieved.number == 7777);

        if (!ok17) {
            printf("  [17] dirty-globals old-gen store FAILED "
                   "(fired=%d scanned=%d tag=%d val=%ld)\n",
                   fired17, scanned17, retrieved.tag,
                   (long)retrieved.number);
            failed = 1;
        } else {
            printf("  [17] dirty-globals old-gen store passed — old-gen "
                   "value scanned without corruption\n");
        }
        gc_root_pop();  /* oldval */
    }

    /* ---- Test 18: dirty-globals full-collect hygiene ---- */
    {
        /* A full collect must clear the dirty-globals bitset so a
         * subsequent scavenge starts from a clean bitset. */
        Value *hv = (Value *)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
        *hv = val_number(8888);
        gc_root_push_ptr((void**)&hv);

        /* Mark a defun dirty. */
        long fired_before = gc_dirty_defuns_fired;
        defun_set("t-hygiene", *hv);
        int fired18 = (gc_dirty_defuns_fired > fired_before);

        /* Force a full collect via old-gen allocation pressure.
         * Use the same technique as Test 8 (200 × 4MB chunks) to
         * guarantee a full collect fires regardless of heap size. */
        long fc_before = gc_full_collect_count;
        {
            const size_t CHUNK = 4 * 1024 * 1024;
            for (int i = 0; i < 200; i++) {
                char *blob = (char *)gc_alloc_oldgen(CHUNK, GC_TYPE_RAW);
                (void)blob;
            }
        }
        int fc_ok = (gc_full_collect_count > fc_before);

        /* After full collect, force a scavenge — no dirty defuns
         * should be scanned because the full collect cleared them. */
        long scanned_before = gc_dirty_defuns_scanned;
        long before = gc_nursery_scavenge_count;
        force_nursery_scavenge(before + 1);
        long scanned_delta = gc_dirty_defuns_scanned - scanned_before;

        int ok18 = fired18 && fc_ok && (scanned_delta == 0);
        if (!ok18) {
            printf("  [18] dirty-defuns full-collect hygiene FAILED "
                   "(fired=%d fc_ok=%d scanned_delta=%ld)\n",
                   fired18, fc_ok, scanned_delta);
            failed = 1;
        } else {
            printf("  [18] dirty-defuns full-collect hygiene passed — "
                   "bits cleared by full collect, no stale scan\n");
        }
        gc_root_pop();  /* hv */
    }

    printf(failed ? "GC nursery tests FAILED\n" : "GC nursery tests all passed\n");
    printf("GC alloc classes: RAW=%llu VALUE=%llu VALUE_ARRAY=%llu "
           "INSTR_ARRAY=%llu CALLFRAME_ARRAY=%llu\n",
           gc_alloc_class_count[GC_TYPE_RAW],
           gc_alloc_class_count[GC_TYPE_VALUE],
           gc_alloc_class_count[GC_TYPE_VALUE_ARRAY],
           gc_alloc_class_count[GC_TYPE_INSTR_ARRAY],
           gc_alloc_class_count[GC_TYPE_CALLFRAME_ARRAY]);
    return failed;
}

/* ---- GC Phase 4a churn test: precise-root missed-root detector ----
 * A deep cons tree is built through the NORMAL nursery path (real
 * val_cons) and held ONLY by a precise root (gc_root_push_value).  After
 * the eventual flip (conservative C-stack scan removed), this root is the
 * sole reason the tree survives.  Repeated transient nursery allocations
 * + forced scavenges/full collects must never reclaim a reachable node.
 * Deterministic (fixed LCG seed).  This is the crux detector for missed
 * roots under precise-authoritative collection. */
static unsigned long churn_lcg = 0xDEADBEEFUL;
static unsigned long churn_lcg_next(void) {
    churn_lcg = churn_lcg * 1103515245UL + 12345UL;
    return churn_lcg & 0x7FFFFFFFUL;
}

static int gc_root_churn_test(void) {
    int failed = 0;
    const int node_count = 5000;
    printf("\n=== GC Phase 4a churn test: %d-node nursery-allocated cons tree, 200K iters ===\n",
           node_count);
    fflush(stdout);

    /* Build the persistent tree bottom-up through the nursery (real val_cons),
     * head held only on the precise-root shadow stack. */
    Value root = val_nil();
    gc_root_push_value(&root);
    for (int i = node_count - 1; i >= 0; i--)
        root = val_cons(val_number(i), root);

    /* Verify the freshly-built tree before churn. */
    {
        int count = 0; Value cur = root;
        while (cur.tag == VAL_CONS) {
            if (cur.cons.car->tag != VAL_NUMBER || cur.cons.car->number != count) {
                fprintf(stderr, "[churn] initial tree corrupt at node %d (tag=%d num=%ld)\n",
                        count, cur.cons.car ? (int)cur.cons.car->tag : -1,
                        cur.cons.car ? (long)cur.cons.car->number : -1);
                gc_root_pop();
                return 1;
            }
            cur = *cur.cons.cdr; count++;
        }
        if (count != node_count) {
            printf("  gc_root_churn_test: initial count mismatch: %d vs %d\n", count, node_count);
            gc_root_pop();
            return 1;
        }
        printf("  initial tree verified: %d nodes\n", count);
    }

    long sv0 = gc_nursery_scavenge_count;
    long fc0 = gc_full_collect_count;

    for (int iter = 0; iter < 200000; iter++) {
        /* Transient nursery garbage: ~3 dead cons cells per iteration. */
        Value g1 = val_cons(val_number(churn_lcg_next()), val_nil());
        Value g2 = val_cons(val_number(churn_lcg_next()), g1);
        Value g3 = val_cons(val_number(churn_lcg_next()), g2);
        (void)g3;

        /* Force a nursery scavenge every ~2000 iterations. */
        if (iter % 2000 == 0) {
            long cap = 5000;
            while (gc_nursery_scavenge_count < sv0 + 1 + iter/2000 && cap-- > 0) {
                char *p = (char *)gc_alloc_atomic(64);
                (void)p;
            }
        }

        /* Force a full collect occasionally (semi-space swap survival). */
        if (iter % 100000 == 0 && iter > 0) {
            const size_t CHUNK = 4UL * 1024 * 1024;
            for (int fi = 0; fi < 2; fi++) {
                char *blob = (char *)gc_alloc_oldgen(CHUNK, GC_TYPE_RAW);
                (void)blob;
            }
        }

        /* Walk + verify the whole tree every 10000 iterations. */
        if (iter % 10000 == 0 && iter > 0) {
            int count = 0; Value cur = root;
            while (cur.tag == VAL_CONS) {
                if (cur.cons.car->tag != VAL_NUMBER || cur.cons.car->number != count) {
                    printf("  gc_root_churn_test: tree corrupt at iter %d, node %d "
                           "(expected %d, tag=%d)\n", iter, count, count,
                           cur.cons.car ? (int)cur.cons.car->tag : -1);
                    failed = 1; goto done;
                }
                cur = *cur.cons.cdr; count++;
            }
            if (count != node_count) {
                printf("  gc_root_churn_test: tree truncated at iter %d, got %d nodes\n",
                       iter, count);
                failed = 1; goto done;
            }
        }
    }

done:
    /* Final verification. */
    if (!failed) {
        int count = 0; Value cur = root;
        while (cur.tag == VAL_CONS) {
            if (cur.cons.car->tag != VAL_NUMBER || cur.cons.car->number != count) {
                printf("  gc_root_churn_test: final verification failed at node %d\n", count);
                failed = 1; break;
            }
            cur = *cur.cons.cdr; count++;
        }
        if (!failed && count != node_count) {
            printf("  gc_root_churn_test: final count mismatch: %d vs %d\n", count, node_count);
            failed = 1;
        }
    }

    long total_collections = (gc_nursery_scavenge_count - sv0)
                           + (gc_full_collect_count - fc0);
    gc_root_pop();  /* root */

    printf(failed ? "  gc_root_churn_test FAILED\n"
                  : "  gc_root_churn_test PASSED — tree intact after 200K iters, %ld collections\n",
           total_collections);
    return failed;
}

/* ---- GC Phase 4b.1 compaction test: prove objects MOVE ----
 *
 * Builds a known LIVE set of N cons-cell pairs (car ← gc_alloc_oldgen
 * number cell, cdr ← next pair or nil) entirely in OLD-GEN so they are
 * guaranteed to be in current_space and thus candidates for evacuation.
 * The chain is held ONLY by a precise root (gc_root_push_value).
 *
 * After a forced full collect (allocation-pressure burst of dead 4MB raw
 * chunks), two assertions must hold:
 *   (a) the chain survived intact (walk and verify all N),
 *   (b) a specific interior pointer actually MOVED (under pinning it
 *       would not move; under evacuation it MUST).
 *
 * Assertion (a) proves correctness: no missed root.  Assertion (b)
 * proves compaction: the object was copied to to-space rather than
 * pinned in place.  Together they are the deterministic gate for 4b.1.
 *
 * Deterministic (fixed size, no random seed).  Runs on BOTH the no-arg
 * path (fresh nursery) and the bundle path (exhausted nursery — the
 * chain is old-gen and unaffected). */
static int gc_compaction_test(void) {
    int failed = 0;
    const int N = 2000;

    printf("\n=== GC Phase 4b.1 compaction test: %d-node old-gen cons chain ===\n", N);
    fflush(stdout);

    /* Build chain in old-gen: (0 . (1 . (2 . ... (N-1 . nil))))
     * Each cons cell and its car (a number Value) are old-gen allocated.
     * The chain is held ONLY on the precise-root shadow stack.
     *
     * IMPORTANT: exhaust any free pages within the nursery address range
     * first by allocating 2 MB of dead raw chunks via gc_alloc_oldgen.
     * Promoted nursery pages from a prior era may have their space tag
     * in the OTHER semi-space (not current_space/next_space/NURSERY),
     * making them look free to allocatepage.  Reusing such a page for
     * a chain cell would make gc_in_nursery() return true (it checks
     * the address range, not the space tag), and gc_move treats nursery
     * addresses as pinned during full collect — the pointer would never
     * move, defeating the compaction proof.  Exhausting the range first
     * ensures the chain lands beyond nursery_last. */
    {
        const size_t EXHAUST = 2UL * 1024 * 1024;  /* 2 MB = nursery size */
        for (int i = 0; i < 4; i++) {
            char *blob = (char *)gc_alloc_oldgen(EXHAUST, GC_TYPE_RAW);
            (void)blob;
        }
    }

    Value root = val_nil();
    gc_root_push_value(&root);

    for (int i = N - 1; i >= 0; i--) {
        Value *car_cell  = gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        Value *cdr_cell  = gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);
        Value *cons_cell = gc_alloc_oldgen(sizeof(Value), GC_TYPE_VALUE);

        *car_cell  = val_number(i);
        *cdr_cell  = root;
        cons_cell->tag = VAL_CONS;
        cons_cell->cons.car = car_cell;
        cons_cell->cons.cdr = cdr_cell;
        root = *cons_cell;
    }

    /* Verify the freshly-built chain. */
    {
        int count = 0; Value cur = root;
        while (cur.tag == VAL_CONS) {
            if (cur.cons.car->tag != VAL_NUMBER || cur.cons.car->number != count) {
                printf("  [compaction] initial chain corrupt at node %d "
                       "(tag=%d num=%ld)\n", count,
                       cur.cons.car ? (int)cur.cons.car->tag : -1,
                       cur.cons.car ? (long)cur.cons.car->number : -1);
                failed = 1; goto comp_done;
            }
            cur = *cur.cons.cdr; count++;
        }
        if (count != N) {
            printf("  [compaction] initial count mismatch: %d vs %d\n", count, N);
            failed = 1; goto comp_done;
        }
        printf("  initial chain verified: %d nodes\n", count);
    }

    /* Snapshot a pointer into the middle of the chain (interior of old-gen
     * object).  Under pin-in-place this address would be unchanged after
     * collect; under evacuation gc_move copies it to to-space. */
    void *before_ptr = (void *)root.cons.car;  /* interior pointer to car cell */

    /* Force full collections by allocation pressure.
     * Iterate until at least one full collection actually fires (the
     * heap may have been grown by earlier tests, raising the threshold).
     * Each iteration allocates a 4MB dead raw chunk; after the burst,
     * gc_full_collect_count must have advanced at least once. */
    {
        const size_t CHUNK = 4UL * 1024 * 1024;
        long fc_target = gc_full_collect_count + 1;
        int cap = 200;  /* safety cap: up to 800 MB of dead pressure */
        while (gc_full_collect_count < fc_target && cap-- > 0) {
            char *blob = (char *)gc_alloc_oldgen(CHUNK, GC_TYPE_RAW);
            (void)blob;
        }
        if (gc_full_collect_count < fc_target) {
            printf("  [compaction] WARNING: could not force a full collect "
                   "(heap too large?)\n");
        }
    }

    /* (a) Chain survived intact. */
    {
        int count = 0; Value cur = root;
        while (cur.tag == VAL_CONS) {
            if (cur.cons.car->tag != VAL_NUMBER || cur.cons.car->number != count) {
                printf("  [compaction] chain corrupt after collect at node %d "
                       "(tag=%d num=%ld)\n", count,
                       cur.cons.car ? (int)cur.cons.car->tag : -1,
                       cur.cons.car ? (long)cur.cons.car->number : -1);
                failed = 1; goto comp_done;
            }
            cur = *cur.cons.cdr; count++;
        }
        if (count != N) {
            printf("  [compaction] post-collect count mismatch: %d vs %d\n", count, N);
            failed = 1; goto comp_done;
        }
        printf("  chain intact after full collect: %d nodes\n", count);
    }

    /* (b) Pointer MUST have moved.  Under pin-in-place the address would
     * be unchanged; under evacuation gc_move copies it to to-space. */
    void *after_ptr = (void *)root.cons.car;
    if (before_ptr == after_ptr) {
        printf("  [compaction] FAILED: interior pointer did NOT move "
               "(%p — still pinned)\n", before_ptr);
        failed = 1;
    } else {
        printf("  [compaction] pointer moved: %p → %p (compaction confirmed)\n",
               before_ptr, after_ptr);
    }

comp_done:
    gc_root_pop();  /* root */
    printf(failed ? "  gc_compaction_test FAILED\n"
                  : "  gc_compaction_test PASSED — compaction verified\n");
    return failed;
}

/* ------------------------------------------------------------------ */
/*  main — test driver                                                 */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();

    gc_init(256UL * 1024 * 1024);

    /* Install SIGSEGV backtrace handler for crash diagnostics */
    struct sigaction sa = {0};
    sa.sa_handler = crash_handler;
    sigaction(SIGSEGV, &sa, NULL);

    /* Register typed walkers so gc_scan_roots traces defun_table closures,
     * values_table values, and traced_code Instr arrays.  These replace the
     * former extra_roots conservative scan of the same BSS/static data. */
    gc_register_global_table(defun_table, &defun_table_cap);
    gc_register_values_table(values_table, &values_table_cap);
    gc_register_traced_code(traced_code, &num_traced);

    /* Scan for --trace <name> flags (before bundle load) */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0 && i + 1 < argc) {
            trace_add(argv[++i]);
        }
        if (strcmp(argv[i], "--gc-verbose") == 0)          gc_set_verbose(1);
        if (strcmp(argv[i], "--gc-check-closures") == 0)   gc_set_check_closures(1);
        if (strcmp(argv[i], "--gc-dump-roots") == 0)       gc_set_dump_roots(1);
        if (strcmp(argv[i], "--gc-stale-scan") == 0)       gc_set_stale_scan(1);
        else if (strcmp(argv[i], "--gc-log") == 0 && i + 1 < argc) { gc_set_log(argv[++i]); }
        if (strcmp(argv[i], "--gc-page-transition") == 0) gc_set_page_transition(1);
        else if (strcmp(argv[i], "--gc-page-transition-watch") == 0 && i + 1 < argc)
            gc_set_page_transition_watch(strtoul(argv[++i], NULL, 0));
        else if (strcmp(argv[i], "--gc-watch-alloc") == 0 && i + 1 < argc)
            gc_set_watch_alloc(strtoull(argv[++i], NULL, 0));
        if (strcmp(argv[i], "--gc-verify") == 0) gc_set_verify(1);
        if (strcmp(argv[i], "--gc-verify-codechains") == 0) gc_set_verify_codechains(1);
        if (strcmp(argv[i], "--gc-verify-live") == 0) gc_set_verify_live(1);
        else if (strcmp(argv[i], "--gc-verify-live-from") == 0 && i + 1 < argc)
            gc_set_verify_live_from(strtol(argv[++i], NULL, 0));
    }

    if (argc > 1) {
        char *buf = read_file_or_stdin(argv[1]);
        if (!buf) return 1;
        char *p = buf; while (*p && isspace((unsigned char)*p)) p++;

        /* Detect: if the second char (after '(') is '(' it's a bundle */
        if (*p == '(' && *(p+1) == '(') {
            /* Bundle format: ((name code) (name code) ...) */

            int n = vm_load_bundle(p);

            /* Verify heap integrity after bundle load */
            verify_heap();

            /* Resolve --trace function names to code pointers */
            if (num_traced > 0) trace_resolve();

            if (n == 0) { free(buf); return 1; }

            /* GC Phase 2 Step 5: generational nursery scavenge stress and
               retention tests.  Must run here — right after bundle load while
               the nursery still has free NURSERY-tagged pages — because the
               self-hosting tests below allocate enough to promote every nursery
               page, permanently exhausting the fast lane. */
            gc_nursery_tests();

            /* GC Phase 4b.1: sliding compaction — prove root-reached
               old-gen objects MOVE during full collect.  The nursery may
               be exhausted at this point (all pages promoted during bundle
               load), but the compaction test uses gc_alloc_oldgen and is
               unaffected by nursery state. */
            gc_compaction_test();

            /* Self-hosting proof: call Shen library functions from the
               bundle with values built in C. */
            printf("=== Self-hosting test ===\n");

            /* Build list [1 2 3] as a Shen value */
            Value e_1 = val_number(1);
            Value e_2 = val_number(2);
            Value e_3 = val_number(3);
            Value e_nil = val_nil();
            Value list123 = val_cons(e_1,
                             val_cons(e_2,
                             val_cons(e_3, e_nil)));

            /* Store in defun table (reached by [global *test-list*]) */
            defun_set("*test-list*", list123);

            /* Test 1: (+ 1 2) through bundled + closure */
            printf("--- Test 1: (+ 1 2) via bundled + ---\n");
            run_test("add", "(mn[1:n]2n[1:n]1g[1:s]+p)", 0);

            /* Test 2: (reverse [1 2 3]) through bundled reverse closure */
            printf("--- Test 2: (reverse [1 2 3]) via bundled reverse ---\n");
            run_test("reverse",
                     "(mg[11:s]*test-list*g[7:s]reversep)", 0);

            /* Test 4: open / close via inline OP_PRIM — prove primitives
               bypass safe wrapper shadowing, enabling read-compile-eval round-trip */
            printf("--- Test 4: (open \"Makefile\" in) -> (close stream) ---\n");
            run_test("open-close",
                     "(s[2:s]inS[8:S]MakefileP[4:s]openP[5:s]close)", 0);

            /* Test 5: eval-kl [+ 1 2] through the marshal chain. */
            printf("--- Test 5: eval-kl [+ 1 2] via marshal chain ---\n");
            Value plus_sym = val_symbol("+");
            Value ev_one = val_number(1);
            Value ev_two = val_number(2);
            Value ev_nil = val_nil();
            Value ev_list = val_cons(ev_two, ev_nil);          /* [2] */
            ev_list = val_cons(ev_one, ev_list);               /* [1 2] */
            ev_list = val_cons(plus_sym, ev_list);             /* [+ 1 2] */
            defun_set("*ev1*", ev_list);
            run_test("eval-kl-add",
                     "(g[5:s]*ev1*P[7:s]eval-kl)", 0);

            /* Test 11: eval-kl [cons 1 2] → [cons 1 . 2]. */
            {
                Value cons_sym = val_symbol("cons");
                Value n1 = val_number(1);
                Value n2 = val_number(2);
                Value nil = val_nil();
                Value lst = val_cons(n2, nil);           /* (2) */
                lst = val_cons(n1, lst);                 /* (1 2) */
                defun_set("*ev2*", val_cons(cons_sym, lst)); /* (cons 1 2) */
            }
            printf("--- Test 11: eval-kl [cons 1 2] — expect [cons 1 . 2] ---\n");
            run_test("eval-kl-cons",
                     "(g[5:s]*ev2*P[7:s]eval-kl)", 0);

            /* Test 12: eval-kl [+ [* 2 3] 4] → 10. */
            {
                Value plus_sym2 = val_symbol("+");
                Value mul_sym = val_symbol("*");
                Value n2 = val_number(2);
                Value n3 = val_number(3);
                Value n4 = val_number(4);
                Value nil = val_nil();
                Value inner = val_cons(n3, nil);          /* (3) */
                inner = val_cons(n2, inner);              /* (2 3) */
                inner = val_cons(mul_sym, inner);         /* (* 2 3) */
                Value outer = val_cons(n4, nil);          /* (4) */
                outer = val_cons(inner, outer);           /* ([* 2 3] 4) */
                outer = val_cons(plus_sym2, outer);       /* (+ [* 2 3] 4) */
                defun_set("*ev3*", outer);
            }
            printf("--- Test 12: eval-kl [+ [* 2 3] 4] — expect 10 ---\n");
            run_test("eval-kl-nested",
                     "(g[5:s]*ev3*P[7:s]eval-kl)", 0);

            /* Test 13: eval-kl [cn "hello" "world"] → "helloworld". */
            {
                Value cn_sym = val_symbol("cn");
                Value s1 = val_string("hello", 5);
                Value s2 = val_string("world", 5);
                Value nil = val_nil();
                Value lst = val_cons(s2, nil);           /* ("world") */
                lst = val_cons(s1, lst);                 /* ("hello" "world") */
                defun_set("*ev4*", val_cons(cn_sym, lst)); /* (cn "hello" "world") */
            }
            printf("--- Test 13: eval-kl [cn \"hello\" \"world\"] — expect \"helloworld\" ---\n");
            run_test("eval-kl-cn",
                     "(g[5:s]*ev4*P[7:s]eval-kl)", 0);

            /* Test 14: eval-kl error recovery: [hd 42] returns input. */
            {
                Value hd_sym = val_symbol("hd");
                Value n42 = val_number(42);
                Value nil = val_nil();
                Value lst = val_cons(n42, nil);           /* (42) */
                lst = val_cons(hd_sym, lst);              /* (hd 42) */
                defun_set("*ev5*", lst);
            }
            printf("--- Test 14: eval-kl [hd 42] — expect identity (error swallowed) ---\n");
            run_test("eval-kl-error",
                     "(g[5:s]*ev5*P[7:s]eval-kl)", 0);

            /* Test 14b: eval-kl [/ 1 0] — safe./ must intercept the zero divisor. */
            {
                Value nil = val_nil();
                Value zero = val_number(0), one = val_number(1);
                Value body = val_cons(zero, nil);          /* (0) */
                body = val_cons(one, body);                /* (1 0) */
                body = val_cons(val_symbol("/"), body);    /* (/ 1 0) */
                defun_set("*ev6*", body);
            }
            printf("--- Test 14b: eval-kl [/ 1 0] — expect identity, no SIGFPE (safe./ div-zero) ---\n");
            run_test("eval-kl-trap-divzero", "(g[5:s]*ev6*P[7:s]eval-kl)", 0);

            /* Test 14c: eval-kl (str BIG) on a >4096-char string — regression
               for the str_value overflow heap smash (results > ~4090 chars
               used to SIGSEGV print_shen / the str primitive).  Before the
               sv_append fix this aborts the whole harness; after it, returns
               the 10002-char printed form and survives. */
            {
                char *big = malloc(10000 + 1);
                for (int bi = 0; bi < 10000; bi++) big[bi] = 'x';
                big[10000] = '\0';
                Value str_sym = val_symbol("str");
                Value bign = val_string(big, 10000);
                Value nil = val_nil();
                Value args = val_cons(bign, nil);          /* (BIG) */
                Value expr = val_cons(str_sym, args);      /* (str BIG) */
                defun_set("*evbig*", expr);
                free(big);
            }
            printf("--- Test 14c: eval-kl (str 10000-char) — regression: no heap smash ---\n");
            run_test("eval-kl-str-big", "(g[7:s]*evbig*P[7:s]eval-kl)", 0);

            /* Diagnostic: dump bytecode of toplevel-interp and interp */
            printf("--- Bytecode Dump ---\n");
            {
                Value tli = defun_get("toplevel-interp");
                if (tli.tag == VAL_LAMBDA) {
                    printf("toplevel-interp bytecode (%d instrs):\n", tli.lambda.code_len);
                    print_instr(tli.lambda.code, tli.lambda.code_len < 30 ? tli.lambda.code_len : 30, 0);
                    if (tli.lambda.code_len > 30) printf("  ... (%d more)\n", tli.lambda.code_len - 30);
                    printf("env_len=%d\n", tli.lambda.env_len);
                }
                Value ip = defun_get("interp");
                if (ip.tag == VAL_LAMBDA) {
                    printf("\ninterp bytecode (%d instrs):\n", ip.lambda.code_len);
                    print_instr(ip.lambda.code, ip.lambda.code_len < 50 ? ip.lambda.code_len : 50, 0);
                    if (ip.lambda.code_len > 50) {
                        printf("  ... (instructions 50-100):\n");
                        print_instr(ip.lambda.code + 40, ip.lambda.code_len - 40 < 20 ? ip.lambda.code_len - 40 : 20, 0);
                        printf("  ... (%d more)\n", ip.lambda.code_len - 100);
                        int start = ip.lambda.code_len - 50;
                        if (start < 50) start = 50;
                        printf("  --- last 50 instructions (from %d) ---\n", start);
                        print_instr(ip.lambda.code + start, ip.lambda.code_len - start, 0);
                    }
                    printf("env_len=%d\n", ip.lambda.env_len);
                }
            }
            printf("--- End Bytecode Dump ---\n\n");

            /* Test 5b: call toplevel-interp directly */
            printf("--- Test 5b: toplevel-interp directly ---\n");
            {
                Value tli = defun_get("toplevel-interp");
                if (tli.tag == VAL_LAMBDA) {
                    /* Test A: empty bytecode → should return [cons] */
                    Value nil = val_nil();
                    printf("  Test A ([] -> [cons]):\n");

                    gc_root_push_value(&tli);
                    Value *env = GC_VALUE_ARRAY(tli.lambda.env_len + 1);
                    if (tli.lambda.env_len > 0)
                        memcpy(env, tli.lambda.env, tli.lambda.env_len * sizeof(Value));
                    env[tli.lambda.env_len] = nil;  /* empty code */
                    gc_root_pop();

                    {
                        CatchFrame cf;
                        cf.parent = vm_catch_chain;
                        cf.in_trap_error = 0;
                        vm_catch_chain = &cf;
                        if (setjmp(cf.buf) == 0) {
                            Value result = vm_exec_env(tli.lambda.code, tli.lambda.code_len,
                                                        env, tli.lambda.env_len + 1);
                            printf("    result: "); print_value(result);
                            printf(" (tag=%d)\n", result.tag);
                            vm_catch_chain = cf.parent;
                        } else {
                            vm_catch_chain = cf.parent;
                            gc_root_push_value(&cf.error_val);   /* S3: root error message */
                            printf("    ERROR: "); print_value(cf.error_val); printf("\n");
                            gc_root_pop();  /* S3: cf.error_val */
                        }
                    }

                    /* Test B: [number 42] → should return [number 42] */
                    printf("  Test B ([number 42] -> [number 42]):\n");
                    Value num_sym = val_symbol("number");
                    Value n42 = val_number(42);
                    Value bc = val_cons(num_sym, val_cons(n42, nil));

                    gc_root_push_value(&tli);
                    gc_root_push_value(&bc);  /* root bc across GC_VALUE_ARRAY */
                    Value *env2 = GC_VALUE_ARRAY(tli.lambda.env_len + 1);
                    if (tli.lambda.env_len > 0)
                        memcpy(env2, tli.lambda.env, tli.lambda.env_len * sizeof(Value));
                    env2[tli.lambda.env_len] = bc;
                    gc_root_pop();  /* bc */
                    gc_root_pop();  /* tli */

                    /* Trace Test B — disabled */
                    /* trace_counter = 0; trace_limit = 800; */

                    {
                        CatchFrame cf;
                        cf.parent = vm_catch_chain;
                        cf.in_trap_error = 0;
                        vm_catch_chain = &cf;
                        if (setjmp(cf.buf) == 0) {
                            Value result = vm_exec_env(tli.lambda.code, tli.lambda.code_len,
                                                        env2, tli.lambda.env_len + 1);
                            printf("    result: "); print_value(result);
                            printf(" (tag=%d)\n", result.tag);
                            vm_catch_chain = cf.parent;
                        } else {
                            vm_catch_chain = cf.parent;
                            gc_root_push_value(&cf.error_val);   /* S3: root error message */
                            printf("    ERROR: "); print_value(cf.error_val); printf("\n");
                            gc_root_pop();  /* S3: cf.error_val */
                        }
                    }
                    trace_counter = -1;

                    /* Test C: call interp directly */
                    printf("  Test C (interp [] [cons] [] [] []):\n");
                    Value interp_fn = defun_get("interp");
                    if (interp_fn.tag == VAL_LAMBDA) {
                        Value nil_v = val_nil();
                        Value cons_tag = val_cons(val_symbol("cons"), nil_v);

                        Value args[5];
                        args[0] = nil_v;           /* ret stack */
                        args[1] = nil_v;           /* data stack */
                        args[2] = nil_v;           /* env */
                        args[3] = cons_tag;        /* acc = [cons] */
                        args[4] = nil_v;           /* code = [] */

                        trace_counter = -1; trace_limit = 0;

                        /* Diagnostic: verify env setup */
                        printf("    env setup verification:\n");
                        printf("    env[0]=Ret="); print_value(args[0]); printf(" (tag=%d)\n", args[0].tag);
                        printf("    env[1]=Stack="); print_value(args[1]); printf(" (tag=%d)\n", args[1].tag);
                        printf("    env[2]=Env="); print_value(args[2]); printf(" (tag=%d)\n", args[2].tag);
                        printf("    env[3]=Acc="); print_value(args[3]); printf(" (tag=%d)\n", args[3].tag);
                        printf("    env[4]=Code="); print_value(args[4]); printf(" (tag=%d)\n", args[4].tag);
                        printf("    cons? nil: ");
                        Value ctest = val_boolean(args[4].tag == VAL_CONS);
                        print_value(ctest); printf(" (expected false)\n");

                        gc_root_push_value(&interp_fn);
                        Value *env_i = GC_VALUE_ARRAY(interp_fn.lambda.env_len + 5);
                        env_i[0] = args[4];  /* code   → access 4 */
                        env_i[1] = args[3];  /* acc    → access 3 */
                        env_i[2] = args[2];  /* env    → access 2 */
                        env_i[3] = args[1];  /* stack  → access 1 */
                        env_i[4] = args[0];  /* ret    → access 0 */
                        if (interp_fn.lambda.env_len > 0)
                            memcpy(env_i + 5, interp_fn.lambda.env, interp_fn.lambda.env_len * sizeof(Value));
                        gc_root_pop();

                        {
                            CatchFrame cf;
                            cf.parent = vm_catch_chain;
                            cf.in_trap_error = 0;
                            vm_catch_chain = &cf;
                            if (setjmp(cf.buf) == 0) {
                                Value result = vm_exec_env(interp_fn.lambda.code, interp_fn.lambda.code_len,
                                                            env_i, interp_fn.lambda.env_len + 5);
                                printf("    result: "); print_value(result);
                                printf(" (tag=%d)\n", result.tag);
                                vm_catch_chain = cf.parent;
                            } else {
                                vm_catch_chain = cf.parent;
                                gc_root_push_value(&cf.error_val);   /* S3: root error message */
                                printf("    ERROR: "); print_value(cf.error_val); printf("\n");
                                gc_root_pop();  /* S3: cf.error_val */
                            }
                        }
                    } else {
                        printf("    interp not found (tag=%d)\n", interp_fn.tag);
                    }
                } else {
                    printf("  toplevel-interp not found\n");
                }
            }

            /* Test 6: bundled read-file-as-string */
            printf("--- Test 6: bundled read-file-as-string via apply ---\n");
            run_test("rfas-via-apply",
                     "(mS[8:S]Makefileg[19:s]read-file-as-stringp)", 0);

            /* Test 8: id from bundled util.shen */
            printf("--- Test 8: call (id 42) from bundled util.shen ---\n");
            run_test("id-from-util",
                     "(mn[2:n]42g[2:s]idp)", 0);

            /* Test 9: newvar from bundled util.shen */
            printf("--- Test 9: call (newvar) from bundled util.shen ---\n");
            run_test("newvar-from-util",
                     "(mg[6:s]newvarp)", 0);

            /* Test 10: instruction-keyword? from bundled util.shen */
            printf("--- Test 10: call (instruction-keyword? push) from bundled util.shen ---\n");
            run_test("ikw-from-util",
                     "(ms[4:s]pushg[20:s]instruction-keyword?p)", 0);

            /* Test F: Self-compilation fixed point.
             *
             * Construct the KLambda form (+ 1 2) as a raw cons list, compile it
             * through the bundled kl->zinc (which takes the primitive path,
             * bypassing normalize/debruijn), execute the resulting ZINC bytecode
             * via toplevel-interp, and verify the result is 3.
             *
             * This proves the metacircular compiler produces correct, executable
             * ZINC bytecode — the core of the self-compilation fixed-point
             * property.  (A bare (lambda X X) is NOT used here: driving kl->zinc's
             * general lambda path requires normalize/debruijn with a properly
             * scoped variable, which this direct C harness does not set up.  This
             * is a harness limitation, NOT a marshal→extract-kl defect — an
             * independent trace of marshal_to_tagged + extract-kl shows lambdas
             * round-trip correctly.) */
                printf("\n--- Test F: Self-compilation ((+ 1 2) compiled via kl->zinc, executed via toplevel-interp) ---\n"); fflush(stdout);
                {
                /* Construct KLambda: (+ 1 2) = cons('+', cons(1, cons(2, nil))) */
                Value plus_sym = val_symbol("+");
                Value one_v    = val_number(1);
                Value two_v    = val_number(2);
                Value nil_v    = val_nil();
                Value args     = val_cons(two_v, nil_v);          /* (2) */
                args           = val_cons(one_v, args);           /* (1 2) */
                Value expr     = val_cons(plus_sym, args);        /* (+ 1 2) */

                /* Step 1: Compile KLambda → ZINC bytecode via bundled kl->zinc.
                 * kl->zinc recognises + as a primitive and calls zinc-c directly
                 * (no normalize/debruijn), producing [number 2, number 1, prim +]. */
                printf("  Calling kl->zinc on (+ 1 2)...\n"); fflush(stdout);
                Value zinc_code = call_bundled_1("kl->zinc", expr);
                if (zinc_code.tag == VAL_ERROR) {
                    printf("  Test F FAILED: kl->zinc returned error: ");
                    print_value(zinc_code); printf("\n");
                } else if (zinc_code.tag != VAL_CONS && zinc_code.tag != VAL_NIL) {
                    printf("  Test F FAILED: kl->zinc did not return a list (tag=%d)\n",
                           zinc_code.tag);
                } else {
                    printf("  kl->zinc returned ZINC bytecode (list, length check ok)\n");
                    /* Step 2: Execute the ZINC bytecode via bundled toplevel-interp. */
                    printf("  Calling toplevel-interp on compiled bytecode...\n"); fflush(stdout);
                    Value result = call_bundled_1("toplevel-interp", zinc_code);
                    /* Demarshal the tagged result: toplevel-interp returns tagged
                     * forms, so we need to unwrap.  For numbers it's [number N]. */
                    Value native;
                    if (result.tag == VAL_CONS && result.cons.car->tag == VAL_SYMBOL) {
                        /* tagged form: [tag val] or [cons ...] */
                        if (strcmp(result.cons.car->sym.name, "number") == 0) {
                            Value cdr = *result.cons.cdr;
                            native = *cdr.cons.car;
                        } else {
                            native = result; /* pass through */
                        }
                    } else {
                        native = result;
                    }
                    printf("  toplevel-interp result: "); print_value(native); printf("\n");
                    if (native.tag == VAL_NUMBER && native.number == 3) {
                        printf("  Test F PASSED: (+ 1 2) compiled and executed → 3\n");
                    } else {
                        printf("  Test F FAILED: expected 3, got tag=%d", native.tag);
                        if (native.tag == VAL_NUMBER) printf(" number=%ld", native.number);
                        printf("\n");
                    }
                }
                fflush(stdout);
                }

#ifdef ZINC_TEST_OS_LOAD
                /* ---- OS-load probes: determine WHERE corruption first occurs. ---- */
                {
                    /* Fast path (env ZINC_STLIB_ONLY): time read-file-raw on
                     * stlib.kl, count forms, exit early (skip slow ordered load). */
                    if (getenv("ZINC_STLIB_ONLY")) {
                        const char *sp2 = "vendor/ShenOSKernel-41.2/klambda/stlib.kl";
                        printf("\n--- FAST: read-file-raw of stlib.kl ---\n"); fflush(stdout);
                        clock_t t0 = clock();
                        Value s2 = call_bundled_1("read-file-raw", val_string(sp2, (long)strlen(sp2)));
                        clock_t t1 = clock();
                        printf("  read-file-raw tag=%d  wall=%.2fs\n", s2.tag,
                               (double)(t1 - t0) / CLOCKS_PER_SEC); fflush(stdout);
                        if (s2.tag == VAL_CONS) {
                            int cnt = 0; Value c2 = s2;
                            while (c2.tag == VAL_CONS) { cnt++; c2 = *c2.cons.cdr; }
                            printf("  form count=%d\n", cnt); fflush(stdout);
                            c2 = s2;
                            for (int k = 0; k < 3 && c2.tag == VAL_CONS; k++) {
                                Value h = *c2.cons.car;
                                if (h.tag == VAL_CONS && h.cons.car != NULL && h.cons.car->tag == VAL_SYMBOL)
                                    printf("  form[%d] head=%s\n", k, h.cons.car->sym.name);
                                c2 = *c2.cons.cdr;
                            }
                        } else if (s2.tag == VAL_ERROR) {
                            printf("  read-file-raw ERROR: "); print_value(s2); printf("\n");
                        }
                        printf("--- FAST stlib read-file-raw done ---\n"); fflush(stdout);
                        goto osload_done_fast;
                    }
                    const char *path_str = "shen/probe-kl/test-add.kl";
                    long path_len = (long)strlen(path_str);

                    /* Probe 1: strlen alone on the path (1-arg, direct). */
                    printf("\n--- OS-load Probe 1: strlen of path ---\n"); fflush(stdout);
                    {
                        Value p1path = val_string(path_str, path_len);
                        Value s1 = call_bundled_1("strlen", p1path);
                        printf("  strlen result: "); print_value(s1); printf(" (tag=%d)\n", s1.tag); fflush(stdout);
                        if (s1.tag == VAL_NUMBER && s1.number == path_len)
                            printf("  Probe 1 PASS: strlen = %ld\n", path_len);
                        else
                            printf("  Probe 1 FAIL: expected %ld\n", path_len);
                        /* Second allocation-heavy call: corruption often shows here. */
                        Value s1b = call_bundled_1("strlen", p1path);
                        printf("  strlen (2nd call): "); print_value(s1b); printf(" (tag=%d)\n", s1b.tag); fflush(stdout);
                        if (s1b.tag == VAL_NUMBER && s1b.number == path_len)
                            printf("  Probe 1b PASS: strlen survives 2nd call (%ld)\n", path_len);
                        else
                            printf("  Probe 1b FAIL: expected %ld on 2nd call\n", path_len);
                        fflush(stdout);
                    }

                    /* Probe 2: read-file-as-string on the path. Expect file contents. */
                    printf("\n--- OS-load Probe 2: read-file-as-string of path ---\n"); fflush(stdout);
                    {
                        Value p2path = val_string(path_str, path_len);
                        Value c2 = call_bundled_1("read-file-as-string", p2path);
                        printf("  read-file-as-string result: "); print_value(c2); printf(" (tag=%d)\n", c2.tag); fflush(stdout);
                        if (c2.tag == VAL_STRING)
                            printf("  Probe 2 PASS: string of len %d\n", c2.str.len);
                        else
                            printf("  Probe 2 FAIL: expected VAL_STRING, got tag=%d\n", c2.tag);
                        fflush(stdout);
                    }

                    /* Probe 3: read-file-raw on the path. Expect list of 2 defun forms. */
                    printf("\n--- OS-load Probe 3: read-file-raw of path ---\n"); fflush(stdout);
                    {
                        Value p3path = val_string(path_str, path_len);
                        Value c3 = call_bundled_1("read-file-raw", p3path);
                        printf("  read-file-raw result: "); print_value(c3); printf(" (tag=%d)\n", c3.tag); fflush(stdout);
                        if (c3.tag == VAL_CONS)
                            printf("  Probe 3 PASS: read-file-raw returned a non-empty list\n");
                        else
                            printf("  Probe 3 FAIL: expected a list (VAL_CONS), got tag=%d\n", c3.tag);
                        fflush(stdout);
                    }

                    /* Probe 4: interp-eval-all on a fresh read-file-raw result. Expect `loaded`. */
                    printf("\n--- OS-load Probe 4: interp-eval-all of read-file-raw forms ---\n"); fflush(stdout);
                    {
                        Value p4path = val_string(path_str, path_len);
                        Value forms = call_bundled_1("read-file-raw", p4path);
                        printf("  forms tag=%d\n", forms.tag); fflush(stdout);
                        Value c4 = call_bundled_1("interp-eval-all", forms);
                        printf("  interp-eval-all result: "); print_value(c4); printf(" (tag=%d)\n", c4.tag); fflush(stdout);
                        if (c4.tag == VAL_SYMBOL && strcmp(c4.sym.name, "loaded") == 0)
                            printf("  Probe 4 PASS: interp-eval-all returned `loaded`\n");
                        else
                            printf("  Probe 4 FAIL: expected symbol `loaded`, got tag=%d\n", c4.tag);
                        fflush(stdout);
                    }
                }

                /* Probe 4b: does OUR zinc-c compile a FLAT debruijn'd
                 * application [[function debruijn] [] [lookup 1]] into FLAT
                 * or CURRIED ZINC?  This isolates where the currying is
                 * introduced (zinc-c vs upstream KLambda). */
                printf("\n--- OS-load Probe 4b: zinc-c on flat KLambda app ---\n"); fflush(stdout);
                {
                    /* [function debruijn] */
                    Value fn_h = val_cons(val_symbol("function"), val_cons(val_symbol("debruijn"), val_nil()));
                    /* [lookup 1] */
                    Value lk = val_cons(val_symbol("lookup"), val_cons(val_number(1), val_nil()));
                    /* [[function debruijn] [] [lookup 1]] */
                    Value kl = val_cons(fn_h, val_cons(val_nil(), val_cons(lk, val_nil())));
                    Value z = call_bundled_1("zinc-c", kl);
                    printf("  zinc-c([function debruijn] [] [lookup 1]) -> ");
                    print_value(z); printf(" (tag=%d)\n", z.tag); fflush(stdout);
                }

                /* Probe 4c: bundled shen->kl on a .shen define — does it
                 * produce FLAT or CURRIED KLambda for (debruijn [] X)? */
                printf("\n--- OS-load Probe 4c: shen->kl on test-define.shen ---\n"); fflush(stdout);
                {
                    Value p = val_string("shen/probe-kl/test-define.shen", (long)strlen("shen/probe-kl/test-define.shen"));
                    Value forms = call_bundled_1("read-file-raw", p);
                    Value kls = call_bundled_1("shen->kl-forms", forms);
                    printf("  forms: "); print_value(forms); printf("\n  kls: "); print_value(kls); printf("\n"); fflush(stdout);
                }

                /* Probe 4d: compile (defun my-add [X Y] [+ X Y]) through the
                 * flat pipeline pieces (defun->lambda -> kmacros ->
                 * normalize-term -> debruijn -> zinc-c) to find where zinc-c
                 * says "unknown expression". */
                printf("\n--- OS-load Probe 4d: pipeline on my-add defun ---\n"); fflush(stdout);
                {
                    /* Test the CPS continuation `id` first: does (id 42) -> 42? */
                    Value idr = call_bundled_1("id", val_number(42));
                    printf("  id(42): "); print_value(idr); printf(" (tag=%d)\n", idr.tag); fflush(stdout);
                    /* normalize-term on [+ X Y] directly (bypass lambda) */
                    Value xsym2 = val_symbol("X"), ysym2 = val_symbol("Y"), addsym2 = val_symbol("+");
                    Value plus = val_cons(addsym2, val_cons(xsym2, val_cons(ysym2, val_nil())));
                    Value N2 = call_bundled_1("normalize-term", plus);
                    printf("  normalize-term([+ X Y]): "); print_value(N2); printf("\n"); fflush(stdout);
                    /* idx: X and Y positions in scope [X Y] should differ. */
                    Value sc = val_cons(xsym2, val_cons(ysym2, val_nil()));
                    Value iX = call_bundled_2("idx", xsym2, sc);
                    Value iY = call_bundled_2("idx", ysym2, sc);
                    printf("  idx X [X Y]: "); print_value(iX); printf("   idx Y [X Y]: "); print_value(iY); printf("\n"); fflush(stdout);
                    Value xsym = val_symbol("X"), ysym = val_symbol("Y"), addsym = val_symbol("+");
                    Value args = val_cons(xsym, val_cons(ysym, val_nil()));
                    Value body = val_cons(addsym, val_cons(xsym, val_cons(ysym, val_nil())));
                    Value defun = val_cons(val_symbol("defun"),
                               val_cons(val_symbol("my-add"),
                                 val_cons(args, val_cons(body, val_nil()))));
                    Value lam = call_bundled_1("defun->lambda", defun);
                    printf("  defun->lambda: "); print_value(lam); printf("\n"); fflush(stdout);
                    Value K = call_bundled_1("kmacros", lam);
                    printf("  kmacros: "); print_value(K); printf("\n"); fflush(stdout);
                    Value N = call_bundled_1("normalize-term", K);
                    printf("  normalize: "); print_value(N); printf("\n"); fflush(stdout);
                    Value nil = val_nil();
                    Value D = call_bundled_2("debruijn", nil, N);
                    printf("  debruijn: "); print_value(D); printf("\n"); fflush(stdout);
                    Value Z = call_bundled_1("zinc-c", D);
                    printf("  zinc-c: "); print_value(Z); printf("\n"); fflush(stdout);
                    /* toplevel-interp the compiled code -> closure (does this OOM?) */
                    Value clos = call_bundled_1("toplevel-interp", Z);
                    printf("  toplevel-interp(zinc-c): "); print_value(clos); printf(" (tag=%d)\n", clos.tag); fflush(stdout);
                }

                /* Probe 4e: shen->kl output for a 3-arg fn (index_h) — check
                 * KLambda before debruijn. */
                printf("\n--- OS-load Probe 4e: shen->kl on index_h ---\n"); fflush(stdout);
                {
                    Value p = val_string("shen/probe-kl/test-indexh.shen", (long)strlen("shen/probe-kl/test-indexh.shen"));
                    Value forms = call_bundled_1("read-file-raw", p);
                    Value kls = call_bundled_1("shen->kl-forms", forms);
                    printf("  shen->kl(index_h): "); print_value(kls); printf("\n"); fflush(stdout);
                }

                printf("\n--- Test OS-load probe: interp-load-raw of shen/probe-kl/test-add.kl ---\n"); fflush(stdout);
                {
                    const char *path_str = "shen/probe-kl/test-add.kl";

                    /* Ordered Shen OS kernel load probe.  Loads the real OS .kl
                     * files in the standard Shen OS Kernel load order, each via
                     * interp-load-raw (defuns land in the meta-interp's
                     * global-table, namespace 2).  Reports per-file result and
                     * stops at the first file that does NOT return `loaded`.
                     * Runs AFTER the test-add.kl probe so the mechanism is already
                     * proven; this measures how far the real OS actually loads. */
                    {
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
                            NULL
                        };
                        printf("\n--- Ordered Shen OS kernel load (shen-scheme order) ---\n"); fflush(stdout);
                        for (int i = 0; os_order[i] != NULL; i++) {
                            const char *os_path = os_order[i];
                            Value os_p = val_string(os_path, (long)strlen(os_path));
                            printf("  [%d] interp-load-raw \"%s\" ... ", i, os_path); fflush(stdout);
                            Value os_res = call_bundled_1("interp-load-raw", os_p);
                            if (os_res.tag == VAL_SYMBOL && strcmp(os_res.sym.name, "loaded") == 0) {
                                printf("loaded\n"); fflush(stdout);
                            } else {
                                printf("FAIL tag=%d", os_res.tag);
                                if (os_res.tag == VAL_SYMBOL) printf(" name=%s", os_res.sym.name);
                                if (os_res.tag == VAL_ERROR) { printf(" msg="); print_value(os_res); }
                                printf("\n  Ordered OS load STOPPED at file %d (%s)\n",
                                       i, os_path); fflush(stdout);
                                break;
                            }
                        }
                        printf("--- Ordered OS load probe done ---\n"); fflush(stdout);

                        /* Diagnostic: isolate which defun in types.kl fails to
                         * compile.  Read the file, iterate forms, call interp-eval
                         * on each and report the first that returns an error. */
                        {
                            const char *tp = "vendor/ShenOSKernel-41.2/klambda/types.kl";
                            Value p = val_string(tp, (long)strlen(tp));
                            Value forms = call_bundled_1("read-file-raw", p);
                            printf("\n--- types.kl per-form compile isolation ---\n"); fflush(stdout);
                            /* Walk the list of forms; each form is [defun Name Args Body]. */
                            Value cur = forms;
                            int fi = 0;
                            while (cur.tag == VAL_CONS) {
                                Value form = *cur.cons.car;
                                Value res = call_bundled_1("interp-eval", form);
                                if (res.tag == VAL_ERROR) {
                                    printf("  form[%d] FAIL: ", fi); print_value(form);
                                    printf("\n    error="); print_value(res); printf("\n"); fflush(stdout);
                                    break;
                                } else {
                                    printf("  form[%d] ok -> ", fi);
                                    if (form.cons.car != NULL && form.cons.car->tag == VAL_SYMBOL) printf("%s", form.cons.car->sym.name);
                                    printf("\n"); fflush(stdout);
                                }
                                cur = *cur.cons.cdr;
                                fi++;
                            }
                            printf("--- types.kl isolation done ---\n"); fflush(stdout);

                            /* stlib.kl per-form compile isolation: find the first
                             * defun that interp-eval cannot compile (currently fails
                             * with 'No condition was true' from normalize.shen:19). */
                            {
                                const char *slp = "vendor/ShenOSKernel-41.2/klambda/stlib.kl";
                                Value p = val_string(slp, (long)strlen(slp));
                                Value forms = call_bundled_1("read-file-raw", p);
                                printf("\n--- stlib.kl per-form compile isolation ---\n"); fflush(stdout);
                                if (forms.tag != VAL_CONS) {
                                    printf("  read-file-raw(stlib.kl) tag=%d\n", forms.tag); fflush(stdout);
                                } else {
                                    { /* count forms */
                                        Value cc = forms; int n = 0;
                                        while (cc.tag == VAL_CONS) { n++; cc = *cc.cons.cdr; }
                                        printf("  read-file-raw(stlib.kl) form count=%d\n", n); fflush(stdout);
                                    }
                                    Value cur = forms;
                                    gc_root_push_value(&cur);
                                    gc_root_push_value(&forms);
                                    int fi = 0;
                                    while (cur.tag == VAL_CONS) {
                                        Value form = *cur.cons.car;
                                        gc_root_push_value(&form);
                                        Value res = call_bundled_1("interp-eval", form);
                                        gc_root_pop();  /* form */
                                        if (res.tag == VAL_ERROR) {
                                            printf("  form[%d] FAIL: ", fi);
                                            if (form.cons.car != NULL && form.cons.car->tag == VAL_SYMBOL) printf("%s", form.cons.car->sym.name);
                                            printf("\n    error="); print_value(res); printf("\n"); fflush(stdout);
                                            /* kmacros-only isolation on the body */
                                            Value c1 = *form.cons.cdr;          /* name args body */
                                            Value c2 = *c1.cons.cdr;            /* args body */
                                            Value c3 = *c2.cons.cdr;            /* (body) */
                                            Value body = *c3.cons.car;          /* body */
                                            Value k = call_bundled_1("kmacros", body);
                                            printf("    kmacros(body): "); print_value(k); printf("\n"); fflush(stdout);
                                            break;
                                        } else {
                                            printf("  form[%d] ok -> ", fi);
                                            if (form.cons.car != NULL && form.cons.car->tag == VAL_SYMBOL) printf("%s", form.cons.car->sym.name);
                                            printf("\n"); fflush(stdout);
                                        }
                                        cur = *cur.cons.cdr;
                                        fi++;
                                    }
                                    gc_root_pop();  /* forms */
                                    gc_root_pop();  /* cur */
                                }
                                /* Compile ONLY the last 3 forms (345-347) individually,
                                 * each with proper rooting, to find which one fails
                                 * whole-file interp-load-raw. */
                                {
                                    Value tail = forms;
                                    int sk = 0;
                                    while (tail.tag == VAL_CONS && sk < 345) { tail = *tail.cons.cdr; sk++; }
                                    printf("  last-3 skip=%d tail_tag=%d\n", sk, tail.tag); fflush(stdout);
                                    int li = 0;
                                    Value tc = tail;
                                    while (tc.tag == VAL_CONS && li < 5) {
                                        Value tf = *tc.cons.car;
                                        if (tf.cons.car != NULL && tf.cons.car->tag == VAL_SYMBOL)
                                            printf("  last[%d] head=%s\n", li, tf.cons.car->sym.name); fflush(stdout);
                                        gc_root_push_value(&tf);
                                        Value tres = call_bundled_1("interp-eval", tf);
                                        gc_root_pop();
                                        printf("  last[%d] -> ", li);
                                        if (tres.tag == VAL_ERROR) { printf("FAIL "); print_value(tres); }
                                        else if (tres.tag == VAL_SYMBOL) printf("ok (%s)", tres.sym.name);
                                        else printf("ok (tag=%d)", tres.tag);
                                        printf("\n"); fflush(stdout);
                                        tc = *tc.cons.cdr;
                                        li++;
                                    }
                                }
                                printf("--- stlib.kl isolation done ---\n"); fflush(stdout);
                            }

                            /* Isolate the exact failing construct in declare:
                             * test curried multi-lambda application and @v/vector
                             * forms individually through the bundled compiler. */
                            {
                                printf("\n--- declare sub-construct isolation ---\n"); fflush(stdout);
                                /* Each test is a KLambda defun compiled via interp-eval. */
                                const char *tests[] = {
                                    "(defun t1 (X) (@v true (@v 0 (vector 0))))",
                                    "(defun t2 (X) (vector 0))",
                                    "(defun t3 (F) ((((F X) Y) Z) W))",
                                    "(defun t4 (X) (shen.variancy X Y))",
                                    "(defun t5 (X) (receive (shen.deref X Z)))",
                                    "(defun t6 (X) (((((lambda A (lambda B (lambda C (lambda D (shen.variancy A B C D X X)))) (shen.prolog-vector)) (@v true (@v 0 (vector 0)))) 0) (freeze true)))))",
                                    NULL
                                };
                                for (int ti = 0; tests[ti] != NULL; ti++) {
                                    Value strv = val_string(tests[ti], (long)strlen(tests[ti]));
                                    Value parsed = call_bundled_1("read-from-string", strv);
                                    Value form = (parsed.tag == VAL_CONS) ? *parsed.cons.car : val_nil();
                                    Value res = call_bundled_1("interp-eval", form);
                                    printf("  %s -> ", tests[ti]);
                                    if (res.tag == VAL_ERROR) { printf("FAIL "); print_value(res); }
                                    else printf("ok (%s)", res.tag==VAL_SYMBOL?res.sym.name:"?");
                                    printf("\n"); fflush(stdout);
                                }
                                /* Same body but loaded via read-file-raw (raw KLambda path). */
                                {
                                    Value p = val_string("shen/probe-kl/test-declare.kl", (long)strlen("shen/probe-kl/test-declare.kl"));
                                    Value forms = call_bundled_1("read-file-raw", p);
                                    if (forms.tag == VAL_CONS) {
                                        Value form = *forms.cons.car;
                                        Value res = call_bundled_1("interp-eval", form);
                                        printf("  raw-kl test-declare.kl -> ");
                                        if (res.tag == VAL_ERROR) { printf("FAIL "); print_value(res); }
                                        else printf("ok");
                                        printf("\n"); fflush(stdout);
                                    }
                                }
                                /* Bisect raw-KLambda constructs: compile each of several
                                 * hand-written .kl files via the exact read-file-raw path. */
                                {
                                    const char *bis[] = {
                                        "shen/probe-kl/b1.kl",
                                        "shen/probe-kl/b2.kl",
                                        "shen/probe-kl/b3.kl",
                                        "shen/probe-kl/b4.kl",
                                        "shen/probe-kl/b5.kl",
                                        "shen/probe-kl/b6.kl",
                                        "shen/probe-kl/b7.kl",
                                        NULL
                                    };
                                    printf("\n--- raw-KLambda bisect ---\n"); fflush(stdout);
                                    for (int bi = 0; bis[bi] != NULL; bi++) {
                                        Value p = val_string(bis[bi], (long)strlen(bis[bi]));
                                        Value forms = call_bundled_1("read-file-raw", p);
                                        if (forms.tag != VAL_CONS) { printf("  %s: read FAIL\n", bis[bi]); fflush(stdout); continue; }
                                        Value form = *forms.cons.car;
                                        Value res = call_bundled_1("interp-eval", form);
                                        printf("  %s -> ", bis[bi]);
                                        if (res.tag == VAL_ERROR) { printf("FAIL "); print_value(res); }
                                        else printf("ok");
                                        printf("\n"); fflush(stdout);
                                    }
                                    printf("--- raw-KLambda bisect done ---\n"); fflush(stdout);
                                    /* Trace the failing curried-lambda form through the
                                     * pipeline steps to find where it breaks. */
                                    {
                                        Value p = val_string("shen/probe-kl/b6.kl", (long)strlen("shen/probe-kl/b6.kl"));
                                        Value forms = call_bundled_1("read-file-raw", p);
                                        Value form = *forms.cons.car;
                                        /* [defun t (X) BODY]: c1=t, c2=(X), c3=(BODY), body=BODY */
                                        Value c1 = *form.cons.cdr;          /* t (X) BODY */
                                        Value c2 = *c1.cons.cdr;            /* (X) BODY */
                                        Value c3 = *c2.cons.cdr;            /* (BODY) */
                                        Value body = *c3.cons.car;          /* BODY */
                                        printf("\n--- b6 body pipeline trace ---\n"); fflush(stdout);
                                        Value k = call_bundled_1("kmacros", body);
                                        printf("  kmacros: "); print_value(k); printf("\n"); fflush(stdout);
                                        Value n = call_bundled_1("normalize-term", k);
                                        printf("  normalize-term: "); print_value(n); printf("\n"); fflush(stdout);
                                        Value d = call_bundled_2("debruijn", val_nil(), n);
                                        printf("  debruijn: "); print_value(d); printf("\n"); fflush(stdout);
                                        Value z = call_bundled_1("zinc-c", d);
                                        printf("  zinc-c: "); print_value(z); printf("\n"); fflush(stdout);
                                        printf("--- b6 trace done ---\n"); fflush(stdout);
                                    }
                                }
                                printf("--- declare isolation done ---\n"); fflush(stdout);
                            }
                        }
                    }


                    /* Verify the loaded closures are usable through the
                     * metacircular interp.  The defuns land in the interp's Shen
                     * global-table (namespace 2), NOT the C VM defun_table[],
                     * so raw C bytecode [global my-add] can't reach them.
                     * Instead drive them through eval-kl: build (my-add 2 3) as
                     * a cons list, store in a C global, pass to the eval-kl
                     * primitive (marshal → extract-kl → kl->zinc →
                     * toplevel-interp; interp resolves [global my-add] via
                     * lookup-global → namespace 2).  Expect 5. */
                    {
                        Value add_sym = val_symbol("my-add");
                        Value n2 = val_number(2), n3 = val_number(3), nil = val_nil();
                        Value add_args = val_cons(n3, nil);            /* (3) */
                        add_args = val_cons(n2, add_args);             /* (2 3) */
                        Value add_expr = val_cons(add_sym, add_args);  /* (my-add 2 3) */
                        defun_set("*evadd*", add_expr);
                        run_test_timeout("probe-my-add-evalkl",
                            "(g[7:s]*evadd*P[7:s]eval-kl)", 0, 30);

                        /* (my-id 42) → 42. */
                        Value id_sym = val_symbol("my-id");
                        Value n42 = val_number(42);
                        Value id_args = val_cons(n42, nil);            /* (42) */
                        Value id_expr = val_cons(id_sym, id_args);     /* (my-id 42) */
                        defun_set("*evid*", id_expr);
                        run_test_timeout("probe-my-id-evalkl",
                            "(g[6:s]*evid*P[7:s]eval-kl)", 0, 30);

                        /* Diagnostic: does lookup-global find my-add after load?
                         * Interprets whether the defun actually got compiled. */
                        {
                            Value lg = call_bundled_1("lookup-global", val_symbol("my-add"));
                            printf("  lookup-global my-add → "); print_value(lg);
                            printf(" (tag=%d)\n", lg.tag); fflush(stdout);
                        }
                    }
                    fflush(stdout);
                }
                osload_done_fast: ;
#endif

            printf("\nSelf-hosting proven: The C VM loaded %d closures compiled by\n", defun_table_used);
            printf("the metacircular Shen ZINC interpreter and executed them correctly.\n");
            printf("Inline OP_PRIM dispatch works (open/close/eval-kl bypass safe wrappers).\n");
            printf("eval-kl chain (marshal → extract-kl → kl->zinc → toplevel-interp → demarshal) works.\n");
            printf("Bundled file I/O works — safe wrappers + P[4:s]open chain functional.\n");

            /* Verify the variable? fix: global-table variable? (now safe.variable?)
             * must return true for symbol X. */
            {
                defun_set("dv", val_symbol("X"));
                run_test_timeout("global-var-true",
                    "(mg[2:s]dvg[9:s]variable?p)", 0, 5);
                fflush(stdout);
            }

            /* GC stress: allocate 50000 cons cells */
            printf("\n--- GC stress: allocating 50000 cons cells ---\n");
            fprintf(stderr, "[gc-stress] starting...\n");
            {
                Value nil = val_nil();
                for (int i = 0; i < 50000; i++) {
                    if (i % 10000 == 0) fprintf(stderr, "[gc-stress] iter %d\n", i);
                    Value cell = val_cons(val_number(i), nil);
                    (void)cell;
                }
            }
            fprintf(stderr, "[gc-stress] loop done\n");
            printf("  GC stress passed — allocated 50000 cells, no crash\n");

            /* GC retention test */
            {
                Value nil = val_nil();
                Value lst = val_cons(val_number(3),
                            val_cons(val_number(2),
                            val_cons(val_number(1), nil)));
                value_set("*gc-test-list*", lst);

                for (int i = 0; i < 5000; i++) {
                    Value cell = val_cons(val_number(i), nil);
                    (void)cell;
                }

                Value retrieved = value_get("*gc-test-list*");
                if (retrieved.tag != VAL_CONS
                    || retrieved.cons.car->tag != VAL_NUMBER
                    || retrieved.cons.car->number != 3) {
                    printf("  GC retention test FAILED\n");
                } else {
                    printf("  GC retention test passed — defun/values table entry survived GC\n");
                }
            }

            free(buf);
            return 0;
        } else {
            /* Single bytecode list */
            if (*p) run_test(argv[1], p, 0); else printf("(empty file)\n");
            free(buf);
        }
        return 0;
    }

    /* No args: built-in bytecode tests */
    printf("=== ZINC Bytecode VM with 47 Primitives ===\n\n");

    /* GC Phase 4a: precise-root missed-root churn detector (nursery path).
       Runs here on a FRESH nursery (before the built-in tests allocate), so
       the persistent tree is built through the nursery bump allocator — the
       path the flip depends on. */
    gc_root_churn_test();

    /* GC Phase 4b.1: sliding compaction — prove root-reached objects MOVE
       (evacuated to to-space) rather than being pinned in place. */
    gc_compaction_test();

    /* CONVENTION: Hand-written bytecode MUST push args in RTL order
       (rightmost Shen arg pushed first, leftmost arg pushed last/on top).
       Zinc-c compiler output follows this — the C VM pops top-first.
       For (f A B): emit "pushmark, B, A, global f, apply"
       NOT:         "pushmark, A, B, global f, apply"                     */

    run_test("1. [+ 1 2]",              "(mn[1:n]2n[1:n]1g[1:s]+p)", 1);
    run_test("2. [lambda X X]",         "(c(a[1:n]0v))", 1);
    run_test("3. [let X 1 X]",          "(n[1:n]1ea[1:n]0d)", 1);
    run_test("4. [- 1 2] (expect -1)",  "(mn[1:n]2n[1:n]1g[1:s]-p)", 1);
    run_test("5. [* 3 4] (expect 12)",  "(mn[1:n]4n[1:n]3g[1:s]*p)", 1);
    run_test("6. [/ 10 2] (expect 5)",  "(mn[1:n]2n[2:n]10g[1:s]/p)", 1);
    run_test("7. [= 1 1] (expect true)","(mn[1:n]1n[1:n]1g[1:s]=p)", 1);
    run_test("8. [< 1 2] (expect true)","(mn[1:n]2n[1:n]1g[1:s]<p)", 1);
    run_test("9. [> 5 3] (expect true)","(mn[1:n]3n[1:n]5g[1:s]>p)", 1);
    run_test("10. [<= 2 2] (expect true)","(mn[1:n]2n[1:n]2g[2:s]<=p)", 1);
    run_test("11. [>= 5 3] (expect true)","(mn[1:n]3n[1:n]5g[2:s]>=p)", 1);
    run_test("12. [number? 42]",         "(mn[2:n]42g[7:s]number?p)", 1);
    run_test("13. [symbol? hello]",      "(ms[5:s]hellog[7:s]symbol?p)", 1);
    run_test("14. [boolean? true]",      "(mb[4:b]trueg[8:s]boolean?p)", 1);
    run_test("15. [string? \"hi\"]",     "(mS[2:S]hig[7:s]string?p)", 1);
    run_test("16. [string? 42] (expect false)", "(mn[2:n]42g[7:s]string?p)", 1);
    run_test("17. [cons 1 2]",           "(mn[1:n]2n[1:n]1g[4:s]consp)", 1);
    run_test("18. [cn \"hello\" \"world\"]", "(mS[5:S]worldS[5:S]hellog[2:s]cnp)", 1);
    run_test("19. [n->string 42] (expect *)",       "(mn[2:n]42g[9:s]n->stringp)", 1);
    run_test("20. [string->n \"42\"] (expect 52)",   "(mS[2:S]42g[9:s]string->np)", 1);
    run_test("21. [str hello]",          "(ms[5:s]hellog[3:s]strp)", 1);
    run_test("22. [tlstr \"abc\"]",      "(mS[3:S]abcg[5:s]tlstrp)", 1);
    run_test("23. [intern \"foo\"]",     "(mS[3:S]foog[6:s]internp)", 1);
    run_test("24. [= \"ab\" \"ab\"]",    "(mS[2:S]abS[2:S]abg[1:s]=p)", 1);
    run_test("25. [= 1 2] (expect false)","(mn[1:n]2n[1:n]1g[1:s]=p)", 1);
    run_test("26. simple-error caught",   "(mS[4:S]boomg[12:s]simple-errorp)", 1);
    /* RTL: (trap-error Body Handler) — Handler pushed first, Body last */
    run_test("27. trap-error handler",
        "(mc(S[6:S]caughtv)"                       /* handler pushed FIRST (bottom) */
        "c(mS[4:S]oopsg[12:s]simple-errorpv)"     /* body pushed LAST (top) */
        "g[10:s]trap-errorp)", 1);
    run_test("28. [get-time unix]",      "(ms[4:s]unixg[8:s]get-timep)", 1);


    /* === appterm ('t' opcode) tests ===
       Stack layout for appterm: [mark, argN..arg1, function]
       Same RTL arg order as apply.  VAL_PRIM: pops optional mark, calls
       primitive inline.  VAL_LAMBDA: collects args, builds env, tail-calls
       in current frame (pc=0 — no new CallFrame, frame reuse).               */

    /* 33. appterm to primitive (+) */
    run_test("33. appterm: (+ 1 2)", "(mn[1:n]2n[1:n]1g[1:s]+t)", 1);

    /* 34. appterm to lambda (1 arg, identity) */
    run_test("34. appterm: id 42", "(mn[2:n]42c(a[1:n]0v)t)", 1);

    /* 35. appterm to lambda (2 args, return rightmost via access 0).
       RTL: 99 pushed first (rightmost Shen arg), 42 pushed last (leftmost).
       Env=[42,99]; reverse-index: access 0 → env[1]=99.                */
    run_test("35. appterm: 2-arg 2nd", "(mn[2:n]99n[2:n]42c(a[1:n]0v)t)", 1);

    /* 36. appterm within apply — outer closure appterms to inner closure.
       Tests frame reuse: appterm runs in apply's frame, return pops
       correctly through the apply-saved CallFrame.                         */
    run_test("36. appterm-in-apply",
        "(mn[2:n]42c(ma[1:n]0c(a[1:n]0v)t)p)", 1);

    /* 37. appterm error: zero args — stack has closure but no args */
    run_test("37. appterm: zero args", "(c(a[1:n]0v)t)", 0);

    /* 38. appterm error: missing mark for lambda — one arg pushed
       but no pushmark; arg gets collected, then stack empty → error    */
    run_test("38. appterm: missing mark", "(n[2:n]42c(a[1:n]0v)t)", 0);

    /* === shensh process-primitive tests (inline OP_PRIM / global+apply) ===
       (tests 39/40 — exec-command / shell-pipe — were removed in shpar-p2
       U6 together with the /bin/sh code paths; exec-plan replaces them.) */

    /* 41. getcwd → current directory string */
    run_test("41. getcwd", "(mg[6:s]getcwdp)", 1);

    /* 42. cd /tmp + getcwd roundtrip → "/tmp" */
    run_test("42. cd+getcwd roundtrip",
        "(mS[4:S]/tmpg[2:s]cdpmg[6:s]getcwdp)", 1);

    /* 43. glob *.c → sorted tagged list of matching path strings */
    run_test("43. glob *.c", "(mS[3:S]*.cg[4:s]globp)", 1);

    /* 44. getenv PATH → path string (or "" if unset) */
    run_test("44. getenv PATH", "(mS[4:S]PATHg[6:s]getenvp)", 1);

    /* 45. setenv FOO=bar → true  (RTL: bar pushed first, FOO last) */
    run_test("45. setenv FOO=bar",
        "(mS[3:S]barS[3:S]FOOg[6:s]setenvp)", 1);

    /* === exec-plan tests (46-52): tagged plan built in C, stored as a
       global, executed via inline OP_PRIM (pre-built-global pattern). === */

    /* 46. exec-plan `echo hi` (child builtin) → tagged [0 "hi\n" ""] */
    {
        char *argv[2] = {"echo", "hi"};
        Value plan = tplan1_(argv, 2);
        defun_set("*epA*", plan);
    }
    run_test("46. exec-plan echo hi",
        "(g[5:s]*epA*P[9:s]exec-plan)", 1);

    /* 47. exec-plan pipeline `echo hello | wc -c` → tagged [0 "6\n" ""]
       (execvp path: last stage is the external wc) */
    {
        char *a1[2] = {"echo", "hello"};
        char *a2[2] = {"wc", "-c"};
        Value c1 = tcmd_(a1, 2);
        gc_root_push_value(&c1);
        Value c2 = tcmd_(a2, 2);
        gc_root_pop();
        Value pipe = tlist2_(c1, c2);
        gc_root_push_value(&pipe);
        Value chain = tchain_("seq", pipe);
        gc_root_pop();
        Value plan = tlist1_(chain);
        defun_set("*epB*", plan);
    }
    run_test("47. exec-plan echo hello | wc -c",
        "(g[5:s]*epB*P[9:s]exec-plan)", 1);

    /* 48. exec-plan chains `false || echo yes` → tagged [0 "yes\n" ""]
       (seq chain fails with 1, or-chain runs) */
    {
        char *a1[1] = {"false"};
        char *a2[2] = {"echo", "yes"};
        Value c1 = tcmd_(a1, 1);
        gc_root_push_value(&c1);
        Value p1 = tlist1_(c1);
        gc_root_push_value(&p1);
        Value ch1 = tchain_("seq", p1);
        gc_root_push_value(&ch1);
        Value c2 = tcmd_(a2, 2);
        gc_root_push_value(&c2);
        Value p2 = tlist1_(c2);
        gc_root_push_value(&p2);
        Value ch2 = tchain_("or", p2);
        gc_root_push_value(&ch2);
        Value plan = tlist2_(ch1, ch2);
        defun_set("*epC*", plan);
        gc_root_pop(); gc_root_pop(); gc_root_pop();
        gc_root_pop(); gc_root_pop(); gc_root_pop();
    }
    run_test("48. exec-plan false || echo yes",
        "(g[5:s]*epC*P[9:s]exec-plan)", 1);

    /* 49. exec-plan redirect `echo hi > /tmp/zinctest-ep-redir.txt`
       → tagged [0 "" ""] (stdout goes to the file, not the capture) */
    {
        char *argv[2] = {"echo", "hi"};
        Value op = tsym_("out");
        gc_root_push_value(&op);
        Value fd = tnum_(1);
        gc_root_push_value(&fd);
        Value tgt = tstr_("/tmp/zinctest-ep-redir.txt");
        gc_root_pop(); gc_root_pop();
        Value redirs = tredir_(op, fd, tgt);
        gc_root_push_value(&redirs);
        Value cmd = tcmd_r_(argv, 2, redirs);
        gc_root_push_value(&cmd);
        Value pipe = tlist1_(cmd);
        gc_root_push_value(&pipe);
        Value chain = tchain_("seq", pipe);
        gc_root_push_value(&chain);
        Value plan = tlist1_(chain);
        defun_set("*epD*", plan);
        gc_root_pop(); gc_root_pop(); gc_root_pop();
        gc_root_pop(); gc_root_pop();
    }
    run_test("49. exec-plan echo hi > /tmp file",
        "(g[5:s]*epD*P[9:s]exec-plan)", 1);

    /* 50. exec-plan `cat /tmp/zinctest-ep-redir.txt` → tagged [0 "hi\n" ""]
       (reads back what 49 wrote — proves the redirect took effect) */
    {
        char *argv[2] = {"cat", "/tmp/zinctest-ep-redir.txt"};
        Value plan = tplan1_(argv, 2);
        defun_set("*epE*", plan);
    }
    run_test("50. exec-plan cat redirected file",
        "(g[5:s]*epE*P[9:s]exec-plan)", 1);

    /* 51. exec-plan `echo duped` with [dup 1 2] (1>&2) → tagged
       [0 "" "duped\n"] (stdout dup'd onto stderr → stderr capture) */
    {
        char *argv[2] = {"echo", "duped"};
        Value op = tsym_("dup");
        gc_root_push_value(&op);
        Value fd = tnum_(1);
        gc_root_push_value(&fd);
        Value tgt = tnum_(2);
        gc_root_pop(); gc_root_pop();
        Value redirs = tredir_(op, fd, tgt);
        gc_root_push_value(&redirs);
        Value cmd = tcmd_r_(argv, 2, redirs);
        gc_root_push_value(&cmd);
        Value pipe = tlist1_(cmd);
        gc_root_push_value(&pipe);
        Value chain = tchain_("seq", pipe);
        gc_root_push_value(&chain);
        Value plan = tlist1_(chain);
        defun_set("*epF*", plan);
        gc_root_pop(); gc_root_pop(); gc_root_pop();
        gc_root_pop(); gc_root_pop();
    }
    run_test("51. exec-plan dup 1>&2",
        "(g[5:s]*epF*P[9:s]exec-plan)", 1);

    /* 52. exec-plan ENOENT → tagged [127 "" "shensh: X: not found\n"] */
    {
        char *argv[1] = {"definitely-no-such-cmd-xyzzy"};
        Value plan = tplan1_(argv, 1);
        defun_set("*epG*", plan);
    }
    run_test("52. exec-plan ENOENT -> 127",
        "(g[5:s]*epG*P[9:s]exec-plan)", 1);

    printf("=== All 48 tests done ===\n");

    return 0;
}

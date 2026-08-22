/*
 * zincvm.c — ZINC bytecode parser and virtual machine
 *
 * Parses the canonical s-expression bytecode format produced by
 * compile.shen (nat->csexp) and executes it with a register/stack
 * machine matching the Shen ZINC interpreter semantics.
 *
 * Grammar:
 *   csexp-list   ::= "(" elem* ")"
 *   elem         ::= opcode | csexp-atom | csexp-list
 *   csexp-atom   ::= "[" len ":" type "]" value
 *   len          ::= [0-9]+    (decimal, number of bytes in value)
 *   type         ::= "s" | "n" | "S" | "b"
 *
 * Opcodes (single characters):
 *   m  pushmark    p  apply         u  push
 *   r  grab        v  return        e  let
 *   d  endlet      t  appterm
 *   a  access      g  global        f  jmpf
 *   j  jmp         c  cur           n  number
 *   S  string      s  symbol        b  boolean
 *   P  prim
 *
 * Compile: gcc -Wall -Wextra -o zincvm zincvm.c
 * Test:    ./zincvm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <stdbool.h>

#include <stdint.h>
#include "gc.h"
#include "symbol_static.h"

/* Cheney GC: mostly-copying semi-space collector.  gc_alloc returns
 * zeroed memory.  Call gc_init() once before any allocation.
 * Roots are precise-only (shadow stack via gc_root_push_* /
 * gc_register_global_table / gc_register_traced_code); there is no
 * conservative C-stack scan or extra_roots mechanism. */
/* GC_VALUE, GC_STR, GC_VALUE_ARRAY, and value types are in zincvm.h */

/* ------------------------------------------------------------------ */
/*  Value types (shared with gc.c via zinctypes.h)                     */
/* ------------------------------------------------------------------ */

#include "zincvm.h"

/* ---- GC scanning functions (called by gc.c scavenger) ----
 *
 * gc_scan_value and gc_evacuate are mode-agnostic: they serve both full
 * collect (evacuate to next_space) and nursery scavenge (nursery→old-gen),
 * dispatched by gc_move via in_scavenge.  gc_scan_value evacuates all
 * GC-managed pointers within a Value; gc_evacuate updates a single pointer
 * slot via gc_move. */

/* gc_move is implemented in gc.c */
void *gc_move(void *p);

/* gc_evacuate: update a single pointer slot to point to the evacuated copy */
void gc_evacuate(void **slot) {
    *slot = gc_move(*slot);
}

/* gc_scan_value: evacuate all GC-managed pointers within a Value */
void gc_scan_value(Value *v) {
    switch (v->tag) {
    case VAL_CONS:
        gc_evacuate((void **)&v->cons.car);
        gc_evacuate((void **)&v->cons.cdr);
        break;
    case VAL_LAMBDA:
        gc_evacuate((void **)&v->lambda.code);
        gc_evacuate((void **)&v->lambda.env);
        break;
    case VAL_VECTOR:
        gc_evacuate((void **)&v->vector.data);
        break;
    case VAL_STRING:
        gc_evacuate((void **)&v->str.data);
        break;
    case VAL_ERROR:
        gc_evacuate((void **)&v->error.message);
        break;
    /* These types contain no GC-managed pointers:
     *   VAL_NUMBER, VAL_SYMBOL (sym.name is strdup'd C-heap),
     *   VAL_BOOLEAN, VAL_NIL, VAL_MARK,
     *   VAL_PRIM (prim.name is a literal string),
     *   VAL_STREAM (stream.file is FILE* / intptr_t)
     */
    default:
        break;
    }
}

/* True iff v references any GC object in the nursery.  Must mirror
 * exactly the pointer fields gc_scan_value evacuates. */
int value_references_nursery(Value *v) {
    switch (v->tag) {
    case VAL_CONS:    return gc_in_nursery(v->cons.car) || gc_in_nursery(v->cons.cdr);
    case VAL_LAMBDA:  return gc_in_nursery(v->lambda.code) || gc_in_nursery(v->lambda.env);
    case VAL_VECTOR:  return v->vector.data && gc_in_nursery(v->vector.data);
    case VAL_STRING:  return v->str.data && gc_in_nursery(v->str.data);
    case VAL_ERROR:   return v->error.message && gc_in_nursery(v->error.message);
    default:          return 0;
    }
}

/* ------------------------------------------------------------------ */
/*  Parser state                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *p;
    const char *start;
    int scratch;         /* 1 = produce C-heap operand strings for scratch buffer */
    Instr *scratch_buf;  /* current scratch buffer (to free on PARSE_ERROR) */
    int scratch_len;     /* number of valid Instr entries in scratch_buf */
    /* Side-slot rooting for closure_code children during recursive
     * parse_body.  Each OP_CUR allocates a malloc'd Instr** slot that
     * is pushed onto the GC shadow stack so the collector can see
     * nested closure_code arrays while the outer scratch buffer
     * (malloc'd, invisible to GC) holds copies. */
    Instr ***cc_slots;   /* growable array of malloc'd Instr** slots */
    int cc_len;          /* number of slots in use */
    int cc_cap;          /* capacity of cc_slots array */
} ParseState;

static jmp_buf parse_err_jmp;
static char parse_err_msg[256];

#define PARSE_ERROR(msg) do { \
    snprintf(parse_err_msg, sizeof(parse_err_msg), \
             "parse error at offset %ld: %s", \
             (long)(ps->p - ps->start), (msg)); \
    longjmp(parse_err_jmp, 1); \
} while (0)

/* ------------------------------------------------------------------ */
/*  Value helpers                                                      */
/* ------------------------------------------------------------------ */

Value val_number(long n) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_NUMBER; v.number = n; return v;
}
Value val_string(const char *data, int len) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_STRING;
    v.str.data = GC_STR(len);
    memcpy(v.str.data, data, len);
    v.str.data[len] = '\0';
    v.str.len = len; return v;
}
Value val_string_from(Value *src_slot, int off, int len) {
    /* Pins src_slot so its str.data survives the GC_STR alloc.
       For string/error primitives that read a popped Value's interior
       pointer across a gc_alloc_atomic call. */
    gc_root_push_value(src_slot);
    char *dst = (char*)gc_alloc_atomic(len + 1);
    memcpy(dst, src_slot->str.data + off, len);
    dst[len] = '\0';
    gc_root_pop();
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_STRING; v.str.data = dst; v.str.len = len;
    return v;
}
/* Symbol intern: TWO stores, both returning a CANONICAL char* so that the QBE
   inline `=` fast path (symbol pointer-equality == strcmp-equality) is sound.

   1. STATIC store (vm/symbol_static.c, generated by tools/gen-symbol-static.py
      from the closed-world subset/meta-interp bundle): every symbol literal in
      the bundle lives in a fixed array addressed by a minimal perfect hash.
      symbol_static_lookup(name) returns the canonical pointer or NULL.

   2. DYNAMIC store (this file): every name NOT in the static set (OS .kl
      symbols loaded at runtime, gensym/newvar/intern output) is interned in an
      open-addressed table that EXPANDS (x2) when the load factor crosses ~70%
      and SHRINKS (halves) when it drops below ~25%.  Symbols are immortal (no
      GC pointers inside VAL_SYMBOL), so the strings are never freed — a
      resize only re-buckets the existing pointers, keeping every outstanding
      VAL_SYMBOL.sym.name valid and canonical. */
#define SYMBOL_DYN_INIT 256
#define SYMBOL_DYN_MAXLOAD 70   /* percent -> grow */
#define SYMBOL_DYN_MINLOAD 25   /* percent -> shrink */

static char **symbol_dyn = NULL;
static int symbol_dyn_cap = 0;
static int symbol_dyn_count = 0;

static unsigned int sym_intern_hash(const char *s) {
    unsigned int h = 5381;
    while (*s) h = ((h << 5) + h) + (unsigned char)*s++;
    return h;
}

/* (Re)size the dynamic table to a new power-of-two capacity and rehash every
   existing (immortal, never-freed) string pointer into it.  Only the bucket
   array is realloc'd; the char* values are moved, not copied/freed, so every
   outstanding VAL_SYMBOL.sym.name stays valid and canonical.  newcap must be
   a power of two. */
static void sym_dyn_resize(int newcap) {
    char **newtab = (char **)calloc(newcap, sizeof(char *));
    for (int i = 0; i < symbol_dyn_cap; i++) {
        char *s = symbol_dyn[i];
        if (!s) continue;
        unsigned int h = sym_intern_hash(s) & (newcap - 1);
        for (int j = 0; j < newcap; j++) {
            unsigned int idx = (h + j) & (newcap - 1);
            if (!newtab[idx]) { newtab[idx] = s; break; }
        }
    }
    free(symbol_dyn);
    symbol_dyn = newtab;
    symbol_dyn_cap = newcap;
}

/* Look up OR intern `name` in the dynamic store, returning its canonical
   pointer.  Grows before insert when the load factor is high; shrinks after
   (never here — symbols are immortal, but the hook is correct). */
static const char *sym_dyn_get(const char *name) {
    if (!symbol_dyn) sym_dyn_resize(SYMBOL_DYN_INIT);
    else if (symbol_dyn_count * 100 / symbol_dyn_cap > SYMBOL_DYN_MAXLOAD)
        sym_dyn_resize(symbol_dyn_cap * 2);

    unsigned int h = sym_intern_hash(name) & (symbol_dyn_cap - 1);
    for (int i = 0; i < symbol_dyn_cap; i++) {
        unsigned int idx = (h + i) & (symbol_dyn_cap - 1);
        char *existing = symbol_dyn[idx];
        if (!existing) break;  /* empty slot -> not in table yet */
        if (strcmp(existing, name) == 0) return existing;
    }
    /* Not found — insert.  Growth above guarantees a free slot is reachable. */
    for (int i = 0; i < symbol_dyn_cap; i++) {
        unsigned int idx = (h + i) & (symbol_dyn_cap - 1);
        if (!symbol_dyn[idx]) {
            char *dup = strdup(name);
            symbol_dyn[idx] = dup;
            symbol_dyn_count++;
            return dup;
        }
    }
    return strdup(name);  /* unreachable; defensive */
}

Value val_symbol(const char *name) {
    /* 1. Static (closed-world bundle) store first — O(1) MPH.  A name is
       canonical iff it is here OR in the dynamic store; never both, because we
       check static first and only fall through to dynamic when it misses. */
    const char *canon = symbol_static_lookup(name);
    if (!canon) canon = sym_dyn_get(name);
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_SYMBOL; v.sym.name = (char *)canon;
    return v;
}
Value val_boolean(int b) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_BOOLEAN; v.boolean = b; return v;
}
Value val_cons(Value car, Value cdr) {
    /* Pin car and cdr so their interior pointers survive the two gc_alloc
       calls below.  car_root is separately pinned (ROOT_PTR) because it is
       held only in a C local across the second gc_alloc; without this the
       conservative scan used to find it, but under precise-only roots (4a.6)
       it goes stale. */
    gc_root_push_value(&car);
    gc_root_push_value(&cdr);
    Value *car_cell = (Value*)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    Value *volatile car_root = car_cell;
    gc_root_push_ptr((void**)&car_root);
    Value *cdr_cell = (Value*)gc_alloc(sizeof(Value), GC_TYPE_VALUE);
    *car_root = car;
    *cdr_cell = cdr;
    gc_root_pop();  /* car_root */
    gc_root_pop();  /* cdr */
    gc_root_pop();  /* car */
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_CONS; v.cons.car = car_root; v.cons.cdr = cdr_cell;
    return v;
}
Value val_nil(void) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_NIL; return v;
}
Value val_lambda(Instr *code, int code_len, Value *env, int env_len) {
    /* env arrays are GC-allocated via gcalloc so GC traces captured
       Values when the closure is reachable (e.g. via global_table).
       code/env are rooted across GC_VALUE_ARRAY; v is a local NOT on
       the shadow stack, so v.lambda.code must be set AFTER allocating
       (GC may evacuate the code array; the rooted code param is updated
       but a stale v.lambda.code set before GC would not be). */
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_LAMBDA;
    if (env_len > 0) {
        gc_root_push_ptr((void**)&code);   /* root code across GC_VALUE_ARRAY */
        gc_root_push_ptr((void**)&env);    /* root env across GC_VALUE_ARRAY */
        v.lambda.env = GC_VALUE_ARRAY(env_len);
        memcpy(v.lambda.env, env, env_len * sizeof(Value));
        v.lambda.env_len = env_len;
        gc_root_pop();  /* env */
        gc_root_pop();  /* code */
    } else { v.lambda.env = NULL; v.lambda.env_len = 0; }
    /* Set code AFTER env allocation — v is not rooted so any pre-GC
       assignment would hold a stale interior pointer. */
    v.lambda.code = code; v.lambda.code_len = code_len;
    return v;
}
#define check_closure(cl, where) gc_check_closure(&(cl), where)
/* verify_heap() is now in zincvm.h */
static Value val_mark(void) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_MARK; return v;
}
static Value val_prim(const char *name) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_PRIM; v.prim.name = name; return v;
}
static Value val_error(const char *msg) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_ERROR;
    /* GC-allocate so the message is reclaimed with the collector instead of
       leaking via strdup on every raised error. */
    int len = (int)strlen(msg);
    char *buf = (char*)gc_alloc_atomic(len + 1);
    memcpy(buf, msg, len); buf[len] = '\0';
    v.error.message = buf;
    return v;
}
Value val_vector(int size) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_VECTOR; v.vector.len = size;
    if (size > 0) v.vector.data = (Value*)gc_alloc(size * sizeof(Value), GC_TYPE_VALUE_ARRAY);
    return v;
}
static Value val_stream_in(FILE *f) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_STREAM; v.stream.file = f; v.stream.is_input = 1; return v;
}
static Value val_stream_out(FILE *f) {
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_STREAM; v.stream.file = f; v.stream.is_input = 0; return v;
}

/* String stream storage — avoids bloating sizeof(Value).
   Index stored in stream.file cast to (FILE*)(intptr_t)idx. */
#define MAX_STRING_STREAMS 8
static struct { char *data; int len; int pos; } string_streams[MAX_STRING_STREAMS];
static int n_string_streams = 0;

static Value val_string_stream_in(const char *src, int srclen) {
    if (n_string_streams >= MAX_STRING_STREAMS) {
        fprintf(stderr, "runtime: too many string streams\n");
        return val_error("too many string streams");
    }
    int idx = n_string_streams++;
    string_streams[idx].data = malloc(srclen + 1);
    memcpy(string_streams[idx].data, src, srclen);
    string_streams[idx].data[srclen] = '\0';
    string_streams[idx].len = srclen;
    string_streams[idx].pos = 0;
    Value v; memset(&v, 0, sizeof(v));
    v.tag = VAL_STREAM;
    v.stream.file = (FILE*)(intptr_t)(idx + 1);  /* +1 so 0 = no string stream */
    v.stream.is_input = 1;
    v.stream.is_string = 1;
    return v;
}

void print_value(Value v) {
    switch (v.tag) {
    case VAL_NUMBER: printf("%ld", v.number); break;
    case VAL_STRING: printf("\"%.*s\"", v.str.len, v.str.data); break;
    case VAL_SYMBOL: printf("%s", v.sym.name); break;
    case VAL_BOOLEAN: printf(v.boolean ? "true" : "false"); break;
    case VAL_CONS: printf("[cons "); print_value(*v.cons.car);
                   printf(" . "); print_value(*v.cons.cdr);
                   printf("]"); break;
    case VAL_NIL: printf("[]"); break;
    case VAL_LAMBDA:
        printf("[lambda %p %d env=%p %d]",
               (void *)v.lambda.code, v.lambda.code_len,
               (void *)v.lambda.env, v.lambda.env_len); break;
    case VAL_MARK: printf("mark"); break;
    case VAL_PRIM: printf("[prim %s]", v.prim.name); break;
    case VAL_ERROR: printf("[error \"%s\"]", v.error.message); break;
    case VAL_VECTOR: printf("[vector %d]", v.vector.len); break;
    case VAL_STREAM: printf("[stream %s]", v.stream.is_input ? "in" : "out"); break;
    default: printf("?%d?", v.tag);
    }
}

/* ------------------------------------------------------------------ */
/*  Value stack                                                        */
/* ------------------------------------------------------------------ */

#define STACK_INIT_CAP 64

static void va_init(ValueArray *a) {
    a->data = GC_VALUE_ARRAY(STACK_INIT_CAP);
    a->len = 0; a->cap = STACK_INIT_CAP;
}
void va_push(ValueArray *a, Value v) {
    if (a->len >= a->cap) {
        int new_cap = a->cap * 2;
        /* Root v across GC_VALUE_ARRAY — v may carry interior pointers
           (lambda.code/env, cons.car/cdr, str.data, ...) that a GC fired
           during the grow would otherwise leave stale in this local. */
        gc_root_push_value(&v);
        Value *new_data = GC_VALUE_ARRAY(new_cap);
        memcpy(new_data, a->data, a->len * sizeof(Value));
        a->data = new_data; a->cap = new_cap;
        gc_root_pop();
    }
    a->data[a->len++] = v;
    if (gc_in_oldgen(a->data) && value_references_nursery(&v))
        gc_dirty_vectors_add(a->data);
}
Value va_pop(ValueArray *a) {
    if (a->len <= 0) { fprintf(stderr, "fatal: pop from empty stack\n"); exit(1); }
    return a->data[--a->len];
}
static Value va_peek(ValueArray *a) { return a->data[a->len - 1]; }
static void va_free(ValueArray *a) { a->data = NULL; a->len = a->cap = 0; }

/* ------------------------------------------------------------------ */
/*  Closure tracing (--trace <name>)                                   */
/* ------------------------------------------------------------------ */

/* MAX_TRACED is in zincvm.h */
Instr  *traced_code[MAX_TRACED];
static const char *traced_name[MAX_TRACED];
int   num_traced = 0;

/* Add a function name to the trace list.  The code pointer is resolved
   after parse_bundle (when closures are in the global table). */
void trace_add(const char *name) {
    if (num_traced < MAX_TRACED) {
        traced_name[num_traced++] = name;
    }
}

/* ------------------------------------------------------------------ */
/*  Global tables (defun + values)                                     */
/* ------------------------------------------------------------------ */

/* DEFUN_TABLE_CAP/VALUES_TABLE_CAP and TableEntry are in zincvm.h.
   The defun table is registered with the GC (via gc_register_global_table)
   so gc_scan_roots traces every closure precisely.  The values table is
   registered via gc_register_values_table.  There is no conservative
   C-stack scan or extra_roots mechanism; the shadow stack + registered
   tables are the sole root sources (4a.6). */

TableEntry defun_table[DEFUN_TABLE_CAP];
int defun_table_used = 0;
TableEntry values_table[VALUES_TABLE_CAP];
int values_table_used = 0;

/* Capacity registers for the GC: the defun table is a minimal perfect
 * hash (slots [0, N) filled, overflow tail [N, N+64) partially filled),
 * and the values table is open-addressed — in both cases live entries are
 * not dense, so the GC must scan the whole capacity and skip empty
 * (name==NULL) slots rather than trusting the `used` count.  The GC reads
 * these via pointer at scan time, so defun_freeze() updating
 * defun_table_cap to N+DEFUN_OVERFLOW_CAP is safe. */
int defun_table_cap = DEFUN_TABLE_CAP;
int values_table_cap = VALUES_TABLE_CAP;

/* Minimal perfect hash state.  After defun_freeze(), defun_table holds
   the N unique bundle keys in a collision-free (bucket, displacement)
   layout.  Runtime defun_set/get use this table plus a small overflow
   tail for keys that appear after bundle load (zinctest test keys). */
int defun_table_size = 0;        /* N: perfect slots */
int defun_buckets = 0;           /* B */
uint32_t *defun_displacement = NULL;

/* Bootstrap mode: before defun_freeze() (during init_globals + parse_bundle
   + keyword registration) all defun_set() calls accumulate into this growable
   list instead of touching defun_table.  defun_freeze() consumes it once. */
typedef struct { const char *name; Value value; } BootstrapEntry;
static BootstrapEntry *bootstrap_keys = NULL;
static int bootstrap_count = 0;
static int bootstrap_cap = 0;
static enum { DEFUN_BOOTSTRAP, DEFUN_RUNTIME } defun_mode = DEFUN_BOOTSTRAP;

/* FNV-1a over the name.  hash_name (reduced mod cap) is retained for the
   open-addressed VALUES table.  hash_name_h0 (raw) is the primary bucket
   hash; hash_name_h1 (raw, seeded) is the displacement/slot hash used to
   place keys during the perfect-hash build and to look them up at runtime. */
static uint32_t hash_name(const char *name, int cap) {
    uint32_t h = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        h ^= (uint32_t)*p;
        h *= 16777619u;
    }
    return h % (uint32_t)cap;
}

static uint32_t hash_name_h0(const char *name) {
    uint32_t h = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        h ^= (uint32_t)*p;
        h *= 16777619u;
    }
    return h;
}

static uint32_t hash_name_h1(const char *name, uint32_t seed) {
    uint32_t h = seed;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        h ^= (uint32_t)*p;
        h *= 16777619u;
    }
    return h;
}

/* defun_set stores name→closure/primitive/keyword bindings, reached by
   [global X].  Two modes:
     DEFUN_BOOTSTRAP — accumulate into bootstrap_keys (never touches the
       GC-scanned defun_table; used during init_globals/parse_bundle).
     DEFUN_RUNTIME   — perfect-hash insert/update, then overflow tail.
   Each store marks the GC dirty bit so the nursery scavenge re-scans the
   slot (runtime slots may reference nursery objects). */
void defun_set(const char *name, Value v) {
    if (defun_mode == DEFUN_BOOTSTRAP) {
        for (int i = 0; i < bootstrap_count; i++) {
            if (strcmp(bootstrap_keys[i].name, name) == 0) {
                bootstrap_keys[i].value = v;   /* later store wins */
                return;
            }
        }
        if (bootstrap_count >= bootstrap_cap) {
            int nc = bootstrap_cap ? bootstrap_cap * 2 : 64;
            BootstrapEntry *nk = realloc(bootstrap_keys, (size_t)nc * sizeof(BootstrapEntry));
            if (!nk) { fprintf(stderr, "defun bootstrap OOM\n"); exit(1); }
            bootstrap_keys = nk;
            bootstrap_cap = nc;
        }
        bootstrap_keys[bootstrap_count].name = strdup(name);
        bootstrap_keys[bootstrap_count].value = v;
        bootstrap_count++;
        defun_table_used = bootstrap_count;
        return;
    }

    /* RUNTIME: perfect-hash slot */
    uint32_t b = hash_name_h0(name) % (uint32_t)defun_buckets;
    uint32_t d = defun_displacement[b];
    uint32_t slot = hash_name_h1(name, d) % (uint32_t)defun_table_size;
    if (defun_table[slot].name != NULL &&
        strcmp(defun_table[slot].name, name) == 0) {
        defun_table[slot].value = v;
        gc_dirty_defuns_mark((int)slot);
        return;
    }
    /* overflow tail: update existing */
    for (int i = defun_table_size; i < defun_table_cap; i++) {
        if (defun_table[i].name != NULL &&
            strcmp(defun_table[i].name, name) == 0) {
            defun_table[i].value = v;
            gc_dirty_defuns_mark(i);
            return;
        }
    }
    /* overflow tail: insert into first NULL slot */
    for (int i = defun_table_size; i < defun_table_cap; i++) {
        if (defun_table[i].name == NULL) {
            defun_table[i].name = strdup(name);
            defun_table[i].value = v;
            gc_dirty_defuns_mark(i);
            defun_table_used++;
            return;
        }
    }
    fprintf(stderr, "defun overflow table full on '%s'\n", name);
    exit(1);
}

static int exec_primitive_valid(const char *name);
Value defun_get(const char *name) {
    if (defun_mode == DEFUN_BOOTSTRAP) {
        for (int i = 0; i < bootstrap_count; i++)
            if (strcmp(bootstrap_keys[i].name, name) == 0)
                return bootstrap_keys[i].value;
    } else {
        uint32_t b = hash_name_h0(name) % (uint32_t)defun_buckets;
        uint32_t d = defun_displacement[b];
        uint32_t slot = hash_name_h1(name, d) % (uint32_t)defun_table_size;
        if (defun_table[slot].name != NULL &&
            strcmp(defun_table[slot].name, name) == 0)
            return defun_table[slot].value;
        for (int i = defun_table_size; i < defun_table_cap; i++)
            if (defun_table[i].name != NULL &&
                strcmp(defun_table[i].name, name) == 0)
                return defun_table[i].value;
    }
    /* Only return VAL_PRIM for known C primitives. Unknown names
       (e.g., *macros*, *stinput*) must be VAL_SYMBOL so that
       cons?, element?, and other list-traversal code can match them.
       The = primitive already handles SYMBOL-vs-PRIM comparison in
       both directions, so this doesn't break fail comparisons. */
    if (exec_primitive_valid(name))
        return val_prim(name);
    return val_symbol(name);
}

/* Probe whether the defun table has an explicit entry for name
   (no val_prim/val_symbol fallback).  Used by bundle-load keyword
   registration to avoid clobbering bundled closures (e.g. the
   metacircular interp's `lookup` helper) with keyword symbols. */
int defun_has(const char *name) {
    if (defun_mode == DEFUN_BOOTSTRAP) {
        for (int i = 0; i < bootstrap_count; i++)
            if (strcmp(bootstrap_keys[i].name, name) == 0)
                return 1;
    } else {
        uint32_t b = hash_name_h0(name) % (uint32_t)defun_buckets;
        uint32_t d = defun_displacement[b];
        uint32_t slot = hash_name_h1(name, d) % (uint32_t)defun_table_size;
        if (defun_table[slot].name != NULL &&
            strcmp(defun_table[slot].name, name) == 0)
            return 1;
        for (int i = defun_table_size; i < defun_table_cap; i++)
            if (defun_table[i].name != NULL &&
                strcmp(defun_table[i].name, name) == 0)
                return 1;
    }
    return 0;
}

/* values_table stores name→value bindings, reached by (value S)/(set S V):
   streams, the Shen global-table value, and runtime (set S V) bindings.
   Open-address insert with linear probing.  No dirty-bitset: the GC always
   full-scans the values table. */
void value_set(const char *name, Value v) {
    if (values_table_used >= VALUES_TABLE_CAP - 1) {
        fprintf(stderr, "values table full (%d entries) on '%s'\n",
                VALUES_TABLE_CAP, name);
        exit(1);
    }
    uint32_t idx = hash_name(name, VALUES_TABLE_CAP);
    while (values_table[idx].name != NULL) {
        if (strcmp(values_table[idx].name, name) == 0) {
            values_table[idx].value = v;
            return;
        }
        idx = (idx + 1) % VALUES_TABLE_CAP;
    }
    values_table[idx].name = strdup(name);
    values_table[idx].value = v;
    values_table_used++;
}

/* No primitive fallback: (value +) must return the bare symbol `+`. */
Value value_get(const char *name) {
    uint32_t idx = hash_name(name, VALUES_TABLE_CAP);
    while (values_table[idx].name != NULL) {
        if (strcmp(values_table[idx].name, name) == 0)
            return values_table[idx].value;
        idx = (idx + 1) % VALUES_TABLE_CAP;
    }
    return val_symbol(name);
}

/* defun_is_defined: is `name` a known defun-table global or C primitive? */
static int defun_is_defined(const char *name) {
    if (!name) return 0;
    if (defun_mode == DEFUN_BOOTSTRAP) {
        for (int i = 0; i < bootstrap_count; i++)
            if (strcmp(bootstrap_keys[i].name, name) == 0) return 1;
    } else {
        uint32_t b = hash_name_h0(name) % (uint32_t)defun_buckets;
        uint32_t d = defun_displacement[b];
        uint32_t slot = hash_name_h1(name, d) % (uint32_t)defun_table_size;
        if (defun_table[slot].name != NULL &&
            strcmp(defun_table[slot].name, name) == 0) return 1;
        for (int i = defun_table_size; i < defun_table_cap; i++)
            if (defun_table[i].name != NULL &&
                strcmp(defun_table[i].name, name) == 0) return 1;
    }
    if (exec_primitive_valid(name)) return 1;
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Error handling for trap-error / simple-error                       */
/* ------------------------------------------------------------------ */

/* CatchFrame is in zincvm.h */

/* S3: CatchFrames are stack-allocated at each catch site (trap-error,
   eval-kl, vm_exec_env callers in zinctest.c and main).  Their error_val
   field holds a GC-allocated string (val_error in vm_throw).  Under
   precise-only roots (4a.6 flip) with no conservative C-stack scan, each
   catch site must explicitly root the error value (or a copy) after
   setjmp returns non-zero so the message string stays alive across any
   collection between the allocation and the site's use of cf.error_val. */
CatchFrame *vm_catch_chain = NULL;

static void vm_throw(const char *msg) {
    if (!vm_catch_chain) {
        fprintf(stderr, "uncaught Shen error: %s\n", msg);
        abort();
    }
    vm_catch_chain->error_val = val_error(msg);
    longjmp(vm_catch_chain->buf, 1);
}

/* Type-error in a primitive.  Primary ownership is the Shen safe-wrapper layer
   (shen/primitives.shen): those wrappers validate args and raise a catchable
   simple-error before the raw primitive is ever called.  This C-level routing is
   therefore only DEFENSE-IN-DEPTH, enabled solely in debug builds
   so that raw/%%-style direct calls into a primitive are still catchable while
   developing.  In release builds the wrapper is the contract: a primitive that
   reaches here prints and returns -1 (a hard, non-catchable VM error), which is
   fine because the wrapper never forwards bad input. */

/* alarm_jmp and test_timed_out moved to zinctest.c (test binary) */

int repl_mode = 0;
jmp_buf repl_exit_jmp;

/* (vm_exec / vm_exec_env now declared in zincvm.h) */

/* ------------------------------------------------------------------ */
/*  Marshal layer: convert C Value ↔ Shen tagged representation        */
/* ------------------------------------------------------------------ */

/* marshal_to_tagged: C Value → Shen tagged form.
   Tagged forms (from interp.shen extract-kl):
     [number X]  = cons(symbol("number"), cons(X, nil))
     [symbol X]  = cons(symbol("symbol"), cons(X, nil))
     [string X]  = cons(symbol("string"), cons(X, nil))
     [boolean X] = cons(symbol("boolean"), cons(X, nil))
     [cons X Y]  = cons(symbol("cons"), cons(X', cons(Y', nil)))
     [cons]      = cons(symbol("cons"), nil)   — empty list
     mark        = symbol("mark")
   Unmarshallable types (lambdas, prims, errors, vectors, streams)
   pass through unchanged. */
Value marshal_to_tagged(Value v) {
    switch (v.tag) {
    case VAL_NUMBER:
        return val_cons(val_symbol("number"), val_cons(v, val_nil()));
    case VAL_SYMBOL:
        return val_cons(val_symbol("symbol"), val_cons(v, val_nil()));
    case VAL_STRING:
        return val_cons(val_symbol("string"), val_cons(v, val_nil()));
    case VAL_BOOLEAN:
        return val_cons(val_symbol("boolean"), val_cons(v, val_nil()));
    case VAL_CONS: {
        /* Don't recursively marshal car/cdr — extract-kl handles its own
           recursion on [cons X Y] by calling extract-kl on X and Y directly.
           Recursive marshalling creates deeply nested structures that the
           compiled interp patterns can't match. */
        gc_root_push_value(&v);  /* root v across nested val_cons allocs */
        Value car_val = *v.cons.car;
        Value cdr_val = *v.cons.cdr;
        gc_root_push_value(&car_val);
        gc_root_push_value(&cdr_val);
        Value inner  = val_cons(cdr_val, val_nil());
        gc_root_push_value(&inner);
        Value middle = val_cons(car_val, inner);
        gc_root_push_value(&middle);
        Value result = val_cons(val_symbol("cons"), middle);
        gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop();
        return result;
    }
    case VAL_NIL:
        return val_cons(val_symbol("cons"), val_nil());
    case VAL_MARK:
        return val_symbol("mark");
    default:
        return v;  /* lambdas, prims, errors, vectors, streams */
    }
}

/* demarshal_from_tagged: Shen tagged form → C Value.
   Inverse of marshal_to_tagged.  Non-tagged atoms pass through. */
Value demarshal_from_tagged(Value tagged) {
    if (tagged.tag == VAL_NUMBER || tagged.tag == VAL_STRING ||
        tagged.tag == VAL_BOOLEAN) return tagged;
    if (tagged.tag == VAL_SYMBOL) {
        if (strcmp(tagged.sym.name, "mark") == 0) return val_nil();
        return tagged;
    }
    if (tagged.tag != VAL_CONS) return tagged;
    /* Check for tagged form: car is a symbol tag */
    Value car = *tagged.cons.car;
    if (car.tag != VAL_SYMBOL) return tagged;
    const char *tag = car.sym.name;

    if (strcmp(tag, "number") == 0 || strcmp(tag, "symbol") == 0 ||
        strcmp(tag, "string") == 0 || strcmp(tag, "boolean") == 0) {
        /* [tag X] — extract the value: cadr of the tagged form */
        Value cdr = *tagged.cons.cdr;
        return *cdr.cons.car;
    }
    if (strcmp(tag, "cons") == 0) {
        gc_root_push_value(&tagged);  /* root tagged across recursive call allocs */
        Value cdr = *tagged.cons.cdr;
        gc_root_push_value(&cdr);
        if (cdr.tag == VAL_NIL) { gc_root_pop(); gc_root_pop(); return val_nil(); }  /* [cons] — empty list */
        /* [cons X Y] — recursively demarshal car and cdr */
        Value tagged_car = *cdr.cons.car;
        Value tagged_cdr = *cdr.cons.cdr;
        Value actual_cdr = *tagged_cdr.cons.car;
        gc_root_push_value(&tagged_car);
        gc_root_push_value(&tagged_cdr);
        gc_root_push_value(&actual_cdr);
        Value r1 = demarshal_from_tagged(tagged_car);
        gc_root_push_value(&r1);     /* root r1 across demarshal of actual_cdr */
        Value r2 = demarshal_from_tagged(actual_cdr);
        gc_root_push_value(&r2);     /* root r2 across val_cons alloc */
        Value out = val_cons(r1, r2);
        gc_root_pop();  /* r2 */
        gc_root_pop();  /* r1 */
        gc_root_pop();  /* actual_cdr */
        gc_root_pop();  /* tagged_cdr */
        gc_root_pop();  /* tagged_car */
        gc_root_pop();  /* cdr */
        gc_root_pop();  /* tagged */
        return out;
    }
    return tagged;  /* unknown tag */
}

/* ------------------------------------------------------------------ */
/*  Primitive dispatch                                                 */
/* ------------------------------------------------------------------ */

/* Deep structural equality for cons cells and vectors.  Used by the =
   primitive to compare lists, trees, and vectors.  Handles circular
   structures via conservative cycle detection (depth limit). */
static int deep_equal(Value a, Value b) {
    /* Depth limit to avoid infinite recursion on cyclic structures */
    #define DEEP_EQUAL_MAX_DEPTH 1000
    static int depth = 0;
    if (depth > DEEP_EQUAL_MAX_DEPTH) return 0;
    
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
        case VAL_NUMBER:  return a.number == b.number;
        case VAL_STRING:  return a.str.len == b.str.len &&
                                 memcmp(a.str.data, b.str.data, a.str.len) == 0;
        case VAL_SYMBOL:   return strcmp(a.sym.name, b.sym.name) == 0;
        case VAL_BOOLEAN: return a.boolean == b.boolean;
        case VAL_NIL:     return 1;
        case VAL_CONS:
            depth++;
            { int r = deep_equal(*a.cons.car, *b.cons.car) &&
                      deep_equal(*a.cons.cdr, *b.cons.cdr);
              depth--;
              return r; }
        case VAL_VECTOR:
            if (a.vector.len != b.vector.len) return 0;
            depth++;
            for (int i = 0; i < a.vector.len; i++) {
                if (!deep_equal(a.vector.data[i], b.vector.data[i])) {
                    depth--;
                    return 0;
                }
            }
            depth--;
            return 1;
        default:          return 0;
    }
    #undef DEEP_EQUAL_MAX_DEPTH
}

/* Build string representation of any Value into buf (matching shen-scheme's
   put-datum behaviour: full printed form for all types).  Used by str primitive. */
static void str_value(Value v, char *buf, int *pos, int bufsize, int depth) {
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
                str_value(*cur->cons.car, buf, pos, bufsize, depth + 1);
                cur = cur->cons.cdr;
            }
            if (cur->tag != VAL_NIL && *pos < bufsize - 1) {
                *pos += snprintf(buf + *pos, bufsize - *pos, " . ");
                str_value(*cur, buf, pos, bufsize, depth + 1);
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

/* Single source of truth for C primitive names (X-macro over vm/prims.def).
 * Shared by exec_primitive_valid, init_globals, and vm_load_bundle (which
 * builds the Shen primitive?-names list from it).  prims.def also drives the
 * generated shen/prims-generated.shen via the Makefile gen-prims target, so
 * the C name set and the Shen primitive? predicate stay in sync. */
#define PRIM(n, a) n,
static const char *const prim_names[] = {
#include "prims.def"
    NULL
};
#undef PRIM

/* Returns true if `name` is a known C primitive. */
static int exec_primitive_valid(const char *name) {
    for (int i = 0; prim_names[i]; i++)
        if (strcmp(name, prim_names[i]) == 0) return 1;
    return 0;
}

/* exec_primitive: dispatch a C primitive by name.
 *
 * Audit note (4a.6): several primitives here pop a Value from the stack,
 * then read an interior pointer (str.data, error.message) from that popped
 * Value across a gc_alloc call in a helper (val_string_from, etc.).  The
 * popped Value is dead as a C local by that point — it must have been
 * separately rooted via gc_root_push_value BEFORE the pop, or its interior
 * pointer will be dangling under precise-only roots (no conservative stack
 * scan to accidentally keep it alive).  Search for gc_root_push_value in
 * this function to confirm coverage of all such popped-Value→alloc pairs. */
int exec_primitive(const char *name, Value *acc, ValueArray *stack) {
    if (!name[0]) goto unknown;
    switch (name[0]) {

    /* ---- 'a': absvector, absvector?, address-> ---- */
    case 'a':
        if (strcmp(name, "absvector") == 0) {
            Value a = va_pop(stack);
            *acc = val_vector((int)a.number); return 0;
        }
        if (strcmp(name, "absvector?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_VECTOR); return 0;
        }
        if (strcmp(name, "address->") == 0) {
            Value vec = va_pop(stack), idx = va_pop(stack), val = va_pop(stack);
            int i = (int)idx.number;
            vec.vector.data[i] = val;
            if (vec.vector.data &&
                gc_in_oldgen(vec.vector.data) &&
                value_references_nursery(&val)) {
                gc_dirty_vectors_add(vec.vector.data);
            }
            *acc = vec; return 0;
        }
        /* assoc: search an alist for a key.  Returns () on not-found, the
           matching pair on found (key matched via = / deep_equal), and
           throws an ALWAYS-ON error on a non-list alist (sys.kl:83:
           "attempt to search a non-list with assoc").  Non-pair elements
           are skipped (the OS recurses on tl when the head isn't a cons). */
        if (strcmp(name, "assoc") == 0) {
            Value key = va_pop(stack), l = va_pop(stack);
            gc_root_push_value(&key);
            gc_root_push_value(&l);
            int found = 0;
            Value result = val_nil();
            while (l.tag == VAL_CONS) {
                Value *car = l.cons.car;
                if (car->tag == VAL_CONS && deep_equal(key, *car->cons.car)) {
                    result = *car; found = 1; break;
                }
                l = *l.cons.cdr;
            }
            if (!found && l.tag != VAL_NIL) {
                gc_root_pop(); gc_root_pop();
                vm_throw("attempt to search a non-list with assoc");
            }
            *acc = found ? result : val_nil();
            gc_root_pop(); gc_root_pop();
            return 0;
        }
        /* append: cons-copy a1 prefix with tail a2 (sys.kl:67).  NIL a1 ->
           a2; cons a1 -> copy; non-list a1 -> ALWAYS-ON error.  Both args
           rooted across the val_cons allocs in the copy. */
        if (strcmp(name, "append") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            if (a1.tag != VAL_NIL && a1.tag != VAL_CONS)
                vm_throw("attempt to append a non-list");
            gc_root_push_value(&a1);
            gc_root_push_value(&a2);
            if (a1.tag == VAL_NIL) {
                gc_root_pop(); gc_root_pop();
                *acc = a2; return 0;
            }
            Value rev = val_nil();
            gc_root_push_value(&rev);
            while (a1.tag == VAL_CONS) {
                rev = val_cons(*a1.cons.car, rev);
                a1 = *a1.cons.cdr;
            }
            Value out = a2;
            gc_root_push_value(&out);
            while (rev.tag == VAL_CONS) {
                out = val_cons(*rev.cons.car, out);
                rev = *rev.cons.cdr;
            }
            *acc = out;
            gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop();
            return 0;
        }
        break;

    /* ---- 'b': boolean? ---- */
    case 'b':
        if (strcmp(name, "boolean?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_BOOLEAN); return 0;
        }
        break;

    /* ---- 'c': cons, cons?, cn, close ---- */
    case 'c':
        if (strcmp(name, "cons") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_cons(a1, a2); return 0;
        }
        if (strcmp(name, "cons?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_CONS); return 0;
        }
        if (strcmp(name, "cn") == 0) {
            /* cn: concatenate two values as strings.  Two-pass approach:
               first compute total length, then write into a single GC_STR
               allocation.  No truncation, no malloc/free per call. */
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            int l1, l2;
            switch (a1.tag) {
            case VAL_STRING:  l1 = a1.str.len; break;
            case VAL_NUMBER:  { char t[32]; l1 = snprintf(t, sizeof(t), "%ld", a1.number); } break;
            case VAL_SYMBOL:  l1 = (int)strlen(a1.sym.name); break;
            case VAL_BOOLEAN: l1 = a1.boolean ? 4 : 5; break;
            case VAL_NIL:     l1 = 2; break;
            default:          l1 = 3; break;
            }
            switch (a2.tag) {
            case VAL_STRING:  l2 = a2.str.len; break;
            case VAL_NUMBER:  { char t[32]; l2 = snprintf(t, sizeof(t), "%ld", a2.number); } break;
            case VAL_SYMBOL:  l2 = (int)strlen(a2.sym.name); break;
            case VAL_BOOLEAN: l2 = a2.boolean ? 4 : 5; break;
            case VAL_NIL:     l2 = 2; break;
            default:          l2 = 3; break;
            }
            int total = l1 + l2;
            gc_root_push_value(&a1);
            gc_root_push_value(&a2);
            char *buf = GC_STR(total);
            int pos = 0;
            switch (a1.tag) {
            case VAL_STRING:  memcpy(buf + pos, a1.str.data, l1); break;
            case VAL_NUMBER:  snprintf(buf + pos, (size_t)l1 + 1, "%ld", a1.number); break;
            case VAL_SYMBOL:  memcpy(buf + pos, a1.sym.name, l1); break;
            case VAL_BOOLEAN: memcpy(buf + pos, a1.boolean ? "true" : "false", l1); break;
            case VAL_NIL:     memcpy(buf + pos, "[]", 2); break;
            default:          memcpy(buf + pos, "[?]", 3); break;
            }
            pos = l1;
            switch (a2.tag) {
            case VAL_STRING:  memcpy(buf + pos, a2.str.data, l2); break;
            case VAL_NUMBER:  snprintf(buf + pos, (size_t)l2 + 1, "%ld", a2.number); break;
            case VAL_SYMBOL:  memcpy(buf + pos, a2.sym.name, l2); break;
            case VAL_BOOLEAN: memcpy(buf + pos, a2.boolean ? "true" : "false", l2); break;
            case VAL_NIL:     memcpy(buf + pos, "[]", 2); break;
            default:          memcpy(buf + pos, "[?]", 3); break;
            }
            gc_root_pop(); gc_root_pop();
            Value result; memset(&result, 0, sizeof(result));
            result.tag = VAL_STRING; result.str.data = buf; result.str.len = total;
            *acc = result; return 0;
        }
        if (strcmp(name, "close") == 0) {
            Value s = va_pop(stack);
            if (s.stream.is_string) {
                int idx = (int)(intptr_t)s.stream.file - 1;
                if (idx < 0 || idx >= n_string_streams) { fprintf(stderr, "runtime: bad string stream idx\n"); return -1; }
                free(string_streams[idx].data);
                string_streams[idx].data = NULL;
                *acc = val_nil(); return 0;
            }
            if (s.stream.file) fclose(s.stream.file);
            *acc = val_nil(); return 0;
        }
        /* c-strlen: O(1) string length (kills the per-char trap-error loop). */
        if (strcmp(name, "c-strlen") == 0) {
            Value a = va_pop(stack);
            *acc = val_number(a.str.len); return 0;
        }
        /* char-code: byte at index as integer (no 1-char string allocation). */
        if (strcmp(name, "char-code") == 0) {
            Value a = va_pop(stack);   /* string */
            Value n = va_pop(stack);   /* index */
            int i = (int)n.number;
            if (i >= 0 && i < a.str.len)
                *acc = val_number((unsigned char)a.str.data[i]);
            else
                *acc = val_number(-1);
            return 0;
        }
        break;

    /* ---- 'e': error?, error-to-string, eval-kl, emptylist ---- */
    case 'e':
        if (strcmp(name, "error?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_ERROR); return 0;
        }
        if (strcmp(name, "error-to-string") == 0) {
            Value a = va_pop(stack);
            gc_root_push_value(&a);
            if (a.tag == VAL_ERROR) *acc = val_string(a.error.message, strlen(a.error.message));
            else if (a.tag == VAL_STRING) *acc = a;
            else *acc = val_string("unknown error", 13);
            gc_root_pop();
            return 0;
        }
        /* element?: deep_equal list membership — O(n) C scan.  The bundled Shen
           element? ran ~1500-3000 metacircular instructions per step; as a C
           primitive each scan step is one C VM instruction.  Preserves exact
           semantics (deep structural equality) for debruijn scope scans,
           primitive?/instruction-keyword? membership, and dedupe-globals. */
        if (strcmp(name, "element?") == 0) {
            Value x = va_pop(stack);      /* needle */
            Value l = va_pop(stack);      /* haystack list */
            gc_root_push_value(&x);
            gc_root_push_value(&l);
            int found = 0;
            Value cur = l;
            while (cur.tag == VAL_CONS) {
                if (deep_equal(x, *cur.cons.car)) { found = 1; break; }
                cur = *cur.cons.cdr;
            }
            gc_root_pop();  /* l */
            gc_root_pop();  /* x */
            *acc = val_boolean(found); return 0;
        }
        if (strcmp(name, "eval-kl") == 0) {
            Value a = va_pop(stack);
            CatchFrame cf;
            cf.parent = vm_catch_chain;
            cf.in_trap_error = 0;
            vm_catch_chain = &cf;
            volatile Value result = a;
            volatile size_t eval_kl_wm = gc_root_watermark();
            if (setjmp(cf.buf) == 0) {

            Value tagged = marshal_to_tagged(a);
            gc_root_push_value(&tagged);

            Value extkl = defun_get("extract-kl");
            gc_root_push_value(&extkl);
            if (extkl.tag != VAL_LAMBDA) {
                fprintf(stderr, "runtime: eval-kl: extract-kl not found in bundle\n");
                goto eval_kl_done;
            }
            Value *env1 = GC_VALUE_ARRAY(extkl.lambda.env_len + 1);
            if (extkl.lambda.env_len > 0)
                memcpy(env1, extkl.lambda.env, extkl.lambda.env_len * sizeof(Value));
            env1[extkl.lambda.env_len] = tagged;
            if (gc_in_oldgen(env1) && value_references_nursery(&tagged))
                gc_dirty_vectors_add(env1);
            Value klambda = vm_exec_env(extkl.lambda.code, extkl.lambda.code_len,
                                         env1, extkl.lambda.env_len + 1);
            gc_root_push_value(&klambda);

            Value klzinc = defun_get("kl->zinc");
            gc_root_push_value(&klzinc);
            if (klzinc.tag != VAL_LAMBDA) {
                fprintf(stderr, "runtime: eval-kl: kl->zinc not found in bundle\n");
                goto eval_kl_done;
            }
            Value *env2 = GC_VALUE_ARRAY(klzinc.lambda.env_len + 1);
            if (klzinc.lambda.env_len > 0)
                memcpy(env2, klzinc.lambda.env, klzinc.lambda.env_len * sizeof(Value));
            env2[klzinc.lambda.env_len] = klambda;
            if (gc_in_oldgen(env2) && value_references_nursery(&klambda))
                gc_dirty_vectors_add(env2);
            Value zinc_code = vm_exec_env(klzinc.lambda.code, klzinc.lambda.code_len,
                                           env2, klzinc.lambda.env_len + 1);
            gc_root_push_value(&zinc_code);

            Value tli = defun_get("toplevel-interp");
            gc_root_push_value(&tli);
            if (tli.tag != VAL_LAMBDA) {
                fprintf(stderr, "runtime: eval-kl: toplevel-interp not found in bundle\n");
                goto eval_kl_done;
            }
            Value *env3 = GC_VALUE_ARRAY(tli.lambda.env_len + 1);
            if (tli.lambda.env_len > 0)
                memcpy(env3, tli.lambda.env, tli.lambda.env_len * sizeof(Value));
            env3[tli.lambda.env_len] = zinc_code;
            if (gc_in_oldgen(env3) && value_references_nursery(&zinc_code))
                gc_dirty_vectors_add(env3);
            Value tagged_result = vm_exec_env(tli.lambda.code, tli.lambda.code_len,
                                               env3, tli.lambda.env_len + 1);
            gc_root_push_value(&tagged_result);

            result = demarshal_from_tagged(tagged_result);

            eval_kl_done:
            gc_root_pop_to(eval_kl_wm);
            vm_catch_chain = cf.parent;
            *acc = result;
            return 0;
            }
            gc_root_pop_to(eval_kl_wm);
            vm_catch_chain = cf.parent;
            /* Fix the error path: eval-kl previously echoed the raw input form
               (*acc = result = a), but `a` is NOT GC-rooted across the compile
               + interp, so the Cheney collector can move its cons cells and the
               echoed value then reads as garbage (e.g. (reverse [1 2 3]) ->
               [reverse [1 2 75]).  Instead propagate the real error
               (cf.error_val, a GC-allocated VAL_ERROR set by vm_throw).  This
               also matches the OS --repl path, which checks for VAL_ERROR. */
            Value errv = cf.error_val;
            gc_root_push_value(&errv);   /* S3: root error value across transfer */
            *acc = errv;
            gc_root_pop();
            return 0;
        }
        if (strcmp(name, "emptylist") == 0) {
            Value a = va_pop(stack);
            if (a.tag == VAL_NUMBER && a.number == 0) { *acc = val_nil(); return 0; }
        }
        /* empty?: () <-> VAL_NIL.  Any non-nil value is not empty. */
        if (strcmp(name, "empty?") == 0) {
            Value a = va_pop(stack);
            *acc = val_boolean(a.tag == VAL_NIL); return 0;
        }
        break;

    /* ---- 'f': fst, function?, fail ---- */
    case 'f':
        if (strcmp(name, "fst") == 0) {
            Value a = va_pop(stack);
            *acc = *a.cons.car; return 0;
        }
        if (strcmp(name, "function?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_LAMBDA || a.tag == VAL_PRIM); return 0;
        }
        if (strcmp(name, "fail") == 0) {
            if (stack->len > 0) {
                Value arg = va_pop(stack);
                *acc = val_cons(val_symbol("fail"), val_cons(arg, val_nil()));
                return 0;
            }
            vm_throw("fail");
        }
        break;

    /* ---- 'g': gensym, get-time ---- */
    case 'g':
        if (strcmp(name, "gensym") == 0) {
            static long gensym_counter = 0;
            char buf[64];
            if (stack->len > 0) va_pop(stack);
            snprintf(buf, sizeof(buf), "shen.gensym_%ld", gensym_counter++);
            *acc = val_symbol(buf); return 0;
        }
        if (strcmp(name, "get-time") == 0) {
            Value mode = va_pop(stack);
            if (strcmp(mode.sym.name, "unix") == 0 || strcmp(mode.sym.name, "real") == 0)
                { *acc = val_number((long)time(NULL)); return 0; }
            if (strcmp(mode.sym.name, "run") == 0) { *acc = val_number((long)clock()); return 0; }
        }
        break;

    /* ---- 'h': hd, hdstr ---- */
    case 'h':
        if (strcmp(name, "hd") == 0) {
            Value a = va_pop(stack);
            if (a.tag == VAL_NIL) { *acc = val_nil(); return 0; }
            *acc = *a.cons.car; return 0;
        }
        if (strcmp(name, "hdstr") == 0) {
            Value a = va_pop(stack);
            *acc = val_string_from(&a, 0, 1); return 0;
        }
        break;

    /* ---- 'i': intern ---- */
    case 'i':
        if (strcmp(name, "intern") == 0) {
            Value a = va_pop(stack);
            char buf[256]; int n = a.str.len < 255 ? a.str.len : 255;
            memcpy(buf, a.str.data, n); buf[n] = '\0';
            *acc = val_symbol(buf); return 0;
        }
        break;

    /* ---- 'l': length ---- */
    case 'l':
        /* length: count cons cells to the NIL terminator (sys.kl:172,
           shen.length-h).  A non-NIL, non-CONS tail is an ALWAYS-ON error. */
        if (strcmp(name, "length") == 0) {
            Value a = va_pop(stack);
            long n = 0;
            while (a.tag == VAL_CONS) { n++; a = *a.cons.cdr; }
            if (a.tag != VAL_NIL) vm_throw("length: non-list");
            *acc = val_number(n); return 0;
        }
        break;

    /* ---- 'n': n->string, number?, newvar ---- */
    case 'n':
        if (strcmp(name, "n->string") == 0) {
            Value a = va_pop(stack);
            char buf[2] = { (char)a.number, '\0' };
            *acc = val_string(buf, 1); return 0;
        }
        if (strcmp(name, "number?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_NUMBER); return 0;
        }
        if (strcmp(name, "newvar") == 0) {
            static int newvar_counter = 0;
            char buf[64];
            if (stack->len > 0) va_pop(stack);
            snprintf(buf, sizeof(buf), "V_%d", newvar_counter++);
            *acc = val_symbol(buf); return 0;
        }
        /* nth: 1-BASED element access (sys.kl:178).  Walk k-1 cdrs, then
           return car if the kth cell is a cons; otherwise ALWAYS-ON error. */
        if (strcmp(name, "nth") == 0) {
            Value n = va_pop(stack), l = va_pop(stack);
            long k = (long)n.number;
            while (k > 1 && l.tag == VAL_CONS) { k--; l = *l.cons.cdr; }
            if (k == 1 && l.tag == VAL_CONS) *acc = *l.cons.car;
            else vm_throw("nth applied to a non-list or out-of-range index");
            return 0;
        }
        break;

    /* ---- 'o': open ---- */
    case 'o':
        if (strcmp(name, "open") == 0) {
            Value path = va_pop(stack), dir = va_pop(stack);
            char pb[256]; int n = path.str.len < 255 ? path.str.len : 255;
            memcpy(pb, path.str.data, n); pb[n] = '\0';
            if (strcmp(dir.sym.name, "in") == 0) {
                FILE *f = fopen(pb, "r");
                if (f) { *acc = val_stream_in(f); return 0; }
                if (errno == ENOENT) {
                    *acc = val_string_stream_in(path.str.data, path.str.len);
                    return 0;
                }
                *acc = val_boolean(false); return 0;
            } else if (strcmp(dir.sym.name, "out") == 0) {
                FILE *f = fopen(pb, "w");
                if (!f) { *acc = val_boolean(false); return 0; }
                *acc = val_stream_out(f); return 0;
            }
        }
        break;

    /* ---- 'p': pos ---- */
    case 'p':
        if (strcmp(name, "pos") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            int pl = (int)a2.number;
            if (pl < 0 || pl >= a1.str.len) {
                if (vm_catch_chain && vm_catch_chain->in_trap_error)
                    vm_throw("pos out of bounds");
                *acc = val_string("", 0);
            } else *acc = val_string_from(&a1, pl, 1);
            return 0;
        }
        break;

    /* ---- 'r': read-byte, read-file-as-string ---- */
    case 'r':
        if (strcmp(name, "read-byte") == 0) {
            Value s = va_pop(stack);
            if (s.stream.is_string) {
                int idx = (int)(intptr_t)s.stream.file - 1;
                if (idx < 0 || idx >= n_string_streams) { return -1; }
                if (string_streams[idx].pos >= string_streams[idx].len) {
                    *acc = val_number(-1);
                } else {
                    *acc = val_number((unsigned char)string_streams[idx].data[string_streams[idx].pos++]);
                }
                return 0;
            }
            int c = fgetc(s.stream.file); *acc = val_number(c == EOF ? -1 : c); return 0;
        }
        if (strcmp(name, "read-file-as-string") == 0) {
            Value path = va_pop(stack);
            char *p = strndup(path.str.data, path.str.len);
            FILE *f = fopen(p, "r");
            free(p);
            if (!f) { fprintf(stderr, "runtime: cannot open file for read-file-as-string\n"); *acc = val_string("", 0); return 0; }
            fseek(f, 0, SEEK_END);
            long sz = ftell(f);
            fseek(f, 0, SEEK_SET);
            char *buf = malloc(sz + 1);
            size_t n = fread(buf, 1, sz, f);
            fclose(f);
            buf[n] = '\0';
            *acc = val_string(buf, n);
            free(buf);
            return 0;
        }
        /* reverse: acc-built reversal (sys.kl:143 = shen.reverse-help L ()). */
        if (strcmp(name, "reverse") == 0) {
            Value a = va_pop(stack);
            if (a.tag != VAL_NIL && a.tag != VAL_CONS)
                vm_throw("attempt to reverse a non-list");
            gc_root_push_value(&a);
            Value out = val_nil();
            gc_root_push_value(&out);
            while (a.tag == VAL_CONS) {
                out = val_cons(*a.cons.car, out);
                a = *a.cons.cdr;
            }
            *acc = out;
            gc_root_pop(); gc_root_pop();
            return 0;
        }
        break;

    /* ---- 's': symbol?, string?, simple-error, str, stream?, stinput,
                 stoutput, set, string->n, shen.fail! ---- */
    case 's':
        if (strcmp(name, "symbol?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_SYMBOL); return 0;
        }
        if (strcmp(name, "string?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_STRING); return 0;
        }
        if (strcmp(name, "simple-error") == 0) {
            Value a = va_pop(stack);
            if (repl_mode && a.tag == VAL_STRING
                && a.str.len == 19 && strncmp(a.str.data, "error: empty stream", 19) == 0) {
                longjmp(repl_exit_jmp, 1);
            }
            char msg[256];
            if (a.tag == VAL_STRING) snprintf(msg, sizeof(msg), "%.*s", a.str.len, a.str.data);
            else snprintf(msg, sizeof(msg), "simple-error called");
            vm_throw(msg);
        }
        if (strcmp(name, "str") == 0) {
            Value a = va_pop(stack);
            if (a.tag == VAL_SYMBOL) *acc = val_string(a.sym.name, strlen(a.sym.name));
            else if (a.tag == VAL_STRING) *acc = a;
            else if (a.tag == VAL_NUMBER) { char buf[64]; int len = snprintf(buf, sizeof(buf), "%ld", a.number); *acc = val_string(buf, len); }
            else if (a.tag == VAL_BOOLEAN) *acc = val_string(a.boolean ? "true" : "false",
                                                             a.boolean ? 4 : 5);
            else { static char buf[4096]; int pos = 0; str_value(a, buf, &pos, sizeof(buf), 0); *acc = val_string(buf, pos); }
            return 0;
        }
        if (strcmp(name, "stream?") == 0) {
            Value a = va_pop(stack); *acc = val_boolean(a.tag == VAL_STREAM); return 0;
        }
        if (strcmp(name, "stinput") == 0) {
            Value v; memset(&v, 0, sizeof(v));
            v.tag = VAL_STREAM;
            v.stream.file = stdin;
            v.stream.is_input = 1;
            *acc = v; return 0;
        }
        if (strcmp(name, "stoutput") == 0) {
            Value v; memset(&v, 0, sizeof(v));
            v.tag = VAL_STREAM;
            v.stream.file = stdout;
            v.stream.is_input = 0;
            *acc = v; return 0;
        }
        if (strcmp(name, "set") == 0) {
            Value sym = va_pop(stack), v = va_pop(stack);
            value_set(sym.sym.name, v); *acc = v; return 0;
        }
        if (strcmp(name, "string->n") == 0) {
            Value a = va_pop(stack);
            *acc = val_number(a.str.len > 0 ? (unsigned char)a.str.data[0] : 0); return 0;
        }
        if (strcmp(name, "shen.fail!") == 0) {
            if (stack->len > 0) {
                Value arg = va_pop(stack);
                *acc = val_cons(val_symbol("fail"), val_cons(arg, val_nil()));
                return 0;
            }
            vm_throw("fail");
        }
        if (strcmp(name, "snd") == 0) {
            Value a = va_pop(stack);
            *acc = *a.cons.cdr; return 0;
        }
        /* substring: zero-copy view Str[Start..Start+Len), clamped. */
        if (strcmp(name, "substring") == 0) {
            Value s = va_pop(stack);      /* string */
            Value st = va_pop(stack);     /* start */
            Value ln = va_pop(stack);     /* len */
            int start = (int)st.number, len = (int)ln.number;
            if (start < 0) start = 0;
            if (start > s.str.len) start = s.str.len;
            if (len < 0) len = 0;
            if (start + len > s.str.len) len = s.str.len - start;
            /* Root s across val_string_from (it may alias s's buffer and s may
               be in the nursery; keep the source alive). */
            gc_root_push_value(&s);
            Value r = val_string_from(&s, start, len);
            gc_root_pop();
            *acc = r; return 0;
        }
        /* shen.str->bytes: string -> list of int byte codes (reader.kl:31).
           "" -> (); string -> cons(string->n(hdstr V), str->bytes(tlstr V));
           non-string -> shen.f-error (ALWAYS-ON throw, OS-defined semantics).
           Builds the list in forward byte order (byte[0] at the head).  The
           string arg is rooted across the val_cons allocs. */
        if (strcmp(name, "shen.str->bytes") == 0) {
            Value a = va_pop(stack);
            if (a.tag != VAL_STRING)
                vm_throw("attempt to convert a non-string with str->bytes");
            gc_root_push_value(&a);
            long n = a.str.len;
            Value out = val_nil();
            gc_root_push_value(&out);
            for (long i = n - 1; i >= 0; i--)
                out = val_cons(val_number((unsigned char)a.str.data[i]), out);
            *acc = out;
            gc_root_pop(); gc_root_pop();
            return 0;
        }
        /* shen.bytes->string: list of int byte codes -> string (reader.kl:45).
           () -> ""; (cons? V) -> cn(n->string(hd V), bytes->string(tl V));
           non-list -> shen.f-error (ALWAYS-ON throw, OS-defined semantics).
           Each element is a byte code; n->string turns it into a 1-char
           string, so the result is a concatenation of those chars in list
           order.  The list arg is rooted across the GC_STR alloc. */
        if (strcmp(name, "shen.bytes->string") == 0) {
            Value a = va_pop(stack);
            if (a.tag != VAL_NIL && a.tag != VAL_CONS)
                vm_throw("attempt to convert a non-list with bytes->string");
            gc_root_push_value(&a);
            long n = 0;
            Value cur = a;
            while (cur.tag == VAL_CONS) { n++; cur = *cur.cons.cdr; }
            char *buf = GC_STR(n);
            long i = 0;
            cur = a;
            while (cur.tag == VAL_CONS) {
                buf[i++] = (char)cur.cons.car->number;
                cur = *cur.cons.cdr;
            }
            gc_root_pop();
            Value result; memset(&result, 0, sizeof(result));
            result.tag = VAL_STRING; result.str.data = buf; result.str.len = n;
            *acc = result; return 0;
        }
        break;

    /* ---- 't': tl, trap-error, tlstr ---- */
    case 't':
        if (strcmp(name, "tl") == 0) {
            Value a = va_pop(stack);
            if (a.tag == VAL_NIL) { *acc = val_nil(); return 0; }
            *acc = *a.cons.cdr; return 0;
        }
        if (strcmp(name, "trap-error") == 0) {
            volatile Value body = va_pop(stack);
            volatile Value handler = va_pop(stack);
            gc_root_push_value_volatile(&body);
            gc_root_push_value_volatile(&handler);
            CatchFrame cf;
            cf.parent = vm_catch_chain;
            cf.in_trap_error = 0;
            vm_catch_chain = &cf;
            volatile size_t body_call_wm = gc_root_watermark();
            if (setjmp(cf.buf) == 0) {
                cf.in_trap_error = 1;
                if (body.tag == VAL_LAMBDA) {
                    int new_len = body.lambda.env_len + 1;
                    Value *new_env = GC_VALUE_ARRAY(new_len);
                    if (body.lambda.env_len > 0)
                        memcpy(new_env, body.lambda.env, body.lambda.env_len * sizeof(Value));
                    new_env[body.lambda.env_len] = val_nil();
                    if (gc_in_oldgen(new_env) && body.lambda.env_len > 0) {
                        for (int j = 0; j < body.lambda.env_len; j++) {
                            if (value_references_nursery(&body.lambda.env[j])) {
                                gc_dirty_vectors_add(new_env);
                                break;
                            }
                        }
                    }
                    *acc = vm_exec_env(body.lambda.code, body.lambda.code_len, new_env, new_len);
                }
                else *acc = body;
                vm_catch_chain = cf.parent;
                gc_root_pop(); gc_root_pop();
                return 0;
            } else {
                vm_catch_chain = cf.parent;
                gc_root_pop_to(body_call_wm);
                Value err = cf.error_val;
                int env_len = handler.lambda.env_len;
                int new_env_len = env_len + 1;
                gc_root_push_value(&err);
                Value *henv = GC_VALUE_ARRAY(new_env_len);
                if (env_len > 0)
                    memcpy(henv, handler.lambda.env, env_len * sizeof(Value));
                henv[env_len] = err;
                if (gc_in_oldgen(henv) && value_references_nursery(&err))
                    gc_dirty_vectors_add(henv);
                Instr *hc = handler.lambda.code; int hl = handler.lambda.code_len;
                gc_root_pop();
                gc_root_pop(); gc_root_pop();
                *acc = vm_exec_env(hc, hl, henv, new_env_len);
                return 0;
            }
        }
        if (strcmp(name, "tlstr") == 0) {
            Value a = va_pop(stack);
            *acc = val_string_from(&a, 1, a.str.len - 1); return 0;
        }
        break;

    /* ---- 'v': value, variable? ---- */
    case 'v':
        if (strcmp(name, "value") == 0) {
            Value a = va_pop(stack);
            *acc = value_get(a.sym.name); return 0;
        }
        if (strcmp(name, "variable?") == 0) {
            Value a = va_pop(stack);
            if (a.tag != VAL_SYMBOL) { *acc = val_boolean(0); return 0; }
            const char *s = a.sym.name;
            if (!s[0] || s[0] < 'A' || s[0] > 'Z') { *acc = val_boolean(0); return 0; }
            for (int i = 1; s[i]; i++) {
                int c = (unsigned char)s[i];
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9')) continue;
                if (c == '`' || c == '=' || c == '*' || c == '/' || c == '+' ||
                    c == '_' || c == '?' || c == '$' || c == '!' || c == '@' ||
                    c == '~' || c == '.' || c == '>' || c == '<' || c == '&' ||
                    c == '%' || c == '\'' || c == '#') continue;
                *acc = val_boolean(0); return 0;
            }
            *acc = val_boolean(1); return 0;
        }
        break;

    /* ---- 'w': write-byte ---- */
    case 'w':
        if (strcmp(name, "write-byte") == 0) {
            Value byte = va_pop(stack);
            Value s    = va_pop(stack);
            fputc((int)byte.number, s.stream.file);
            if (s.stream.file == stdout) fflush(stdout);
            *acc = val_number(byte.number); return 0;
        }
        break;

    /* ---- Arithmetic: +, -, *, / ---- */
    case '+':
        if (strcmp(name, "+") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_number(a1.number + a2.number); return 0;
        }
        break;
    case '-':
        if (strcmp(name, "-") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_number(a1.number - a2.number); return 0;
        }
        break;
    case '*':
        if (strcmp(name, "*") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_number(a1.number * a2.number); return 0;
        }
        break;
    case '/':
        if (strcmp(name, "/") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_number(a1.number / a2.number); return 0;
        }
        break;

    /* ---- Comparison: =, <, > ---- */
    case '=':
        if (strcmp(name, "=") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            if (a1.tag == VAL_NUMBER && a2.tag == VAL_NUMBER)
                *acc = val_boolean(a1.number == a2.number);
            else if (a1.tag == VAL_STRING && a2.tag == VAL_STRING)
                *acc = val_boolean(a1.str.len == a2.str.len && memcmp(a1.str.data, a2.str.data, a1.str.len) == 0);
            else if (a1.tag == VAL_SYMBOL && a2.tag == VAL_SYMBOL)
                *acc = val_boolean(strcmp(a1.sym.name, a2.sym.name) == 0);
            else if (a1.tag == VAL_BOOLEAN && a2.tag == VAL_BOOLEAN)
                *acc = val_boolean(a1.boolean == a2.boolean);
            else if ((a1.tag == VAL_CONS && a2.tag == VAL_SYMBOL) ||
                     (a1.tag == VAL_SYMBOL && a2.tag == VAL_CONS))
                *acc = val_boolean(false);
            else if (a1.tag == VAL_SYMBOL && a2.tag == VAL_PRIM)
                *acc = val_boolean(strcmp(a1.sym.name, a2.prim.name) == 0);
            else if (a1.tag == VAL_PRIM && a2.tag == VAL_SYMBOL)
                *acc = val_boolean(strcmp(a1.prim.name, a2.sym.name) == 0);
            else if (a1.tag == VAL_CONS && a2.tag == VAL_CONS)
                *acc = val_boolean(deep_equal(a1, a2));
            else if (a1.tag == VAL_VECTOR && a2.tag == VAL_VECTOR)
                *acc = val_boolean(deep_equal(a1, a2));
            else *acc = val_boolean(a1.tag == VAL_NIL && a2.tag == VAL_NIL);
            return 0;
        }
        break;
    case '<':
        if (strcmp(name, "<") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_boolean(a1.tag == VAL_NUMBER && a2.tag == VAL_NUMBER && a1.number < a2.number); return 0;
        }
        if (strcmp(name, "<=") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_boolean(a1.tag == VAL_NUMBER && a2.tag == VAL_NUMBER && a1.number <= a2.number); return 0;
        }
        if (strcmp(name, "<-address") == 0) {
            Value vec = va_pop(stack), idx = va_pop(stack);
            int i = (int)idx.number;
            *acc = vec.vector.data[i]; return 0;
        }
        break;
    case '>':
        if (strcmp(name, ">") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_boolean(a1.tag == VAL_NUMBER && a2.tag == VAL_NUMBER && a1.number > a2.number); return 0;
        }
        if (strcmp(name, ">=") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_boolean(a1.tag == VAL_NUMBER && a2.tag == VAL_NUMBER && a1.number >= a2.number); return 0;
        }
        break;

    /* ---- '@': @p ---- */
    case '@':
        if (strcmp(name, "@p") == 0) {
            Value a1 = va_pop(stack), a2 = va_pop(stack);
            *acc = val_cons(a1, a2); return 0;
        }
        break;
    }

unknown:
    fprintf(stderr, "runtime: unknown primitive '%s'\n", name);
    return -1;
}

/* ------------------------------------------------------------------ */
/*  csexp parser                                                       */
/* ------------------------------------------------------------------ */

static void skip_ws(ParseState *ps) {
    while (isspace((unsigned char)*ps->p)) ps->p++;
}
static int parse_int(ParseState *ps) {
    int n = 0;
    if (!isdigit((unsigned char)*ps->p)) PARSE_ERROR("expected digit");
    while (isdigit((unsigned char)*ps->p)) { n = n * 10 + (*ps->p - '0'); ps->p++; }
    return n;
}
static Value parse_csexp_atom(ParseState *ps) {
    skip_ws(ps);
    if (*ps->p != '[') PARSE_ERROR("expected '[' for csexp atom");
    ps->p++;
    int len = parse_int(ps);
    if (*ps->p != ':') PARSE_ERROR("expected ':' after length");
    ps->p++;
    char type = *ps->p; ps->p++;
    if (*ps->p != ']') PARSE_ERROR("expected ']' after type");
    ps->p++;
    if (len < 0) PARSE_ERROR("negative length");
    char *buf = malloc(len + 1);
    memcpy(buf, ps->p, len); buf[len] = '\0'; ps->p += len;
    Value v; memset(&v, 0, sizeof(v));
    switch (type) {
    case 's': v = val_symbol(buf); break;
    case 'n': v = val_number(atol(buf)); break;
    case 'S':
        if (ps->scratch) {
            /* scratch mode: use malloc (C-heap, non-moving) so operand
             * strings survive any collection triggered during parsing */
            v.tag = VAL_STRING;
            v.str.data = malloc(len + 1);
            memcpy(v.str.data, buf, len);
            v.str.data[len] = '\0';
            v.str.len = len;
        } else {
            v = val_string(buf, len);
        }
        break;
    case 'b': v = val_boolean(strcmp(buf, "true") == 0); break;
    default: free(buf); { char msg[64]; snprintf(msg, sizeof(msg), "unknown csexp type '%c'", type); PARSE_ERROR(msg); }
    }
    free(buf); return v;
}
static int parse_csexp_list(ParseState *ps, Instr **out);

static int parse_body(ParseState *ps, Instr **out) {
    int cap = 16, len = 0;
    Instr *scratch = (Instr*)malloc(cap * sizeof(Instr));

    /* Save caller's scratch state; set ours for nested parsing */
    int saved_scratch = ps->scratch;
    Instr *saved_scratch_buf = ps->scratch_buf;
    int saved_scratch_len = ps->scratch_len;
    ps->scratch = 1;
    ps->scratch_buf = scratch;
    ps->scratch_len = 0;  /* updated as we add entries below */

    /* Save caller's cc_slots state; this call builds its own */
    Instr ***saved_cc_slots = ps->cc_slots;
    int saved_cc_len = ps->cc_len;
    int saved_cc_cap = ps->cc_cap;
    ps->cc_slots = NULL;
    ps->cc_len   = 0;
    ps->cc_cap   = 0;

    while (1) {
        skip_ws(ps); char c = *ps->p;
        if (c == ')' || c == '\0') break;
        if (c == '(') PARSE_ERROR("unexpected nested list in body");
        Instr instr; memset(&instr, 0, sizeof(instr));
        instr.op = char_to_opcode(c); ps->p++;
        switch (c) {
        case 'm': case 'p': case 'r': case 'v': case 'e': case 'd': case 't':
            break;  /* no operand */
        case 'a': case 'f': case 'j': case 'n': case 'g':
        case 's': case 'P': case 'S': case 'b':
            instr.operand = parse_csexp_atom(ps); break;
        case 'c': {
            skip_ws(ps);
            if (*ps->p != '(') PARSE_ERROR("expected '(' after 'c'");
            ps->p++;
            /* Allocate a stable side-slot for the closure_code so the GC
             * can see it across the recursive parse_body and subsequent
             * gc_alloc calls.  The slot is pushed on the shadow stack
             * for the entire duration of THIS parse_body call so nested
             * recursive parse_body gc_allocs keep every child reachable. */
            Instr **slot = (Instr**)malloc(sizeof(Instr*));
            if (!slot) { fprintf(stderr, "fatal: malloc Instr** slot\n"); exit(1); }
            if (ps->cc_len >= ps->cc_cap) {
                int new_cap = ps->cc_cap ? ps->cc_cap * 2 : 8;
                ps->cc_slots = (Instr***)realloc(ps->cc_slots, new_cap * sizeof(Instr**));
                if (!ps->cc_slots) { fprintf(stderr, "fatal: realloc cc_slots\n"); exit(1); }
                ps->cc_cap = new_cap;
            }
            ps->cc_slots[ps->cc_len++] = slot;
            gc_root_push_ptr((void**)slot);
            instr.closure_len = parse_body(ps, slot);
            instr.closure_code = *slot;
            if (*ps->p != ')') PARSE_ERROR("expected ')' after cur body");
            ps->p++; break;
        }
        default: { char msg[64]; snprintf(msg, sizeof(msg), "unknown opcode '%c' (0x%02x)", c, (unsigned char)c); PARSE_ERROR(msg); }
        }
        if (len >= cap) { cap *= 2; scratch = (Instr*)realloc(scratch, cap * sizeof(Instr)); }
        scratch[len++] = instr;
        ps->scratch_len = len;  /* keep ParseState current for error cleanup */
        ps->scratch_buf = scratch;
    }

    /* Restore caller's scratch state */
    ps->scratch     = saved_scratch;
    ps->scratch_buf = saved_scratch_buf;
    ps->scratch_len = saved_scratch_len;

    /* Re-sync closure_code pointers from rooted side-slots into the
     * scratch buffer before the dangerous gc_alloc below.  A nursery
     * scavenge triggered by a later recursive parse_body may have
     * promoted a child code array, updating *slot but leaving
     * scratch[i].closure_code stale. */
    {
        int si = 0;
        for (int i = 0; i < len; i++) {
            if (scratch[i].op == OP_CUR) {
                scratch[i].closure_code = *ps->cc_slots[si];
                si++;
            }
        }
    }

    /* Allocate final GC-managed Instr array and bulk-copy */
    Instr *code = (Instr*)gc_alloc(len * sizeof(Instr), GC_TYPE_INSTR_ARRAY);
    memcpy(code, scratch, len * sizeof(Instr));

    /* Pin code across the GC_STR calls in the re-wrap loop.  GC_STR may
       trigger a collection; code is a C local not yet returned/registered,
       so without this pin it goes stale under precise-only roots (4a.6). */
    gc_root_push_ptr((void**)&code);

    /* Re-wrap VAL_STRING operand strings: malloc → GC_STR (GC-managed) */
    for (int i = 0; i < len; i++) {
        if (code[i].operand.tag == VAL_STRING) {
            char *old_data = code[i].operand.str.data;
            int slen = code[i].operand.str.len;
            /* GC_STR may trigger a collection; old_data is still valid
             * C-heap memory at this point so gc_scan_value passes it
             * through unchanged */
            code[i].operand.str.data = GC_STR(slen);
            memcpy(code[i].operand.str.data, old_data, slen);
            code[i].operand.str.data[slen] = '\0';
            free(old_data);
        }
        /* VAL_SYMBOL sym.name is strdup'd (C-heap) — stays as-is.
         * VAL_NUMBER / VAL_BOOLEAN have no pointers. */
    }

    gc_root_pop();  /* code */

    /* Pop and free the side-slots that rooted closure_code children.
     * Pushed in order: slot0, slot1, ..., slotN, &code.  &code was
     * popped above; now pop the N slots (LIFO order matches). */
    for (int i = 0; i < ps->cc_len; i++)
        gc_root_pop();
    for (int i = 0; i < ps->cc_len; i++)
        free(ps->cc_slots[i]);
    free(ps->cc_slots);

    /* Restore parent's cc_slots state */
    ps->cc_slots = saved_cc_slots;
    ps->cc_len   = saved_cc_len;
    ps->cc_cap   = saved_cc_cap;

    free(scratch);
    *out = code; return len;
}
static int parse_csexp_list(ParseState *ps, Instr **out) {
    skip_ws(ps);
    if (*ps->p != '(') PARSE_ERROR("expected '(' for list");
    ps->p++;
    int len = parse_body(ps, out);
    if (*ps->p != ')') PARSE_ERROR("expected ')' after list body");
    ps->p++;
    return len;
}
int parse_bytecode(const char *str, Instr **out) {
    ParseState ps = {0}; ps.p = str; ps.start = str;
    volatile size_t parse_wm = gc_root_watermark();
    if (setjmp(parse_err_jmp)) {
        /* Free scratch buffer + C-heap operand strings from parse_body */
        if (ps.scratch_buf) {
            for (int i = 0; i < ps.scratch_len; i++) {
                if (ps.scratch_buf[i].operand.tag == VAL_STRING)
                    free(ps.scratch_buf[i].operand.str.data);
            }
            free(ps.scratch_buf);
        }
        /* Free any side-slots from parse_body OP_CUR rooting */
        for (int i = 0; i < ps.cc_len; i++)
            free(ps.cc_slots[i]);
        free(ps.cc_slots);
        gc_root_pop_to(parse_wm);
        fprintf(stderr, "%s\n", parse_err_msg); *out = NULL; return 0;
    }
    return parse_csexp_list(&ps, out);
}

/* ------------------------------------------------------------------ */
/*  Debug printing                                                     */
/* ------------------------------------------------------------------ */

void print_instr(Instr *code, int len, int indent) {
    for (int i = 0; i < len; i++) {
        for (int j = 0; j < indent; j++) printf("  ");
        Instr *in = &code[i];
        switch (in->op) {
        case OP_PUSHMARK: printf("pushmark\n"); break;
        case OP_APPLY:    printf("apply\n"); break;
        case OP_GRAB:     printf("grab\n"); break;
        case OP_RETURN:   printf("return\n"); break;
        case OP_LET:      printf("let\n"); break;
        case OP_ENDLET:   printf("endlet\n"); break;
        case OP_APPTERM:  printf("appterm\n"); break;
        case OP_ACCESS:   printf("access "); print_value(in->operand); printf("\n"); break;
        case OP_GLOBAL:   printf("global "); print_value(in->operand); printf("\n"); break;
        case OP_JMPF:     printf("jmpf "); print_value(in->operand); printf(" (tgt=%d)\n", in->jmp_target); break;
        case OP_JMP:      printf("jmp ");  print_value(in->operand); printf(" (tgt=%d)\n", in->jmp_target); break;
        case OP_NUMBER:   printf("number "); print_value(in->operand); printf("\n"); break;
        case OP_STRING:   printf("string "); print_value(in->operand); printf("\n"); break;
        case OP_SYMBOL:   printf("symbol "); print_value(in->operand); printf("\n"); break;
        case OP_BOOLEAN:  printf("boolean "); print_value(in->operand); printf("\n"); break;
        case OP_PRIM:     printf("prim "); print_value(in->operand); printf("\n"); break;
        case OP_CUR:
            printf("cur (code=%d):\n", in->closure_len);
            print_instr(in->closure_code, in->closure_len, indent + 1);
            for (int j = 0; j < indent; j++) printf("  ");
            printf("endcur\n");
            break;
        default: printf("??? (op=%d)\n", (int)in->op);
        }
    }
}

/* Resolve trace names to code pointers.  Call after parse_bundle. */
void trace_resolve(void) {
    for (int i = 0; i < num_traced; i++) {
        Value g = defun_get(traced_name[i]);
        if (g.tag == VAL_LAMBDA) {
            traced_code[i] = g.lambda.code;
            fprintf(stderr, "[trace] watching '%s' (%d instrs)\n",
                    traced_name[i], g.lambda.code_len);
        } else {
            fprintf(stderr, "[trace] '%s' not a lambda (tag=%d), skipping\n",
                    traced_name[i], g.tag);
            traced_code[i] = NULL;
        }
    }
}

/* Print one instruction in raw format (same style as zincdec --raw) */
static void print_instr_one(Instr *in, int pc) {
    printf("  %04d  ", pc);
    switch (in->op) {
    case OP_PUSHMARK: printf("pushmark\n"); break;
    case OP_APPLY:    printf("apply\n"); break;
    case OP_GRAB:     printf("grab\n"); break;
    case OP_RETURN:   printf("return\n"); break;
    case OP_LET:      printf("let\n"); break;
    case OP_ENDLET:   printf("endlet\n"); break;
    case OP_APPTERM:  printf("appterm\n"); break;
    case OP_ACCESS:   printf("access "); print_value(in->operand); printf("\n"); break;
    case OP_GLOBAL:   printf("global "); print_value(in->operand); printf("\n"); break;
    case OP_JMPF:     printf("jmpf "); print_value(in->operand);
                      printf(" (tgt=%d)\n", in->jmp_target); break;
    case OP_JMP:      printf("jmp ");  print_value(in->operand);
                      printf(" (tgt=%d)\n", in->jmp_target); break;
    case OP_NUMBER:   printf("number "); print_value(in->operand); printf("\n"); break;
    case OP_STRING:   printf("string "); print_value(in->operand); printf("\n"); break;
    case OP_SYMBOL:   printf("symbol "); print_value(in->operand); printf("\n"); break;
    case OP_BOOLEAN:  printf("boolean "); print_value(in->operand); printf("\n"); break;
    case OP_PRIM:     printf("prim "); print_value(in->operand); printf("\n"); break;
    case OP_CUR:      printf("cur (code=%d)\n", in->closure_len); break;
    default:          printf("??? (%d)\n", (int)in->op);
    }
}

/* ------------------------------------------------------------------ */
/*  Resolve jumps                                                      */
/* ------------------------------------------------------------------ */

void resolve_jumps(Instr *code, int len) {
    for (int i = 0; i < len; i++) {
        Instr *in = &code[i];
        switch (in->op) {
        case OP_JMP: case OP_JMPF: case OP_ACCESS:
            if (in->operand.tag == VAL_NUMBER) in->jmp_target = (int)in->operand.number;
            else in->jmp_target = 0;
            break;
        case OP_CUR: resolve_jumps(in->closure_code, in->closure_len); break;
        default: break;
        }
    }
}

/* ------------------------------------------------------------------ */
/*  VM execution                                                       */
/* ------------------------------------------------------------------ */

static Value lookup_env(int n, Value *env, int env_len) {
    if (n < 0 || n >= env_len) {
        /* Out-of-bounds access: return 0 silently.
           This occurs in nested closures with empty captured environments
           during interp execution. The sentinel value allows graceful
           degradation; downstream guards (cons?, =, etc.) reject it. */
        Value v; memset(&v, 0, sizeof(v)); v.tag = VAL_NUMBER; v.number = 0; return v;
    }
    return env[env_len - 1 - n];
}
static void env_push(Value **env, int *env_len, int *env_cap, Value v) {
    if (*env_len >= *env_cap) {
        int new_cap = *env_cap ? (*env_cap) * 2 : 4;
        gc_root_push_value(&v);            /* root v across GC_VALUE_ARRAY */
        Value *new_env = GC_VALUE_ARRAY(new_cap);
        if (*env_len > 0) memcpy(new_env, *env, *env_len * sizeof(Value));
        *env = new_env; *env_cap = new_cap;
        gc_root_pop();
    }
    (*env)[(*env_len)++] = v;
    if (gc_in_oldgen(*env) && value_references_nursery(&v))
        gc_dirty_vectors_add(*env);
}
static Value env_pop(Value **env, int *env_len) {
    if (*env_len <= 0) {
        if (vm_catch_chain && vm_catch_chain->in_trap_error)
            vm_throw("runtime: pop empty environment");
        fprintf(stderr, "runtime: pop empty environment\n"); exit(1);
    }
    return (*env)[--(*env_len)];
}

int trace_counter = -1;
int trace_limit = 0;

/* Instruction limit with env-var override for huge compilations (e.g. stlib.kl).
   Cached once at vm_exec_env entry so getenv/strtoull is not called per iteration. */
static unsigned long long get_instr_limit(void) {
    const char *e = getenv("ZINCVM_INSTR_LIMIT");
    if (e && *e) {
        char *end = NULL;
        unsigned long long v = strtoull(e, &end, 10);
        if (end != e) return v;
    }
    return 5000000000ULL;
}

Value vm_exec_env(Instr *code, int code_len, Value *init_env, int init_env_len) {
    /* Push all root slots BEFORE any allocation.  &env, &stack.data, and &acc
       are pushed early (while still NULL/nil) so gc_scan_roots reads the
       CURRENT slot value at collect time — they will be reassigned across
       gc_alloc calls below.  NULL slots pin nothing, so pushing early is safe. */
    gc_root_push_ptr((void**)&code);       /* root code across allocs */
    gc_root_push_ptr((void**)&init_env);   /* root init_env across allocs */
    ValueArray stack;
    Value *env = NULL; int env_len = 0, env_cap = 0;
    Value acc; memset(&acc, 0, sizeof(acc)); acc.tag = VAL_NIL;
    gc_root_push_ptr((void**)&env);         /* ROOT_PTR — stable slot for env */
    gc_root_push_ptr((void**)&stack.data);  /* ROOT_PTR — stable slot for stack.data */
    gc_root_push_value(&acc);               /* ROOT_VALUE — stable slot for acc */
    va_init(&stack);                        /* now safe: all slots above are rooted */
    if (init_env_len > 0 && init_env) {
        env_cap = init_env_len;
        env = GC_VALUE_ARRAY(env_cap);
        memcpy(env, init_env, init_env_len * sizeof(Value));
        env_len = init_env_len;
        if (gc_in_oldgen(env)) {
            for (int j = 0; j < init_env_len; j++) {
                if (value_references_nursery(&init_env[j])) {
                    gc_dirty_vectors_add(env);
                    break;
                }
            }
        }
    }
    CallFrame *frame_stack = (CallFrame*)gc_alloc_oldgen(CALL_STACK_DEPTH * sizeof(CallFrame), GC_TYPE_CALLFRAME_ARRAY);
    if (!frame_stack) {
        gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop(); /* acc, stack.data, env, init_env, code */
        va_free(&stack); return acc;
    }
    memset(frame_stack, 0, CALL_STACK_DEPTH * sizeof(CallFrame));
    /* GC-heap int for frames_sp — survives longjmp (stack locals become dangling). */
    int *frames_sp_slot = (int*)gc_alloc_oldgen(sizeof(int), GC_TYPE_RAW);
    *frames_sp_slot = 0;
    int frames_sp = 0;
    gc_root_push_ptr((void**)&frames_sp_slot);  /* root the GC-heap int */
    gc_root_push_callframe_array(frame_stack, frames_sp_slot);
    int pc = 0; Instr *cur_code = code; int cur_len = code_len;
    int instr_count = 0;
    unsigned long long instr_limit = get_instr_limit();
    gc_root_push_ptr((void**)&cur_code);   /* ROOT_PTR — Instr** */
    gc_root_push_ptr((void**)&frame_stack); /* ROOT_PTR — CallFrame** */

    while (1) {
        if ((unsigned long long)++instr_count >= instr_limit) {
            fprintf(stderr, "[HARD LIMIT] %llu instructions, aborting at pc=%d frames=%d\n",
                    instr_limit, pc, frames_sp);
            goto done;
        }
        if (trace_counter >= 0) {
            if (++trace_counter >= trace_limit) trace_counter = -1;
        }
        if (pc < 0 || pc >= cur_len) {
            if (frames_sp > 0) {
                CallFrame *cf = &frame_stack[--frames_sp];
                *frames_sp_slot = frames_sp;
                cur_code = cf->code; cur_len = cf->code_len; pc = cf->pc;
                env = cf->env; env_len = cf->env_len; env_cap = cf->env_cap;
                va_free(&stack);
                stack = cf->stack;
                /* Release stale GC pointers in the popped slot so the full
                 * CALLFRAME_ARRAY scan (gc.c) does not keep dead frame envs /
                 * stacks reachable until the slot is reused. */
                cf->env = NULL; cf->stack.data = NULL; cf->stack.len = 0;
                cf->code = NULL; cf->code_len = 0; cf->pc = 0;
                continue;
            }
            break;
        }
        Instr *in = &cur_code[pc];
        /* Trace: print instruction if current code is being watched */
        if (num_traced > 0) {
            for (int t = 0; t < num_traced; t++) {
                if (cur_code == traced_code[t]) {
                    printf("[%s] ", traced_name[t]);
                    print_instr_one(in, pc);
                    break;
                }
            }
        }
        switch (in->op) {
        case OP_NUMBER: case OP_STRING: case OP_SYMBOL: case OP_BOOLEAN:
            acc = in->operand;
            va_push(&stack, acc);
            pc++; break;
        case OP_PRIM: {
            /* ZINC [prim X]: args already on stack (auto-pushed by loads).
               Execute primitive, push result. */
            const char *pn = (in->operand.tag == VAL_SYMBOL) ? in->operand.sym.name : "";
            if (exec_primitive(pn, &acc, &stack) < 0) goto done;
            va_push(&stack, acc);
            if (trace_counter >= 0 && trace_counter < trace_limit + 5) {
                fprintf(stderr, "    -> acc after prim %s: ", pn);
                print_value(acc); fprintf(stderr, " (tag=%d)\n", acc.tag);
            }
            pc++;
            break;
        }
        case OP_PUSHMARK: va_push(&stack, val_mark()); pc++; break;
        case OP_GRAB: {
            if (stack.len > 0 && va_peek(&stack).tag == VAL_MARK) {
                va_pop(&stack);
                if (frames_sp > 0) {
                    CallFrame *cf = &frame_stack[--frames_sp];
                    *frames_sp_slot = frames_sp;
                    cur_code = cf->code; cur_len = cf->code_len; pc = cf->pc;
                    env = cf->env; env_len = cf->env_len; env_cap = cf->env_cap;
                    stack = cf->stack;
                    /* Release stale GC pointers in the popped slot (see above). */
                    cf->env = NULL; cf->stack.data = NULL; cf->stack.len = 0;
                    cf->code = NULL; cf->code_len = 0; cf->pc = 0;
                    va_push(&stack, acc);  /* push return value to caller stack */
                } else goto done;
            } else if (stack.len > 0) { env_push(&env, &env_len, &env_cap, va_pop(&stack)); pc++; }
            else pc++;
            break;
        }
        case OP_APPLY: {
            /* Standard ZINC: function is auto-pushed on stack top.
               Pop it, then collect args up to the mark.
               zinc-c always emits pushmark — the mark is required. */
            if (stack.len > 0) acc = va_pop(&stack);  /* pop function */
            if (acc.tag == VAL_LAMBDA) {
                check_closure(acc, "APPLY");
                /* Collect all non-mark args (stop at the mark).
                   Stale marks and function already popped above. */
                int nargs = 0;
                Value argbuf[64];
                while (stack.len > 0 && va_peek(&stack).tag != VAL_MARK) {
                    if (nargs < 64) argbuf[nargs++] = va_pop(&stack);
                    else { vm_throw("runtime: too many args (>64)"); }
                }
                /* Pop the required mark (zinc-c always emits pushmark) */
                if (stack.len == 0 || va_peek(&stack).tag != VAL_MARK) {
                    fprintf(stderr, "runtime: apply missing pushmark\n"); goto done;
                }
                va_pop(&stack);
                gc_root_push_value_array(argbuf, &nargs);  /* root argbuf before any alloc below */

                if (frames_sp >= CALL_STACK_DEPTH) { goto done; }
                CallFrame *cf = &frame_stack[frames_sp++];
                *frames_sp_slot = frames_sp;
                cf->code = cur_code; cf->code_len = cur_len; cf->pc = pc + 1;
                cf->env = env; cf->env_len = env_len; cf->env_cap = env_cap;
                cf->stack = stack; va_init(&stack);

                env = NULL; env_len = 0; env_cap = 0;

                int lambda_env_len = acc.lambda.env_len;
                int new_env_len = lambda_env_len + nargs;
                Value *ne = GC_VALUE_ARRAY(new_env_len);
                /* acc.lambda.env stays reachable via the precise-root shadow
                 * stack (&acc is rooted in vm_exec_env prologue). */
                cur_code = acc.lambda.code; cur_len = acc.lambda.code_len;
                Value *lambda_env = acc.lambda.env;
                int ne_is_oldgen = gc_in_oldgen(ne);
                if (lambda_env_len > 0 && lambda_env) {
                    memcpy(ne, lambda_env, lambda_env_len * sizeof(Value));
                    if (ne_is_oldgen) {
                        for (int j = 0; j < lambda_env_len; j++) {
                            if (value_references_nursery(&lambda_env[j])) {
                                gc_dirty_vectors_add(ne);
                                break;
                            }
                        }
                    }
                }
                for (int i = 0; i < nargs; i++) {
                    ne[lambda_env_len + i] = argbuf[i];
                    if (ne_is_oldgen && value_references_nursery(&argbuf[i]))
                        gc_dirty_vectors_add(ne);
                }
                env = ne; env_len = new_env_len; env_cap = new_env_len;
                gc_root_pop();  /* argbuf */
                pc = 0;
            } else if (acc.tag == VAL_PRIM) {
                /* Function already popped; pop mark before args if present */
                if (stack.len > 0 && va_peek(&stack).tag == VAL_MARK) va_pop(&stack);
                const char *pn = acc.prim.name;
                if (exec_primitive(pn, &acc, &stack) < 0) goto done;
                va_push(&stack, acc);
                pc++;
            } else {
                if (vm_catch_chain && vm_catch_chain->in_trap_error)
                    vm_throw("apply non-callable");
                fprintf(stderr, "runtime: apply non-callable tag=%d", acc.tag);
                if (acc.tag == VAL_SYMBOL) {
                    fprintf(stderr, " sym='%s'", acc.sym.name);
                }
                fprintf(stderr, " at pc=%d depth=%d", pc, frames_sp);
                fprintf(stderr, "\n");
                goto done;
            }
            break;
        }
        case OP_RETURN: {
            if (frames_sp > 0) {
                CallFrame *cf = &frame_stack[--frames_sp];
                *frames_sp_slot = frames_sp;
                cur_code = cf->code; cur_len = cf->code_len; pc = cf->pc;
                env = cf->env; env_len = cf->env_len; env_cap = cf->env_cap;
                va_free(&stack);
                stack = cf->stack;
                /* Release stale GC pointers in the popped slot (see above). */
                cf->env = NULL; cf->stack.data = NULL; cf->stack.len = 0;
                cf->code = NULL; cf->code_len = 0; cf->pc = 0;
                va_push(&stack, acc);  /* push return value to caller stack */
            } else goto done;
            break;
        }
        case OP_ACCESS:
            acc = lookup_env((in->operand.tag == VAL_NUMBER) ? (int)in->operand.number : in->jmp_target, env, env_len);
            va_push(&stack, acc);
            pc++; break;
        case OP_GLOBAL: {
            const char *nm = (in->operand.tag == VAL_SYMBOL) ? in->operand.sym.name : "";
            if (nm[0] != '\0' && !defun_is_defined(nm)) {
                char msg[256];
                snprintf(msg, sizeof(msg), "global not found: %s", nm);
                vm_throw(msg);
            }
            acc = defun_get(nm);
            va_push(&stack, acc);
            pc++; break;
        }
        case OP_LET: {
            Value v = (stack.len > 0) ? va_pop(&stack) : acc;
            env_push(&env, &env_len, &env_cap, v);
            pc++; break;
        }
        case OP_ENDLET: if (env_len > 0) env_pop(&env, &env_len); pc++; break;
        case OP_JMP: pc = in->jmp_target; break;
        case OP_JMPF: {
            Value cond = (stack.len > 0) ? va_pop(&stack) : acc;
            if (!(cond.tag == VAL_BOOLEAN && !cond.boolean)) pc++;
            else pc = in->jmp_target;
            break;
        }
        case OP_CUR: {
            /* val_lambda now GC-allocates its own env copy */
            acc = val_lambda(in->closure_code, in->closure_len, env, env_len);
            va_push(&stack, acc);
            pc++; break;
        }
        case OP_APPTERM: {
            /* Standard ZINC: pop function from stack top, collect args
               up to mark.  zinc-t always emits pushmark — required. */
            if (stack.len > 0) acc = va_pop(&stack);  /* pop function */
            if (acc.tag == VAL_LAMBDA) {
                check_closure(acc, "APPTERM");
                if (stack.len <= 0) { fprintf(stderr, "runtime: appterm empty stack\n"); goto done; }
                int nargs = 0;
                Value argbuf[64];
                while (stack.len > 0 && va_peek(&stack).tag != VAL_MARK) {
                    if (nargs < 64) argbuf[nargs++] = va_pop(&stack);
                    else { vm_throw("runtime: appterm too many args (>64)"); }
                }
                /* zinc-t always emits pushmark — required */
                if (stack.len == 0 || va_peek(&stack).tag != VAL_MARK) {
                    fprintf(stderr, "runtime: appterm missing pushmark\n"); goto done;
                }
                va_pop(&stack);  /* pop mark */
                if (nargs == 0) { fprintf(stderr, "runtime: appterm zero args\n"); goto done; }

                int lambda_env_len = acc.lambda.env_len;
                int new_env_len = lambda_env_len + nargs;
                gc_root_push_value_array(argbuf, &nargs);
                Value *ne = GC_VALUE_ARRAY(new_env_len);
                cur_code = acc.lambda.code; cur_len = acc.lambda.code_len;
                Value *lambda_env = acc.lambda.env;
                int ne_is_oldgen = gc_in_oldgen(ne);
                if (lambda_env_len > 0 && lambda_env) {
                    memcpy(ne, lambda_env, lambda_env_len * sizeof(Value));
                    if (ne_is_oldgen) {
                        for (int j = 0; j < lambda_env_len; j++) {
                            if (value_references_nursery(&lambda_env[j])) {
                                gc_dirty_vectors_add(ne);
                                break;
                            }
                        }
                    }
                }
                for (int i = 0; i < nargs; i++) {
                    ne[lambda_env_len + i] = argbuf[i];
                    if (ne_is_oldgen && value_references_nursery(&argbuf[i]))
                        gc_dirty_vectors_add(ne);
                }
                env = ne; env_len = new_env_len; env_cap = new_env_len;
                gc_root_pop();
                pc = 0; break;
            } else if (acc.tag == VAL_PRIM) {
                /* Function already popped; pop mark before args if present */
                if (stack.len > 0 && va_peek(&stack).tag == VAL_MARK) va_pop(&stack);
                const char *pn = acc.prim.name;
                if (exec_primitive(pn, &acc, &stack) < 0) goto done;
                va_push(&stack, acc);
                pc++; break;
            } else {
                if (vm_catch_chain && vm_catch_chain->in_trap_error)
                    vm_throw("appterm non-lambda");
                fprintf(stderr, "runtime: appterm non-lambda\n"); goto done;
            }
        }
        default: fprintf(stderr, "runtime: unknown op %d at pc=%d\n", (int)in->op, pc); goto done;
        }
    }
done:
    /* 9 pops (LIFO): callframe_array, frames_sp_slot, frame_stack, cur_code, acc, stack.data, env, init_env, code */
    gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop();
    gc_root_pop(); gc_root_pop(); gc_root_pop(); gc_root_pop();
    va_free(&stack);
    /* frame_stack is GC-allocated — no free needed */
    return acc;
}

Value vm_exec(Instr *code, int code_len) {
    return vm_exec_env(code, code_len, NULL, 0);
}

/* ------------------------------------------------------------------ */
/*  Meta REPL                                                          */
/* ------------------------------------------------------------------ */
#ifndef ZINCTEST
/* Call a bundled lambda closure by name with a single argument.
   Mirrors the convention used in eval-kl: the arg is placed after the
   closure's captured env, and the closure reads its param via `access N`. */
static Value call_closure1(const char *name, Value arg) {
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

/* Call a bundled lambda closure by name with three arguments
   (used for parse-exprs Str Pos Len). */
static Value call_closure3(const char *name, Value a, Value b, Value c) {
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

static int is_defun_form(Value f) {
    if (f.tag != VAL_CONS) return 0;
    Value h = *f.cons.car;
    return h.tag == VAL_SYMBOL && strcmp(h.sym.name, "defun") == 0;
}

/* Evaluate a KLambda form through the metacircular interpreter via eval-kl.
   This resolves [global G] references through the interp's OWN global-table
   (namespace 2, the Shen `global-table` list), so it can call OS closures
   (shen.initialise, shen.repl, ...) that were loaded at runtime via
   interp-load-raw — NOT the C VM native global_table[] (namespace 1). */
static Value eval_kl_form(Value form) {
    ValueArray s; va_init(&s);
    va_push(&s, form);
    Value acc; memset(&acc, 0, sizeof(acc));
    exec_primitive("eval-kl", &acc, &s);
    va_free(&s);
    return acc;
}

/* Read one line from stdin (until newline or EOF), growing the buffer.
   Returns malloc'd string (caller frees) or NULL on EOF. */
static char *read_stdin_line(void) {
    int cap = 256, len = 0;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    int ch;
    while ((ch = fgetc(stdin)) != EOF && ch != '\n') {
        if (len >= cap - 1) {
            cap *= 2;
            char *newbuf = realloc(buf, cap);
            if (!newbuf) { free(buf); return NULL; }
            buf = newbuf;
        }
        buf[len++] = (char)ch;
    }
    if (ch == EOF && len == 0) { free(buf); return NULL; }
    buf[len] = '\0';
    return buf;
}

/* Print a Shen-style representation of a value (uses str_value). */
static void print_shen(Value v) {
    char *pbuf = malloc(4096); int pos = 0;
    str_value(v, pbuf, &pos, 4096, 0);
    pbuf[pos] = '\0';
    printf("%s\n", pbuf);
    fflush(stdout);
    free(pbuf);
}

/* The meta REPL: reads KLambda text, parses it with the bundled
   parse-exprs reader, evaluates each form via eval-kl (expressions)
   or interp-eval (defuns).  Bypasses the Shen OS REPL (shen.repl)
   which is not present in the reduced bundle. */
static void meta_repl(void) {
    printf("=== Meta REPL (metacircular KLambda interpreter, no Shen OS) ===\n");
    printf("Type KLambda expressions.  Primitive calls evaluate, e.g.\n");
    printf("  (+ 1 2)  (cons 1 2)  (hd ...)  (tl ...)  (cn \"a\" \"b\")\n");
    printf("  (= x y)  (< x y)     (str X)   (number? X)\n");
    printf("Structural forms (if/and/or/cond/let/lambda/defun) and calls to\n");
    printf("non-primitive bundled closures need the metacircular compile\n");
    printf("pipeline, which is not yet functional in the reduced C-VM bundle\n");
    printf("(the repo's open 'close the loop' item).\n");
    printf("Ctrl-D (EOF) to exit.\n\n");
    fflush(stdout);

    while (1) {
        printf("meta> "); fflush(stdout);
        char *line = read_stdin_line();
        if (!line) break;

        /* skip blank / whitespace-only lines */
        int only_ws = 1;
        for (char *p = line; *p; p++) if (!isspace((unsigned char)*p)) { only_ws = 0; break; }
        if (only_ws) { free(line); continue; }

        int n = (int)strlen(line);
        Value Str = val_string(line, n);
        Value Zero = val_number(0);
        Value Len = val_number((long)n);

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
            free(line); continue;
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
            gc_root_push_value_volatile(&result); /* S3: root result across loop body */
            int err = 0;
            if (setjmp(cf.buf) == 0) {
                if (is_defun) {
                    /* register a defun in the Shen global-table via interp-eval.
                       NOTE: this requires the metacircular compile pipeline
                       (kl->zinc's non-primitive branch), which is not functional
                       in the reduced C-VM bundle yet (the "close the loop" open
                       item).  We report the outcome honestly rather than assume
                       success. */
                    Value r = call_closure1("interp-eval", expr);
                    result = r;
                } else {
                    /* evaluate an expression via eval-kl */
                    ValueArray s; va_init(&s);
                    va_push(&s, expr);
                    Value acc; memset(&acc, 0, sizeof(acc));
                    exec_primitive("eval-kl", &acc, &s);
                    va_free(&s);
                    result = acc;
                }
            } else {
                err = 1;
                result = cf.error_val;
            }
            vm_catch_chain = cf.parent;

            if (is_defun) {
                /* The defun form compiles to a [lambda ...] tagged closure; if
                   interp-eval succeeded, print the defun name it returns, else
                   report the registration error. */
                if (!err && result.tag == VAL_SYMBOL) {
                    printf("; registered ");
                    print_shen(result);
                } else {
                    printf("; defun registration failed: ");
                    print_shen(result);
                }
            } else {
                printf("=> ");
                print_shen(result);
            }
            gc_root_pop();  /* S3: result */
            cur = *cur.cons.cdr;
        }
        free(line);
    }
    printf("\nBye.\n");
}
#endif /* !ZINCTEST — meta-repl helpers are only used by zincvm main */

/* ------------------------------------------------------------------ */
/*  File reading                                                       */
/* ------------------------------------------------------------------ */

char *read_file_or_stdin(const char *path) {
    FILE *f = path ? fopen(path, "r") : stdin;
    if (!f) { fprintf(stderr, "error: cannot open '%s'\n", path); return NULL; }
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    int ch;
    while ((ch = fgetc(f)) != EOF) {
        if (len >= cap - 1) { cap *= 2; buf = realloc(buf, cap); }
        buf[len++] = (char)ch;
    }
    buf[len] = '\0';
    if (path) fclose(f);
    return buf;
}

/* Test runner functions (alarm_handler, run_test_timeout, run_test,
 * force_nursery_scavenge, gc_nursery_tests) moved to zinctest.c */

void init_globals(void) {
    /* Register all C primitives as VAL_PRIM globals so [global X] falls back
       to them.  c-strlen / char-code / substring are NON-STANDARD extras kept
       for the load.shen parser hot path (see prims.def); the name list is the
       generated prim_names[] (single source: vm/prims.def). */
    for (int i = 0; prim_names[i]; i++) defun_set(prim_names[i], val_prim(prim_names[i]));
}

/* ------------------------------------------------------------------ */
/*  Bundle parser: load serialized closures into global table          */
/* ------------------------------------------------------------------ */

/*
 * Parse a bundle: ((name1 code1) (name2 code2) ...)
 * Each entry: (name_csexp code_csexp)
 *   where name_csexp is a csexp atom and code_csexp is a csexp list
 * Returns number of entries loaded (0 on error).
 */
int parse_bundle(const char *str) {
    ParseState ps = {0};
    ps.p = str; ps.start = str;

    volatile size_t parse_wm = gc_root_watermark();
    if (setjmp(parse_err_jmp)) {
        /* Free scratch buffer + C-heap operand strings from parse_body */
        if (ps.scratch_buf) {
            for (int i = 0; i < ps.scratch_len; i++) {
                if (ps.scratch_buf[i].operand.tag == VAL_STRING)
                    free(ps.scratch_buf[i].operand.str.data);
            }
            free(ps.scratch_buf);
        }
        /* Free any side-slots from parse_body OP_CUR rooting */
        for (int i = 0; i < ps.cc_len; i++)
            free(ps.cc_slots[i]);
        free(ps.cc_slots);
        gc_root_pop_to(parse_wm);
        fprintf(stderr, "%s\n", parse_err_msg);
        return 0;
    }

    skip_ws(&ps);
    if (*ps.p != '(') {
        fprintf(stderr, "bundle error: expected outer '('\n");
        return 0;
    }
    ps.p++; /* skip '(' */

    int count = 0;
    while (1) {
        skip_ws(&ps);
        if (*ps.p == ')') { ps.p++; break; } /* end of bundle */
        if (*ps.p != '(') {
            fprintf(stderr, "bundle error: expected '(' for entry\n");
            return count;
        }
        ps.p++; /* skip '(' */

        /* Parse name atom */
        Value name_val = parse_csexp_atom(&ps);
        if (name_val.tag != VAL_SYMBOL) {
            fprintf(stderr, "bundle error: name must be a symbol\n");
            return count;
        }
        const char *name = name_val.sym.name;
        /* Keep full safe.* name -- primitives stay under short names */
        const char *key = name;


        /* Parse code list (a cur wrapping the closure body) */
        Instr *code = NULL;
        int code_len = parse_csexp_list(&ps, &code);
        if (code_len <= 0 || code == NULL) {
            fprintf(stderr, "bundle error: failed to parse code for '%s'\n", name);
            return count;
        }

        /* Unwrap the outer cur: use its closure_code as the lambda body */
        if (code_len < 1 || code[0].op != OP_CUR || code[0].closure_code == NULL) {
            fprintf(stderr, "bundle error: expected cur wrapper for '%s'\n", name);
            return count;
        }
        Instr *body_code = code[0].closure_code;
        int body_len = code[0].closure_len;

        /* Resolve jumps in the body */
        resolve_jumps(body_code, body_len);

        /* Create a closure from the body code (empty env) and store in globals */
        Value closure = val_lambda(body_code, body_len, NULL, 0);
        defun_set(key, closure);
        /* code is GC-allocated — no free needed */

        /* Consume closing ')' of entry */
        skip_ws(&ps);
        if (*ps.p != ')') {
            fprintf(stderr, "bundle error: expected ')' to close entry '%s'\n", name);
            return count;
        }
        ps.p++;

        count++;
    }

    return count;
}

/* ------------------------------------------------------------------ */
/*  defun_freeze: build the minimal perfect hash                       */
/* ------------------------------------------------------------------ */

/* Build a bucket+displacement minimal perfect hash over the deduplicated
 * bootstrap key set and lay it out in defun_table.  Called ONCE at the end
 * of vm_load_bundle, when the full key set is known.  The C VM never
 * executes `defun`, so bootstrap keys are exactly primitives + bundle
 * closures + keywords.  After this, defun_mode flips to DEFUN_RUNTIME and
 * the overflow tail handles any keys set after bundle load. */
static void defun_freeze(void) {
    /* 1. Deduplicate (later entries win — keywords override primitives/
          closures with the same name, e.g. `cons`). */
    BootstrapEntry *uniq = malloc((size_t)(bootstrap_count ? bootstrap_count : 1)
                                  * sizeof(BootstrapEntry));
    if (!uniq) { fprintf(stderr, "defun freeze OOM\n"); abort(); }
    int N = 0;
    for (int i = 0; i < bootstrap_count; i++) {
        const char *nm = bootstrap_keys[i].name;
        int found = -1;
        for (int j = 0; j < N; j++)
            if (strcmp(uniq[j].name, nm) == 0) { found = j; break; }
        if (found >= 0)
            uniq[found].value = bootstrap_keys[i].value;   /* later wins */
        else {
            uniq[N].name = strdup(nm);
            uniq[N].value = bootstrap_keys[i].value;
            N++;
        }
    }

    /* The defun table was never written during bootstrap; zero it so the
       perfect layout starts clean and the overflow tail is NULL. */
    for (int i = 0; i < DEFUN_TABLE_CAP; i++)
        defun_table[i].name = NULL;

    /* 2..7. Bucket+displacement construction with a doubling safety valve
       (should never fire). */
    int B = (N / 2 < 1) ? 1 : N / 2;
    uint32_t *disp = NULL;
    bool *used = NULL;
    int built = 0;

    while (!built) {
        /* Partition keys into B buckets by h0(key) % B. */
        int *bsize = calloc((size_t)B, sizeof(int));
        for (int k = 0; k < N; k++)
            bsize[hash_name_h0(uniq[k].name) % (uint32_t)B]++;

        int *boff = malloc((size_t)(B + 1) * sizeof(int));
        boff[0] = 0;
        for (int i = 0; i < B; i++) boff[i + 1] = boff[i] + bsize[i];
        int *bkeys = malloc((size_t)N * sizeof(int));
        int *fill = calloc((size_t)B, sizeof(int));
        for (int k = 0; k < N; k++) {
            int b = hash_name_h0(uniq[k].name) % (uint32_t)B;
            bkeys[boff[b] + fill[b]++] = k;
        }

        /* Sort bucket ids by size descending (largest first). */
        int *order = malloc((size_t)B * sizeof(int));
        for (int i = 0; i < B; i++) order[i] = i;
        for (int i = 1; i < B; i++) {
            int t = order[i], j = i - 1;
            while (j >= 0 && bsize[order[j]] < bsize[t]) { order[j + 1] = order[j]; j--; }
            order[j + 1] = t;
        }

        used = calloc((size_t)N, sizeof(bool));
        disp = calloc((size_t)B, sizeof(uint32_t));
        built = 1;

        for (int oi = 0; oi < B; oi++) {
            int b = order[oi];
            int sz = bsize[b];
            uint32_t d = 0;
            int ok = 0;
            for (; d < 1000000u; d++) {
                int distinct = 1;
                for (int x = 0; x < sz && distinct; x++) {
                    int k = bkeys[boff[b] + x];
                    uint32_t slot = hash_name_h1(uniq[k].name, d) % (uint32_t)N;
                    if (used[slot]) { distinct = 0; break; }
                    for (int y = 0; y < x && distinct; y++) {
                        int k2 = bkeys[boff[b] + y];
                        if (hash_name_h1(uniq[k2].name, d) % (uint32_t)N == slot)
                            distinct = 0;
                    }
                }
                if (distinct) { ok = 1; break; }
            }
            if (!ok) { built = 0; break; }   /* B too small → double and restart */
            disp[b] = d;
            for (int x = 0; x < sz; x++) {
                int k = bkeys[boff[b] + x];
                uint32_t slot = hash_name_h1(uniq[k].name, d) % (uint32_t)N;
                defun_table[slot].name = (char *)uniq[k].name;
                defun_table[slot].value = uniq[k].value;
                used[slot] = true;
            }
        }

        free(bsize); free(boff); free(bkeys); free(fill); free(order);
        if (!built) { free(used); free(disp); B *= 2; }
    }

    /* 8. Assertion: every slot filled, no duplicate names (collision-free). */
    for (int i = 0; i < N; i++) {
        if (defun_table[i].name == NULL) {
            fprintf(stderr, "defun_freeze: slot %d left empty (N=%d)\n", i, N);
            abort();
        }
        for (int j = i + 1; j < N; j++) {
            if (defun_table[j].name != NULL &&
                strcmp(defun_table[i].name, defun_table[j].name) == 0) {
                fprintf(stderr, "defun_freeze: duplicate name '%s' at slots %d,%d\n",
                        defun_table[i].name, i, j);
                abort();
            }
        }
        /* The bundle closures were allocated in the nursery during bootstrap,
         * before any collection.  Mark every perfect slot dirty so the FIRST
         * nursery scavenge (which only rescans dirty defun slots) evacuates
         * them to old-gen instead of reclaiming their code.  Without this,
         * non-dirty perfect slots are skipped and the closures go stale. */
        gc_dirty_defuns_mark(i);
    }
    printf("Perfect hash built: N=%d keys, B=%d buckets, "
           "%d overflow slots — collision-free (all %d slots distinct)\n",
           N, B, DEFUN_OVERFLOW_CAP, N);

    defun_table_size = N;
    defun_buckets = B;
    defun_displacement = disp;
    defun_mode = DEFUN_RUNTIME;
    defun_table_used = N;
    defun_table_cap = N + DEFUN_OVERFLOW_CAP;

    /* 9. Free bootstrap state.  defun_table now OWNS the strdup'd names
       (uniq[k].name); free the container arrays and the now-redundant
       bootstrap key strings, but NOT the uniq names. */
    for (int i = 0; i < bootstrap_count; i++) free((void *)bootstrap_keys[i].name);
    free(bootstrap_keys);
    bootstrap_keys = NULL; bootstrap_count = 0; bootstrap_cap = 0;
    free(uniq);
    free(used);
}

/* ------------------------------------------------------------------ */
/*  vm_load_bundle: shared bundle-bootstrap for zincvm and zinctest    */
/* ------------------------------------------------------------------ */

/* Parse a bundle string and set up the global-table environment
 * (keyword symbols, standard I/O streams, Shen global-table var).
 * Returns the number of closures loaded; 0 on error.
 * Does NOT free(buf) or call trace_resolve/gc_nursery_tests. */
int vm_load_bundle(const char *buf) {
    const char *p = buf;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '(' || *(p+1) != '(') {
        fprintf(stderr, "bundle error: not a bundle (expected ((...)))\n");
        return 0;
    }

    int n = parse_bundle(p);
    printf("Loaded %d closures into global table\n\n", n);
    fflush(stdout);

    /* Register ZINC pattern keywords as symbols. When zinc-c, zinc-t,
       normalize-term, debruijn etc. were self-compiled via set-toplevel,
       their patterns like [number X], [cons X Y], [lambda C E] etc.
       became bytecode with "global number", "global cons" etc. to
       obtain the tag symbol for structural matching at runtime.
       These must resolve to val_symbol, not val_prim or a closure. */
    const char *keywords[] = {
        "number", "symbol", "string", "boolean", "cons",
        "lambda", "function", "error", "absvector",
        "stream in", "stream out", "let", "if",
        "lookup", "freeze", "type", "defun", "define",
        "cond", "and", "or", "do", "fn",
        "list", "where",
        NULL
    };
    /* Only register keywords that are NOT already bundle entries.
       Pattern tags now compile to `symbol X` loads, so nothing in the
       bundle needs e.g. [global lookup] to resolve to a symbol; but the
       metacircular interp DOES need [global lookup] to resolve to its
       bundled `lookup` closure.  Registering over it broke every
       interpreted `access` instruction ("apply non-callable
       sym=lookup"). */
    for (int i = 0; keywords[i]; i++)
        if (!defun_has(keywords[i]))
            defun_set(keywords[i], val_symbol(keywords[i]));

    /* Initialize standard I/O stream variables expected by the Shen OS.
       The bundled stinput/stoutput closures use (value *stinput*),
       (value *stoutput*) — these resolve to value_get("*stinput*") etc.
       shen.initialise-environment does NOT set them; the host port must. */
    {
        Value stin;  memset(&stin, 0, sizeof(stin));
        stin.tag = VAL_STREAM; stin.stream.file = stdin;  stin.stream.is_input = 1;
        value_set("*stinput*", stin);

        Value stout; memset(&stout, 0, sizeof(stout));
        stout.tag = VAL_STREAM; stout.stream.file = stdout; stout.stream.is_input = 0;
        value_set("*stoutput*", stout);

        Value sterr; memset(&sterr, 0, sizeof(sterr));
        sterr.tag = VAL_STREAM; sterr.stream.file = stderr; sterr.stream.is_input = 0;
        value_set("*sterror*", sterr);
    }

    /* Initialize the Shen global-table variable.  The metacircular
       interp's lookup-global reads (value global-table) to resolve
       non-primitive globals; it must start as an empty alist for
       interp-eval / set-toplevel to register new defuns at runtime. */
    value_set("global-table", val_nil());

    /* Initialize the Shen value-table variable.  The metacircular
       interp's interp-value / interp-set read/write (value value-table)
       as a separate values assoc list (namespace 2); it must start as an
       empty alist so a not-found assoc returns [] (not the bare symbol). */
    value_set("value-table", val_nil());

    /* Initialize primitive?-names for the bundled primitive? predicate
       (util.shen + types.shen read (value primitive?-names)).  Built from
       the single-source prim_names[] (vm/prims.def) so the C primitive set
       and Shen's primitive? stay in sync.  pn is rooted across the val_cons
       allocs below. */
    {
        Value pn = val_nil();
        gc_root_push_value(&pn);
        for (int i = 0; prim_names[i]; i++)
            pn = val_cons(val_symbol(prim_names[i]), pn);
        value_set("primitive?-names", pn);
        gc_root_pop();
    }

    /* Freeze point: the full key set (primitives + bundle closures +
       keywords) is now known.  Build the minimal perfect hash once. */
    defun_freeze();

    return n;
}

/* ------------------------------------------------------------------ */
/*  run_bytecode_file: execute a single csexp bytecode file             */
/* ------------------------------------------------------------------ */
#ifndef ZINCTEST
static void run_bytecode_file(const char *label, const char *src) {
    (void)label;  /* label is informational; not printed in production mode */
    Instr *code = NULL;
    int len = parse_bytecode(src, &code);
    if (len <= 0 || code == NULL) {
        printf("PARSE FAILED\n");
        return;
    }
    resolve_jumps(code, len);
    CatchFrame cf;
    cf.parent = vm_catch_chain;
    cf.in_trap_error = 0;
    vm_catch_chain = &cf;
    if (setjmp(cf.buf)) {
        vm_catch_chain = cf.parent;
        gc_root_push_value(&cf.error_val);   /* S3: root error message */
        printf("ERROR: "); print_value(cf.error_val); printf("\n");
        gc_root_pop();  /* S3: cf.error_val */
    } else {
        Value result = vm_exec(code, len);
        vm_catch_chain = cf.parent;
        print_value(result); printf("\n");
    }
}
#endif /* !ZINCTEST */

#ifndef ZINCTEST
int main(int argc, char **argv) {
    volatile char stack_top_marker;
    gc_set_stack_top(((uintptr_t)&stack_top_marker + GC_PAGEBYTES - 1) & ~(GC_PAGEBYTES - 1));

    init_globals();
    gc_init(256UL * 1024 * 1024);

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

            free(buf);
            if (n == 0) return 1;

            /* Find first non-flag arg after bundle (skip --trace pairs) */
            int ai = 2;
            while (ai < argc && strcmp(argv[ai], "--trace") == 0) ai += 2;

            /* -d <name>: decompile a bundled closure's bytecode */
            if (ai < argc && strcmp(argv[ai], "-d") == 0) {
                if (ai + 1 < argc) {
                    Value g = defun_get(argv[ai + 1]);
                    if (g.tag == VAL_LAMBDA) {
                        printf("=== Decompile: %s ===\n", argv[ai + 1]);
                        printf("  code_len=%d  env_len=%d\n\n", g.lambda.code_len, g.lambda.env_len);
                        print_instr(g.lambda.code, g.lambda.code_len, 0);
                    } else if (g.tag == VAL_PRIM) {
                        printf("%s is a C primitive\n", argv[ai + 1]);
                    } else {
                        printf("%s: not found (tag=%d)\n", argv[ai + 1], g.tag);
                    }
                } else {
                    printf("Usage: %s <bundle> -d <function-name>\n", argv[0]);
                }
                return 0;
            }
            /* --meta-repl: run the meta-interpreter KLambda REPL
               (bypasses the Shen OS; uses bundled parse-exprs / eval-kl /
               interp-eval — all present in the reduced bundle). */
            if (ai < argc && strcmp(argv[ai], "--meta-repl") == 0) {
                meta_repl();
                return 0;
            }
            /* --tc-hm: run the bundled HM type checker on Group A source files */
            if (ai < argc && strcmp(argv[ai], "--tc-hm") == 0) {
                printf("=== HM Type Checker ===\n");
                fflush(stdout);

                Value driver = defun_get("run-tc-hm-all");
                if (driver.tag != VAL_LAMBDA) {
                    fprintf(stderr, "--tc-hm: run-tc-hm-all not found in bundle (tag=%d)\n", driver.tag);
                    return 1;
                }
                gc_root_push_value(&driver);
                Value *env_driver = GC_VALUE_ARRAY(driver.lambda.env_len + 1);
                if (driver.lambda.env_len > 0)
                    memcpy(env_driver, driver.lambda.env, driver.lambda.env_len * sizeof(Value));
                env_driver[driver.lambda.env_len] = val_number(0);
                gc_root_pop();

                CatchFrame cf;
                cf.parent = vm_catch_chain;
                cf.in_trap_error = 0;
                vm_catch_chain = &cf;
                volatile size_t driver_wm = gc_root_watermark();
                Value result;
                int errored = 0;
                if (setjmp(cf.buf) == 0) {
                    result = vm_exec_env(driver.lambda.code, driver.lambda.code_len,
                                         env_driver, driver.lambda.env_len + 1);
                } else {
                    errored = 1;
                    result = cf.error_val;
                }
                vm_catch_chain = cf.parent;
                gc_root_pop_to(driver_wm);
                if (errored) {
                    printf("ERROR: ");
                    print_value(result);
                    printf("\n");
                } else if (result.tag == VAL_STRING) {
                    fwrite(result.str.data, 1, result.str.len, stdout);
                    printf("\n");
                } else {
                    printf("result tag=%d\n", (int)result.tag);
                }
                return 0;
            }
            /* --tc-hm-self: run the bundled HM type checker on its own 7 source files */
            if (ai < argc && strcmp(argv[ai], "--tc-hm-self") == 0) {
                printf("=== HM Type Checker (self-check) ===\n");
                fflush(stdout);

                Value driver = defun_get("run-tc-hm-self");
                if (driver.tag != VAL_LAMBDA) {
                    fprintf(stderr, "--tc-hm-self: run-tc-hm-self not found in bundle (tag=%d)\n", driver.tag);
                    return 1;
                }
                gc_root_push_value(&driver);
                Value *env_driver = GC_VALUE_ARRAY(driver.lambda.env_len + 1);
                if (driver.lambda.env_len > 0)
                    memcpy(env_driver, driver.lambda.env, driver.lambda.env_len * sizeof(Value));
                env_driver[driver.lambda.env_len] = val_number(0);
                gc_root_pop();

                CatchFrame cf;
                cf.parent = vm_catch_chain;
                cf.in_trap_error = 0;
                vm_catch_chain = &cf;
                volatile size_t driver_wm = gc_root_watermark();
                Value result;
                int errored = 0;
                if (setjmp(cf.buf) == 0) {
                    result = vm_exec_env(driver.lambda.code, driver.lambda.code_len,
                                         env_driver, driver.lambda.env_len + 1);
                } else {
                    errored = 1;
                    result = cf.error_val;
                }
                vm_catch_chain = cf.parent;
                gc_root_pop_to(driver_wm);
                if (errored) {
                    printf("ERROR: ");
                    print_value(result);
                    printf("\n");
                } else if (result.tag == VAL_STRING) {
                    fwrite(result.str.data, 1, result.str.len, stdout);
                    printf("\n");
                } else {
                    printf("result tag=%d\n", (int)result.tag);
                }
                return 0;
            }
            /* --tc-hm-tests: run the ~68 synthetic HM checker unit tests */
            if (ai < argc && strcmp(argv[ai], "--tc-hm-tests") == 0) {
                printf("=== HM Type Checker (unit tests) ===\n");
                fflush(stdout);

                Value driver = defun_get("run-tc-hm-tests");
                if (driver.tag != VAL_LAMBDA) {
                    fprintf(stderr, "--tc-hm-tests: run-tc-hm-tests not found in bundle (tag=%d)\n", driver.tag);
                    return 1;
                }
                gc_root_push_value(&driver);
                Value *env_driver = GC_VALUE_ARRAY(driver.lambda.env_len + 1);
                if (driver.lambda.env_len > 0)
                    memcpy(env_driver, driver.lambda.env, driver.lambda.env_len * sizeof(Value));
                env_driver[driver.lambda.env_len] = val_number(0);
                gc_root_pop();

                CatchFrame cf;
                cf.parent = vm_catch_chain;
                cf.in_trap_error = 0;
                vm_catch_chain = &cf;
                volatile size_t driver_wm = gc_root_watermark();
                Value result;
                int errored = 0;
                if (setjmp(cf.buf) == 0) {
                    result = vm_exec_env(driver.lambda.code, driver.lambda.code_len,
                                         env_driver, driver.lambda.env_len + 1);
                } else {
                    errored = 1;
                    result = cf.error_val;
                }
                vm_catch_chain = cf.parent;
                gc_root_pop_to(driver_wm);
                if (errored) {
                    printf("ERROR: ");
                    print_value(result);
                    printf("\n");
                } else if (result.tag == VAL_STRING) {
                    fwrite(result.str.data, 1, result.str.len, stdout);
                    printf("\n");
                } else {
                    printf("result tag=%d\n", (int)result.tag);
                }
                return 0;
            }
            /* --repl: run the interactive Shen REPL.
               The full Shen OS (.kl files) is loaded at RUNTIME into the
               metacircular interpreter's OWN global-table (namespace 2) via
               interp-load-raw, then shen.initialise / shen.repl are called
               INSIDE that interpreter through eval-kl (which resolves
               [global G] via lookup-global → namespace 2).  We do NOT use
               defun_get here: the OS closures are not in the C VM native
               global_table[] (namespace 1), they are runtime-loaded. */
            if (ai < argc && strcmp(argv[ai], "--repl") == 0) {
                printf("=== Shen REPL ===\n");
                fflush(stdout);

                /* 1. Load the Shen OS kernel .kl files into the meta-interp. */
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
                for (int oi = 0; os_order[oi] != NULL; oi++) {
                    Value osp = val_string(os_order[oi], (long)strlen(os_order[oi]));
                    gc_root_push_value(&osp);
                    Value osr = call_closure1("interp-load-raw", osp);
                    gc_root_pop();
                    if (!(osr.tag == VAL_SYMBOL && strcmp(osr.sym.name, "loaded") == 0)) {
                        fprintf(stderr, "repl: OS load failed at %s (tag=%d)\n",
                                os_order[oi], osr.tag);
                        return 1;
                    }
                }
                printf("Shen OS loaded into meta-interpreter.\n");
                fflush(stdout);

                /* 2. Call shen.initialise INSIDE the meta-interpreter. */
                {
                    Value init_form = val_cons(val_symbol("shen.initialise"), val_nil());
                    gc_root_push_value(&init_form);
                    Value initr = eval_kl_form(init_form);
                    gc_root_pop();
                    if (initr.tag == VAL_ERROR) {
                        fprintf(stderr, "repl: shen.initialise error: ");
                        print_value(initr);
                        printf("\n");
                        return 1;
                    }
                }
                printf("Shen ready.\n\n");
                fflush(stdout);

                /* 3. Run shen.repl INSIDE the meta-interpreter.
                   Intercept "error: empty stream" (EOF) to exit cleanly. */
                repl_mode = 1;
                if (setjmp(repl_exit_jmp) == 0) {
                    Value repl_form = val_cons(val_symbol("shen.repl"), val_nil());
                    gc_root_push_value(&repl_form);
                    eval_kl_form(repl_form);
                    gc_root_pop();
                }
                repl_mode = 0;

                printf("\nGoodbye.\n");
                return 0;
            }
            /* If another arg, run it as bytecode; otherwise show usage */
            if (ai < argc) {
                char *b2 = read_file_or_stdin(argv[ai]);
                if (b2) {
                    char *q = b2; while (*q && isspace((unsigned char)*q)) q++;
                    if (*q) run_bytecode_file(argv[ai], q);
                    free(b2);
                }
            } else {
                printf("Usage: %s <bundle> [--repl | --meta-repl | --tc-hm | --tc-hm-self | --tc-hm-tests | -d <name> | --trace <name>]\n",
                       argv[0]);
            }
        } else {
            /* Single bytecode list */
            if (*p) run_bytecode_file(argv[1], p); else printf("(empty file)\n");
            free(buf);
        }
        return 0;
    }

    printf("Usage: zincvm <bundle.csexp | bytecode.csexp> [--repl | --meta-repl | --tc-hm | --tc-hm-self | --tc-hm-tests | -d <name> | --trace <name>]\n");
    return 0;
}
#endif

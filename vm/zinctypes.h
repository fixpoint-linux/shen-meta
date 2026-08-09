/*
 * zinctypes.h — shared type definitions for the ZINC VM and GC
 *
 * Included by both zincvm.c and gc.c so the collector can scan
 * typed objects (Value, Instr arrays, CallFrame arrays).
 */

#ifndef ZINCVM_TYPES_H
#define ZINCVM_TYPES_H

#include <stdio.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/*  Value types                                                        */
/* ------------------------------------------------------------------ */

typedef enum {
    VAL_NUMBER,
    VAL_STRING,
    VAL_SYMBOL,
    VAL_BOOLEAN,
    VAL_CONS,
    VAL_NIL,
    VAL_LAMBDA,
    VAL_MARK,
    VAL_PRIM,
    VAL_ERROR,
    VAL_VECTOR,
    VAL_STREAM
} ValTag;

typedef struct Value {
    ValTag tag;
    union {
        long number;
        struct { char *data; int len; } str;
        struct { char *name; } sym;
        int boolean;
        struct { struct Value *car; struct Value *cdr; } cons;
        struct {
            struct Instr *code;
            int code_len;
            struct Value *env;
            int env_len;
        } lambda;
        struct { const char *name; } prim;
        struct { char *message; } error;
        struct {
            struct Value *data;
            int len;
        } vector;
        struct {
            FILE *file;         /* NULL for string streams */
            int is_input;
            int is_string;      /* 1 = string-backed, 0 = FILE-backed */
        } stream;
    };
} Value;

/* ------------------------------------------------------------------ */
/*  Instruction types                                                  */
/* ------------------------------------------------------------------ */

typedef enum {
    OP_ACCESS   = 0,  /* 'a' */
    OP_GLOBAL   = 1,  /* 'g' */
    OP_JMPF     = 2,  /* 'f' */
    OP_JMP      = 3,  /* 'j' */
    OP_APPTERM  = 4,  /* 't' */
    OP_APPLY    = 5,  /* 'p' */
    OP_PUSHMARK = 6,  /* 'm' */
    OP_CUR      = 7,  /* 'c' */
    OP_GRAB     = 8,  /* 'r' */
    OP_RETURN   = 9,  /* 'v' */
    OP_LET      = 10, /* 'e' */
    OP_ENDLET   = 11, /* 'd' */
    OP_NUMBER   = 12, /* 'n' */
    OP_STRING   = 13, /* 'S' */
    OP_SYMBOL   = 14, /* 's' */
    OP_BOOLEAN  = 15, /* 'b' */
    OP_PRIM     = 16, /* 'P' */
    OP_COUNT    = 17
} Opcode;

/* Translate a csexp opcode character to the dense enum.  Called once
   during parse (parse_body) so the VM's main dispatch switch gets a
   compact jump table instead of a branch chain. */
static inline Opcode char_to_opcode(char c) {
    switch (c) {
    case 'a': return OP_ACCESS;
    case 'g': return OP_GLOBAL;
    case 'f': return OP_JMPF;
    case 'j': return OP_JMP;
    case 't': return OP_APPTERM;
    case 'p': return OP_APPLY;
    case 'm': return OP_PUSHMARK;
    case 'c': return OP_CUR;
    case 'r': return OP_GRAB;
    case 'v': return OP_RETURN;
    case 'e': return OP_LET;
    case 'd': return OP_ENDLET;
    case 'n': return OP_NUMBER;
    case 'S': return OP_STRING;
    case 's': return OP_SYMBOL;
    case 'b': return OP_BOOLEAN;
    case 'P': return OP_PRIM;
    default: return OP_COUNT;
    }
}

/* Reverse mapping for decompilers. */
static inline char opcode_to_char(Opcode op) {
    static const char map[17] = {
        [OP_ACCESS]   = 'a',
        [OP_GLOBAL]   = 'g',
        [OP_JMPF]     = 'f',
        [OP_JMP]      = 'j',
        [OP_APPTERM]  = 't',
        [OP_APPLY]    = 'p',
        [OP_PUSHMARK] = 'm',
        [OP_CUR]      = 'c',
        [OP_GRAB]     = 'r',
        [OP_RETURN]   = 'v',
        [OP_LET]      = 'e',
        [OP_ENDLET]   = 'd',
        [OP_NUMBER]   = 'n',
        [OP_STRING]   = 'S',
        [OP_SYMBOL]   = 's',
        [OP_BOOLEAN]  = 'b',
        [OP_PRIM]     = 'P',
    };
    return (op < OP_COUNT) ? map[op] : '?';
}

typedef struct Instr {
    Opcode op;
    Value operand;
    struct Instr *closure_code;
    int closure_len;
    int jmp_target;
} Instr;

/* ------------------------------------------------------------------ */
/*  Call frame (for GC scanning)                                       */
/* ------------------------------------------------------------------ */

#define CALL_STACK_DEPTH 65536
typedef struct { Value *data; int len; int cap; } ValueArray;

typedef struct {
    Instr *code;
    int code_len;
    int pc;
    Value *env;
    int env_len;
    int env_cap;
    ValueArray stack;
} CallFrame;

/* ---- load-bearing size classes (Phase 3/4 BiBOP) ----
 * These MUST stay true: the collector's size-class routing (if/when added)
 * assumes fixed strides.  Build-verified: Value=40, Instr=64, CallFrame=48. */
_Static_assert(sizeof(Value) == 40,   "Value size class is 40B");
_Static_assert(sizeof(Instr) == 64,   "Instr size class is 64B");
_Static_assert(sizeof(CallFrame) == 48, "CallFrame size class is 48B");
_Static_assert(sizeof(ValueArray) == 16, "ValueArray is 16B");
_Static_assert(sizeof(uintptr_t) == 8, "Phase 3/4 assumes LP64");

#endif /* ZINCVM_TYPES_H */

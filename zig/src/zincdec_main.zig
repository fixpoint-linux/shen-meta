//! src/zincdec_main.zig — ZINC bytecode decompiler (standalone, GC-free)
//!
//! Zig port of the C vm/zincdec.c (821 lines).  Reads a globals.csexp bundle
//! and decompiles individual closures.  GC-free by design — it only parses
//! bundles, decompiles closures, and prints; no VM execution, no GC.
//!
//! Usage: zigdec <bundle> <function-name> [--raw|--asm|--shen|--csexp]
//!        zigdec <bundle> --curried
//!
//! Output formats (byte-for-byte match of the C tool):
//!   --raw   (default)  Human-readable opcode names
//!   --asm              Disassembly with addresses
//!   --shen             Shen list syntax (feedable to interp.shen's interp)
//!   --csexp            Raw csexp wire format
//!
//! This file does NOT import the Zig VM/GC modules (they require a booted
//! Gc); it is a self-contained port of the C tool's calloc/malloc logic using
//! a plain std.heap.ArenaAllocator.  Zig 0.16 removed std.io/std.fs, so all
//! output goes through a growing byte buffer flushed with raw posix writes.

const std = @import("std");

// ---------------------------------------------------------------------
//  Value types (mirrors zincdec.c ValTag + Value)
// ---------------------------------------------------------------------

const ValTag = enum(u32) {
    number = 0, // VAL_NUMBER
    string = 1, // VAL_STRING
    symbol = 2, // VAL_SYMBOL
    boolean = 3, // VAL_BOOLEAN
    cons = 4, // VAL_CONS
    nil = 5, // VAL_NIL
    lambda = 6, // VAL_LAMBDA
    mark = 7, // VAL_MARK
    prim = 8, // VAL_PRIM
    error_ = 9, // VAL_ERROR
    vector = 10, // VAL_VECTOR
    stream = 11, // VAL_STREAM
};

const Value = union(ValTag) {
    number: i64, // long
    string: []const u8, // data (len = slice length)
    symbol: []const u8, // name
    boolean: bool, // int
    cons: struct { car: *Value, cdr: *Value },
    nil,
    lambda: struct { code: []Instr, env: []Value },
    mark,
    prim: []const u8, // name
    error_: []const u8, // message
    vector: struct { data: []Value, len: i64 }, // data, len
    stream: struct { is_input: bool, is_string: bool },
};

// ---------------------------------------------------------------------
//  Opcodes & Instr (mirrors zincdec.c Opcode enum + Instr)
// ---------------------------------------------------------------------

const Opcode = enum(u32) {
    access = 0, // OP_ACCESS   'a'
    global = 1, // OP_GLOBAL   'g'
    jmpf = 2, // OP_JMPF     'f'
    jmp = 3, // OP_JMP      'j'
    appterm = 4, // OP_APPTERM  't'
    apply = 5, // OP_APPLY    'p'
    pushmark = 6, // OP_PUSHMARK 'm'
    cur = 7, // OP_CUR      'c'
    grab = 8, // OP_GRAB     'r'
    ret = 9, // OP_RETURN   'v'
    let = 10, // OP_LET      'e'
    endlet = 11, // OP_ENDLET   'd'
    number = 12, // OP_NUMBER   'n'
    string = 13, // OP_STRING   'S'
    symbol = 14, // OP_SYMBOL   's'
    boolean = 15, // OP_BOOLEAN  'b'
    prim = 16, // OP_PRIM     'P'
    count = 17, // OP_COUNT (char_to_opcode default)
};

fn charToOpcode(c: u8) Opcode {
    return switch (c) {
        'a' => .access,
        'g' => .global,
        'f' => .jmpf,
        'j' => .jmp,
        't' => .appterm,
        'p' => .apply,
        'm' => .pushmark,
        'c' => .cur,
        'r' => .grab,
        'v' => .ret,
        'e' => .let,
        'd' => .endlet,
        'n' => .number,
        'S' => .string,
        's' => .symbol,
        'b' => .boolean,
        'P' => .prim,
        else => .count,
    };
}

fn opcodeToChar(op: Opcode) u8 {
    return switch (op) {
        .access => 'a',
        .global => 'g',
        .jmpf => 'f',
        .jmp => 'j',
        .appterm => 't',
        .apply => 'p',
        .pushmark => 'm',
        .cur => 'c',
        .grab => 'r',
        .ret => 'v',
        .let => 'e',
        .endlet => 'd',
        .number => 'n',
        .string => 'S',
        .symbol => 's',
        .boolean => 'b',
        .prim => 'P',
        .count => '?',
    };
}

const Instr = struct {
    op: Opcode,
    operand: ?Value,
    closure: ?[]Instr, // OP_CUR sub-closure
    jmp_target: i64,
};

// ---------------------------------------------------------------------
//  Allocator + output (GC-free: arena + growing byte buffer)
// ---------------------------------------------------------------------

var alloc: std.mem.Allocator = undefined;
var out_buf: std.ArrayListUnmanaged(u8) = .empty;

/// Append raw bytes to the stdout buffer.
fn out(s: []const u8) void {
    out_buf.appendSlice(alloc, s) catch unreachable;
}

/// Format-append to the stdout buffer.
fn outPrint(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch unreachable;
    out(s);
}

/// Format-print to stderr via a raw write (C: fprintf(stderr, ...)).
fn errPrint(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch unreachable;
    _ = std.posix.system.write(2, s.ptr, s.len);
}

/// Flush the stdout buffer to fd 1.
fn flushOut() void {
    _ = std.posix.system.write(1, out_buf.items.ptr, out_buf.items.len);
}

// ---------------------------------------------------------------------
//  Global table (mirrors zincdec.c global_table)
// ---------------------------------------------------------------------

const GLOBAL_TABLE_MAX = 2048;
const GlobalEntry = struct { name: []const u8, closure: Value };
var global_table: [GLOBAL_TABLE_MAX]GlobalEntry = undefined;
var global_table_len: usize = 0;

fn globalSet(name: []const u8, v: Value) void {
    for (global_table[0..global_table_len]) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            e.closure = v;
            return;
        }
    }
    if (global_table_len < GLOBAL_TABLE_MAX) {
        global_table[global_table_len] = .{
            .name = alloc.dupe(u8, name) catch unreachable,
            .closure = v,
        };
        global_table_len += 1;
    }
}

fn globalGet(name: []const u8) Value {
    for (global_table[0..global_table_len]) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.closure;
    }
    return valPrim(name);
}

// --- Value helpers ---
fn valNumber(n: i64) Value {
    return .{ .number = n };
}
fn valString(data: []const u8) Value {
    return .{ .string = alloc.dupe(u8, data) catch unreachable };
}
fn valSymbol(name: []const u8) Value {
    return .{ .symbol = alloc.dupe(u8, name) catch unreachable };
}
fn valBoolean(b: bool) Value {
    return .{ .boolean = b };
}
fn valLambda(code: []Instr, env: []Value) Value {
    return .{ .lambda = .{ .code = code, .env = env } };
}
fn valPrim(name: []const u8) Value {
    return .{ .prim = alloc.dupe(u8, name) catch unreachable };
}

/// Mirrors C print_value (zincdec.c:218-239).  Cons/lambda/etc carry pointer
/// payloads never produced by the csexp parser (only symbol/number/string/
/// boolean operands appear), but the cases are preserved for fidelity.
fn printValue(v: Value) void {
    switch (v) {
        .number => |n| outPrint("{d}", .{n}),
        .string => |s| outPrint("\"{s}\"", .{s}),
        .symbol => |s| outPrint("{s}", .{s}),
        .boolean => |b| out(if (b) "true" else "false"),
        .cons => |c| {
            out("[cons ");
            printValue(c.car.*);
            out(" . ");
            printValue(c.cdr.*);
            out("]");
        },
        .nil => out("[]"),
        .lambda => |l| {
            // C prints raw pointer addresses (%p) — nondeterministic and never
            // reached by the fixture gate (operands are never lambdas).
            outPrint("[lambda {d} env={d}]", .{ l.code.len, l.env.len });
        },
        .mark => out("mark"),
        .prim => |p| outPrint("[prim {s}]", .{p}),
        .error_ => |e| outPrint("[error \"{s}\"]", .{e}),
        .vector => |vec| outPrint("[vector {d}]", .{vec.len}),
        .stream => |st| outPrint("[stream {s}]", .{if (st.is_input) "in" else "out"}),
    }
}

// ---------------------------------------------------------------------
//  Parser state
// ---------------------------------------------------------------------

const ParseState = struct {
    p: []const u8,
    start: []const u8,
};

const ParseFailed = error{ParseFailed};

var parse_err_buf: [256]u8 = undefined;
var parse_err_msg: []const u8 = "";

/// Mirrors C PARSE_ERROR macro: builds "parse error at offset %ld: %s".
fn parseError(ps: *ParseState, msg: []const u8) ParseFailed {
    const off = @intFromPtr(ps.p.ptr) - @intFromPtr(ps.start.ptr);
    parse_err_msg = std.fmt.bufPrint(&parse_err_buf, "parse error at offset {d}: {s}", .{ off, msg }) catch unreachable;
    return ParseFailed.ParseFailed;
}

fn skipWs(ps: *ParseState) void {
    while (ps.p.len > 0 and std.ascii.isWhitespace(ps.p[0])) ps.p = ps.p[1..];
}

fn parseInt(ps: *ParseState) ParseFailed!i64 {
    if (ps.p.len == 0 or !std.ascii.isDigit(ps.p[0])) return parseError(ps, "expected digit");
    var n: i64 = 0;
    while (ps.p.len > 0 and std.ascii.isDigit(ps.p[0])) {
        n = n * 10 + (ps.p[0] - '0');
        ps.p = ps.p[1..];
    }
    return n;
}

/// Mirrors C parse_csexp_atom (zincdec.c:288-310).  Produces symbol/number/
/// string/boolean values from a `[len:type]value` atom.
fn parseCsexpAtom(ps: *ParseState) ParseFailed!Value {
    skipWs(ps);
    if (ps.p.len == 0 or ps.p[0] != '[') return parseError(ps, "expected '[' for csexp atom");
    ps.p = ps.p[1..];
    const len = try parseInt(ps);
    if (ps.p.len == 0 or ps.p[0] != ':') return parseError(ps, "expected ':' after length");
    ps.p = ps.p[1..];
    if (ps.p.len == 0) return parseError(ps, "expected type after ':'");
    const ty = ps.p[0];
    ps.p = ps.p[1..];
    if (ps.p.len == 0 or ps.p[0] != ']') return parseError(ps, "expected ']' after type");
    ps.p = ps.p[1..];
    if (len < 0) return parseError(ps, "negative length");
    const l: usize = @intCast(len);
    if (ps.p.len < l) return parseError(ps, "not enough bytes for atom value");
    const data = ps.p[0..l];
    ps.p = ps.p[l..];
    switch (ty) {
        's' => return valSymbol(data),
        'n' => {
            // C uses atol(buf): parse decimal, 0 on no conversion.
            const num = std.fmt.parseInt(i64, data, 10) catch 0;
            return valNumber(num);
        },
        'S' => return valString(data),
        'b' => return valBoolean(std.mem.eql(u8, data, "true")),
        else => return parseError(ps, "unknown csexp type"),
    }
}

/// Mirrors C parse_body (zincdec.c:313-340).
fn parseBody(ps: *ParseState, list: *std.ArrayListUnmanaged(Instr)) ParseFailed!i64 {
    while (true) {
        skipWs(ps);
        if (ps.p.len == 0 or ps.p[0] == ')') break;
        if (ps.p[0] == '(') return parseError(ps, "unexpected nested list in body");
        const c = ps.p[0];
        ps.p = ps.p[1..];
        const op = charToOpcode(c);
        var instr = Instr{ .op = op, .operand = null, .closure = null, .jmp_target = 0 };
        switch (c) {
            'm', 'p', 'r', 'v', 'e', 'd', 't' => {},
            'a', 'f', 'j', 'n', 'g', 's', 'P', 'S', 'b' => {
                instr.operand = try parseCsexpAtom(ps);
            },
            'c' => {
                skipWs(ps);
                if (ps.p.len == 0 or ps.p[0] != '(') return parseError(ps, "expected '(' after 'c'");
                ps.p = ps.p[1..];
                var sub = std.ArrayListUnmanaged(Instr).empty;
                _ = try parseBody(ps, &sub);
                if (ps.p.len == 0 or ps.p[0] != ')') return parseError(ps, "expected ')' after cur body");
                ps.p = ps.p[1..];
                instr.closure = sub.toOwnedSlice(alloc) catch unreachable;
            },
            else => return parseError(ps, "unknown opcode"),
        }
        list.append(alloc, instr) catch unreachable;
    }
    return @intCast(list.items.len);
}

/// Mirrors C parse_csexp_list (zincdec.c:341-349).
fn parseCsexpList(ps: *ParseState, list: *std.ArrayListUnmanaged(Instr)) ParseFailed!i64 {
    skipWs(ps);
    if (ps.p.len == 0 or ps.p[0] != '(') return parseError(ps, "expected '(' for list");
    ps.p = ps.p[1..];
    const len = try parseBody(ps, list);
    if (ps.p.len == 0 or ps.p[0] != ')') return parseError(ps, "expected ')' after list body");
    ps.p = ps.p[1..];
    return len;
}

/// Mirrors C resolve_jumps (zincdec.c:351-364).
fn resolveJumps(code: []Instr) void {
    for (code) |*in| {
        switch (in.op) {
            .jmp, .jmpf, .access => {
                if (in.operand != null and in.operand.? == .number)
                    in.jmp_target = in.operand.?.number
                else
                    in.jmp_target = 0;
            },
            .cur => resolveJumps(in.closure.?),
            else => {},
        }
    }
}

// ---------------------------------------------------------------------
//  init_globals (mirrors zincdec.c:382-399)
// ---------------------------------------------------------------------

fn initGlobals() void {
    const prims = [_][]const u8{
        "+", "-", "*", "/", "=", "<", ">", "<=", ">=",
        "cons", "hd", "tl", "cn", "emptylist",
        "symbol?", "boolean?", "number?", "string?", "cons?",
        "error?", "function?", "stream?",
        "simple-error", "trap-error", "error-to-string",
        "eval-kl", "absvector", "<-address", "address->",
        "n->string", "string->n", "str", "tlstr", "hdstr", "pos",
        "intern", "value", "open", "close", "read-byte", "write-byte",
        "set", "get-time", "read-file-as-string",
        "@p", "fst", "snd", "gensym", "variable?", "newvar",
        "shen.fail!", "fail",
        "stinput", "stoutput",
    };
    for (prims) |p| globalSet(p, valPrim(p));
}

// ---------------------------------------------------------------------
//  parse_bundle (mirrors zincdec.c:401-476)
// ---------------------------------------------------------------------

fn parseBundleInner(ps: *ParseState) ParseFailed!i64 {
    skipWs(ps);
    if (ps.p.len == 0 or ps.p[0] != '(') {
        errPrint("bundle error: expected outer '('\n", .{});
        return 0;
    }
    ps.p = ps.p[1..]; // skip '('

    var count: i64 = 0;
    while (true) {
        skipWs(ps);
        if (ps.p.len == 0 or ps.p[0] == ')') {
            if (ps.p.len > 0) ps.p = ps.p[1..]; // end of bundle
            break;
        }
        if (ps.p[0] != '(') {
            errPrint("bundle error: expected '(' for entry\n", .{});
            return count;
        }
        ps.p = ps.p[1..]; // skip '('

        const name_val = try parseCsexpAtom(ps);
        if (name_val != .symbol) {
            errPrint("bundle error: name must be a symbol\n", .{});
            return count;
        }
        const name = name_val.symbol;

        var code = std.ArrayListUnmanaged(Instr).empty;
        _ = try parseCsexpList(ps, &code);
        if (code.items.len == 0) {
            errPrint("bundle error: failed to parse code for '{s}'\n", .{name});
            return count;
        }

        if (code.items.len < 1 or code.items[0].op != .cur or code.items[0].closure == null) {
            errPrint("bundle error: expected cur wrapper for '{s}'\n", .{name});
            return count;
        }
        const body = code.items[0].closure.?;
        resolveJumps(body);
        const closure = valLambda(body, &.{});
        globalSet(name, closure);

        skipWs(ps);
        if (ps.p.len == 0 or ps.p[0] != ')') {
            errPrint("bundle error: expected ')' to close entry '{s}'\n", .{name});
            return count;
        }
        ps.p = ps.p[1..];

        count += 1;
    }
    return count;
}

fn parseBundle(str: []const u8) i64 {
    var ps = ParseState{ .p = str, .start = str };
    return parseBundleInner(&ps) catch {
        errPrint("{s}\n", .{parse_err_msg});
        return 0;
    };
}

// ---------------------------------------------------------------------
//  Value -> Shen emitter (mirrors zincdec.c emit_shen_value :484-493)
// ---------------------------------------------------------------------

fn emitShenValue(v: Value) void {
    switch (v) {
        .number => |n| outPrint("{d}", .{n}),
        .string => |s| outPrint("\"{s}\"", .{s}),
        .symbol => |s| outPrint("{s}", .{s}),
        .boolean => |b| out(if (b) "true" else "false"),
        .nil => out("[]"),
        else => out("???"),
    }
}

// ---------------------------------------------------------------------
//  Decompile: raw format (mirrors zincdec.c decompile_raw :499-531)
// ---------------------------------------------------------------------

fn decompileRaw(code: []Instr, indent: usize) void {
    for (code) |*in| {
        var j: usize = 0;
        while (j < indent) : (j += 1) out("  ");
        switch (in.op) {
            .pushmark => out("pushmark\n"),
            .apply => out("apply\n"),
            .grab => out("grab\n"),
            .ret => out("return\n"),
            .let => out("let\n"),
            .endlet => out("endlet\n"),
            .appterm => out("appterm\n"),
            .access => {
                out("access ");
                printValue(in.operand.?);
                out("\n");
            },
            .global => {
                out("global ");
                printValue(in.operand.?);
                out("\n");
            },
            .jmpf => {
                out("jmpf ");
                printValue(in.operand.?);
                outPrint(" (tgt={d})\n", .{in.jmp_target});
            },
            .jmp => {
                out("jmp ");
                printValue(in.operand.?);
                outPrint(" (tgt={d})\n", .{in.jmp_target});
            },
            .number => {
                out("number ");
                printValue(in.operand.?);
                out("\n");
            },
            .string => {
                out("string ");
                printValue(in.operand.?);
                out("\n");
            },
            .symbol => {
                out("symbol ");
                printValue(in.operand.?);
                out("\n");
            },
            .boolean => {
                out("boolean ");
                printValue(in.operand.?);
                out("\n");
            },
            .prim => {
                out("prim ");
                printValue(in.operand.?);
                out("\n");
            },
            .cur => {
                outPrint("cur (code={d}):\n", .{in.closure.?.len});
                decompileRaw(in.closure.?, indent + 1);
                var k: usize = 0;
                while (k < indent) : (k += 1) out("  ");
                out("endcur\n");
            },
            else => outPrint("??? (op={d})\n", .{@intFromEnum(in.op)}),
        }
    }
}

// ---------------------------------------------------------------------
//  Decompile: asm format (mirrors zincdec.c decompile_asm :537-579)
// ---------------------------------------------------------------------

fn decompileAsm(code: []Instr, base_addr: i64, indent: usize) void {
    var addr: i64 = base_addr;
    for (code) |*in| {
        var j: usize = 0;
        while (j < indent) : (j += 1) out("  ");

        var tgt_addr: i64 = -1;
        if (in.op == .jmp or in.op == .jmpf) tgt_addr = base_addr + in.jmp_target;

        // Zig 0.16: hex-formatting a signed i64 injects a '+' sign; C's %04x
        // zero-pads unsigned. addr is always >= 0 here, so cast to u64.
        outPrint("{x:0>4}: ", .{@as(u64, @intCast(addr))});
        switch (in.op) {
            .pushmark => out("pushmark\n"),
            .apply => out("apply\n"),
            .grab => out("grab\n"),
            .ret => out("return\n"),
            .let => out("let\n"),
            .endlet => out("endlet\n"),
            .appterm => out("appterm\n"),
            .access => {
                out("access ");
                printValue(in.operand.?);
                out("\n");
            },
            .global => {
                out("global ");
                printValue(in.operand.?);
                out("\n");
            },
            .jmpf => {
                out("jmpf ");
                printValue(in.operand.?);
                outPrint("  ; -> {x:0>4}\n", .{@as(u64, @intCast(tgt_addr))});
            },
            .jmp => {
                out("jmp ");
                printValue(in.operand.?);
                outPrint("   ; -> {x:0>4}\n", .{@as(u64, @intCast(tgt_addr))});
            },
            .number => {
                out("number ");
                printValue(in.operand.?);
                out("\n");
            },
            .string => {
                out("string ");
                printValue(in.operand.?);
                out("\n");
            },
            .symbol => {
                out("symbol ");
                printValue(in.operand.?);
                out("\n");
            },
            .boolean => {
                out("boolean ");
                printValue(in.operand.?);
                out("\n");
            },
            .prim => {
                out("prim ");
                printValue(in.operand.?);
                out("\n");
            },
            .cur => {
                outPrint("cur (code={d}):\n", .{in.closure.?.len});
                decompileAsm(in.closure.?, 0, indent + 1);
                var k: usize = 0;
                while (k < indent) : (k += 1) out("  ");
                out("      endcur\n");
            },
            else => outPrint("??? (op={d})\n", .{@intFromEnum(in.op)}),
        }
        addr += 1;
    }
}

// ---------------------------------------------------------------------
//  Decompile: shen format (mirrors zincdec.c :585-620)
// ---------------------------------------------------------------------

fn decompileShenInstr(in: *Instr, indent: usize) void {
    var j: usize = 0;
    while (j < indent) : (j += 1) out("  ");
    switch (in.op) {
        .pushmark => out("pushmark\n"),
        .apply => out("apply\n"),
        .grab => out("grab\n"),
        .ret => out("return\n"),
        .let => out("let\n"),
        .endlet => out("endlet\n"),
        .appterm => out("appterm\n"),
        .access => {
            out("[access ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .global => {
            out("[global ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .jmpf => {
            out("[jmpf ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .jmp => {
            out("[jmp ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .number => {
            out("[number ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .string => {
            out("[string ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .symbol => {
            out("[symbol ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .boolean => {
            out("[boolean ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .prim => {
            out("[prim ");
            emitShenValue(in.operand.?);
            out("]\n");
        },
        .cur => {
            out("[cur\n");
            for (in.closure.?) |*sub| decompileShenInstr(sub, indent + 1);
            var k: usize = 0;
            while (k < indent) : (k += 1) out("  ");
            out("]\n");
        },
        else => outPrint("[??? {d}]\n", .{@intFromEnum(in.op)}),
    }
}

fn decompileShen(code: []Instr) void {
    out("[\n");
    for (code) |*in| decompileShenInstr(in, 1);
    out("]\n");
}

// ---------------------------------------------------------------------
//  Decompile: csexp format (mirrors zincdec.c :626-668)
// ---------------------------------------------------------------------

fn emitCsexpOperand(v: Value) void {
    switch (v) {
        .number => |n| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            outPrint("[{d}:n]{s}", .{ s.len, s });
        },
        .string => |s| outPrint("[{d}:S]{s}", .{ s.len, s }),
        .symbol => |s| outPrint("[{d}:s]{s}", .{ s.len, s }),
        .boolean => |b| {
            const s: []const u8 = if (b) "true" else "false";
            outPrint("[{d}:b]{s}", .{ s.len, s });
        },
        else => out("[0:n]0"),
    }
}

fn decompileCsexpInstr(in: *Instr) void {
    switch (in.op) {
        .pushmark, .apply, .grab, .ret, .let, .endlet, .appterm =>
            out(&[_]u8{opcodeToChar(in.op)}),
        .access, .global, .jmpf, .jmp, .number, .string, .symbol, .boolean, .prim => {
            out(&[_]u8{opcodeToChar(in.op)});
            emitCsexpOperand(in.operand.?);
        },
        .cur => {
            out("c(");
            for (in.closure.?) |*sub| decompileCsexpInstr(sub);
            out(")");
        },
        else => out("?"),
    }
}

fn decompileCsexp(code: []Instr) void {
    out("(");
    for (code, 0..) |*in, i| {
        _ = i;
        decompileCsexpInstr(in);
    }
    out(")\n");
}

// ---------------------------------------------------------------------
//  Curried-call detector (mirrors zincdec.c :681-728)
// ---------------------------------------------------------------------

fn scanCurried(code: []Instr, name: []const u8, prev_was_apply: ?*bool, out_count: ?*i64) i64 {
    var local_prev = if (prev_was_apply != null) prev_was_apply.?.* else false;
    var found: i64 = 0;
    for (code, 0..) |*in, i| {
        switch (in.op) {
            .apply, .appterm => {
                if (local_prev) {
                    const prev_op: u8 = if (i > 0) opcodeToChar(code[i - 1].op) else '?';
                    errPrint("  {s}: curried call at instr {d} ({c} after {c})\n", .{ name, i, opcodeToChar(in.op), prev_op });
                    found += 1;
                }
                local_prev = true;
            },
            .cur => {
                found += scanCurried(in.closure.?, name, null, null);
                local_prev = false;
            },
            else => local_prev = false,
        }
    }
    if (out_count != null) out_count.?.* = found;
    return found;
}

fn scanAllCurried() i64 {
    var total: i64 = 0;
    var closures_with: i64 = 0;
    var scanned: i64 = 0;
    for (global_table[0..global_table_len]) |entry| {
        const v = entry.closure;
        if (v != .lambda) continue;
        scanned += 1;
        var cnt: i64 = 0;
        _ = scanCurried(v.lambda.code, entry.name, null, &cnt);
        if (cnt != 0) {
            total += cnt;
            closures_with += 1;
        }
    }
    errPrint("Scanned {d} closures: {d} curried call(s) in {d} closure(s)\n", .{ scanned, total, closures_with });
    return if (total != 0) 1 else 0;
}

// ---------------------------------------------------------------------
//  usage (mirrors zincdec.c :734-758)
// ---------------------------------------------------------------------

fn usage(prog: []const u8) void {
    errPrint(
        \\Usage: {s} <bundle> <function-name> [--raw|--asm|--shen|--csexp]
        \\       {s} <bundle> --curried
        \\
        \\Decompile a bundled closure's ZINC bytecode, or scan the whole bundle.
        \\
        \\Output formats:
        \\  --raw   (default) Human-readable opcode names with operands
        \\  --asm             Disassembly listing with hex addresses
        \\  --shen            Shen list syntax for interp.shen's interp
        \\  --csexp           Raw csexp wire format (feedable to parse_bytecode)
        \\
        \\Whole-bundle modes:
        \\  --curried         Flag any curried partial-application calls (the C VM
        \\                    cannot run them); exit 1 if any found
        \\
        \\Examples:
        \\  {s} globals.csexp +
        \\  {s} globals.csexp read-from-string --asm
        \\  {s} globals.csexp shen.repl --shen
        \\  {s} globals.csexp reverse --csexp
        \\  {s} globals.csexp --curried
        \\
    , .{ prog, prog, prog, prog, prog, prog, prog });
}

// ---------------------------------------------------------------------
//  main (mirrors zincdec.c :760-821)
// ---------------------------------------------------------------------

pub fn main(m: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    alloc = arena.allocator();

    initGlobals();

    // ---- argv (C main's argc/argv) ----
    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;
    var it = std.process.Args.Iterator.init(m.args);
    while (it.next()) |arg| {
        if (argc == argv_buf.len) break;
        argv_buf[argc] = arg;
        argc += 1;
    }
    const args = argv_buf[0..argc];

    if (args.len < 3) {
        usage(if (args.len > 0) args[0] else "zigdec");
        return 1;
    }

    const bundle_path = args[1];
    const func_name = args[2];
    var format: []const u8 = "--raw";

    if (args.len > 3) {
        format = args[3];
        if (!std.mem.eql(u8, format, "--raw") and
            !std.mem.eql(u8, format, "--asm") and
            !std.mem.eql(u8, format, "--shen") and
            !std.mem.eql(u8, format, "--csexp"))
        {
            errPrint("error: unknown format '{s}'\n", .{format});
            usage(args[0]);
            return 1;
        }
    }

    const buf = readFileOrStdin(bundle_path) orelse return 1;
    // skip leading whitespace
    var p = buf;
    while (p.len > 0 and std.ascii.isWhitespace(p[0])) p = p[1..];

    if (!(p.len > 1 and p[0] == '(' and p[1] == '(')) {
        errPrint("error: '{s}' not a bundle\n", .{bundle_path});
        return 1;
    }

    const n = parseBundle(p);
    if (n <= 0) {
        errPrint("error: parse failed\n", .{});
        return 1;
    }
    errPrint("Loaded {d} closures\n", .{n});

    // --curried: scan all closures for curried partial-application calls
    if (std.mem.eql(u8, func_name, "--curried")) {
        return if (scanAllCurried() != 0) 1 else 0;
    }

    // Pattern keywords as symbols
    {
        const kws = [_][]const u8{ "number", "string", "symbol", "cons", "nil", "boolean", "lambda", "function", "prim", "vector", "stream", "true", "false", "error", "absvector", "unit" };
        for (kws) |k| globalSet(k, valSymbol(k));
    }

    const g = globalGet(func_name);
    if (g == .lambda) {
        const fmt_shen = std.mem.eql(u8, format, "--shen");
        const fmt_asm = std.mem.eql(u8, format, "--asm");
        const fmt_csexp = std.mem.eql(u8, format, "--csexp");
        if (!fmt_shen and !fmt_csexp) {
            outPrint("=== {s} ===\n  code_len={d}  env_len={d}\n\n", .{ func_name, g.lambda.code.len, g.lambda.env.len });
        }
        if (fmt_asm) decompileAsm(g.lambda.code, 0, 0)
        else if (fmt_shen) decompileShen(g.lambda.code)
        else if (fmt_csexp) decompileCsexp(g.lambda.code)
        else decompileRaw(g.lambda.code, 0);
    } else if (g == .prim) {
        outPrint("{s} is a C primitive\n", .{func_name});
    } else {
        errPrint("{s}: not found (tag={d})\n", .{ func_name, @intFromEnum(std.meta.activeTag(g)) });
        return 1;
    }
    flushOut();
    return 0;
}

/// Mirrors C read_file_or_stdin (zincdec.c:366-380) for the file path case
/// (the CLI always passes a path).  Zig 0.16 has no std.fs; raw POSIX.
fn readFileOrStdin(path: []const u8) ?[]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch {
        errPrint("error: cannot open '{s}'\n", .{path});
        return null;
    };
    defer _ = std.posix.system.close(fd);
    var buf = std.ArrayListUnmanaged(u8).empty;
    var tmp: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &tmp) catch break; // read error == C's fgetc EOF
        if (n == 0) break;
        buf.appendSlice(alloc, tmp[0..n]) catch return null;
    }
    return buf.toOwnedSlice(alloc) catch null;
}

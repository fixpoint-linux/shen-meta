//! tests/vm_test.zig — M0 (value model) + M1 (symbol interner) for the ZINC VM.
//!
//! M0 covers the ported value constructors, deep_equal, print_value / str_value,
//! val_string_from, the Vm skeleton rooting, and a forced-scavenge cons-chain
//! survival test (uses only the GC API).  M1 covers the symbol interner
//! (identity, distinctness, resize survival, val_symbol).

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const heap = gc.heap;
const vm = @import("vm");
const values = vm.values;
const symbols = vm.symbols;
const state = vm.state;
const tables = vm.tables;
const parser = vm.parser;
const prims = vm.prims;
const execplan = vm.execplan;

// ---- raw libc for the M3 process tests ----
// Zig 0.16 dropped std.Thread.sleep / std.process.getCwdAlloc / std.posix
// chdir wrappers; the test binary links libc (via the vm module's
// link_libc), so declare the three syscalls we need directly.
const Timespec = extern struct { sec: isize, nsec: isize };
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
const T_O_WRONLY: c_int = 1;
const T_O_CREAT: c_int = 64;
const T_O_TRUNC: c_int = 512;

/// Create the glob fixture dir + files (idempotent: O_TRUNC rewrites).
fn globFixture() void {
    _ = mkdir("/tmp/zig-m3-glob", 0o777); // EEXIST is fine
    inline for (.{ ".dot.txt", "a.txt", "b.txt", "other.log" }) |fname| {
        const full = "/tmp/zig-m3-glob/" ++ fname;
        const fd = open(full.ptr, T_O_WRONLY | T_O_CREAT | T_O_TRUNC, @as(c_uint, 0o666));
        if (fd >= 0) {
            _ = write(fd, "x", 1);
            _ = close(fd);
        }
    }
}

fn cwdAlloc() ![:0]u8 {
    const buf = try std.heap.page_allocator.alloc(u8, 4096);
    const p = getcwd(buf.ptr, buf.len) orelse return error.GetcwdFailed;
    const l = std.mem.sliceTo(p, 0).len;
    return buf[0..l :0];
}

fn chdirZ(path: [:0]const u8) void {
    _ = chdir(path.ptr);
}

fn sleepSec(sec: isize) void {
    const ts = Timespec{ .sec = sec, .nsec = 0 };
    _ = nanosleep(&ts, null);
}

fn sleepMs(ms: u64) void {
    const ts = Timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = nanosleep(&ts, null);
}

/// 16 MB heap (the C minimum) with a 64 MB reservation (avoids the 4 GB
/// default VAS), mirroring tests/gc_test.zig's testInit.
fn testInit() !heap.Gc {
    return heap.Gc.init(.{
        .heap_bytes = 16 * 1024 * 1024,
        .reserve_bytes = 64 * 1024 * 1024,
    });
}

/// Build a cons list [n0 n1 ... nk] of numbers (nil-terminated).
fn consNums(g: *heap.Gc, nums: []const i64) types.Value {
    var head = values.valNil();
    var i = nums.len;
    while (i > 0) {
        i -= 1;
        head = values.valCons(g, values.valNumber(nums[i]), head);
    }
    return head;
}

/// str_value / print_value a Value into a fixed module-level buffer and return
/// the written slice.  A single shared buffer is safe here because the tests
/// are sequential and each result is consumed immediately (within the same
/// expression or enclosing scope) before the next call overwrites it.
var fmtBuf: [16384]u8 = undefined;

fn strValueOf(v: types.Value) []const u8 {
    var w: std.Io.Writer = .fixed(&fmtBuf);
    values.strValue(&w, v, 0) catch unreachable;
    return w.buffered();
}

fn printValueOf(v: types.Value) []const u8 {
    var w: std.Io.Writer = .fixed(&fmtBuf);
    values.printValue(&w, v) catch unreachable;
    return w.buffered();
}

// =====================================================================
//  M0 — value round-trips
// =====================================================================

test "M0 scalar value round-trips" {
    var g = try testInit();
    defer g.deinit();

    const n = values.valNumber(42);
    try std.testing.expectEqual(types.ValTag.number, n.tag);
    try std.testing.expectEqual(@as(i64, 42), n.payload.number);

    const t = values.valBoolean(true);
    const f = values.valBoolean(false);
    try std.testing.expectEqual(types.ValTag.boolean, t.tag);
    try std.testing.expectEqual(@as(i32, 1), t.payload.boolean);
    try std.testing.expectEqual(@as(i32, 0), f.payload.boolean);

    try std.testing.expectEqual(types.ValTag.nil, values.valNil().tag);
    try std.testing.expectEqual(types.ValTag.mark, values.valMark().tag);

    const p = values.valPrim("reverse");
    try std.testing.expectEqual(types.ValTag.prim, p.tag);
    try std.testing.expect(std.mem.eql(u8, "reverse", values.primSlice(p)));

    const s = values.valString(&g, "hello");
    try std.testing.expectEqual(types.ValTag.string, s.tag);
    try std.testing.expectEqual(@as(i32, 5), s.payload.str.len);
    try std.testing.expect(std.mem.eql(u8, "hello", values.strSlice(s)));
}

test "M0 valStringFrom slices a rooted string, survives a scavenge" {
    var g = try testInit();
    defer g.deinit();

    var s = values.valString(&g, "hello world");
    var guard = g.rootValue(&s);
    defer guard.end();

    // Promote s to old-gen, then read through the still-rooted slot.
    g.collectNursery(.@"test");

    const sub = values.valStringFrom(&g, &s, 6, 5);
    try std.testing.expectEqual(types.ValTag.string, sub.tag);
    try std.testing.expectEqual(@as(i32, 5), sub.payload.str.len);
    try std.testing.expect(std.mem.eql(u8, "world", values.strSlice(sub)));
}

test "M0 cons list round-trip + deep equality" {
    var g = try testInit();
    defer g.deinit();

    const a = consNums(&g, &.{ 1, 2, 3 });
    const b = consNums(&g, &.{ 1, 2, 3 });
    const c = consNums(&g, &.{ 1, 2, 4 });

    try std.testing.expect(values.deepEqual(a, b, 0));
    try std.testing.expect(!values.deepEqual(a, c, 0));

    // Cons head cells are distinct objects even for equal lists.
    try std.testing.expect(a.payload.cons.car.? != b.payload.cons.car.?);
}

test "M0 deep_equal over vectors / strings / symbols / booleans" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    // Vectors.
    var va = values.valVector(&g, 3);
    va.payload.vector.data.?[0] = values.valNumber(1);
    va.payload.vector.data.?[1] = values.valNumber(2);
    va.payload.vector.data.?[2] = values.valNumber(3);
    var vb = values.valVector(&g, 3);
    vb.payload.vector.data.?[0] = values.valNumber(1);
    vb.payload.vector.data.?[1] = values.valNumber(2);
    vb.payload.vector.data.?[2] = values.valNumber(3);
    var vc = values.valVector(&g, 3);
    vc.payload.vector.data.?[0] = values.valNumber(1);
    vc.payload.vector.data.?[1] = values.valNumber(2);
    vc.payload.vector.data.?[2] = values.valNumber(9);
    try std.testing.expect(values.deepEqual(va, vb, 0));
    try std.testing.expect(!values.deepEqual(va, vc, 0));

    // Strings.
    try std.testing.expect(values.deepEqual(
        values.valString(&g, "same"),
        values.valString(&g, "same"),
        0,
    ));
    try std.testing.expect(!values.deepEqual(
        values.valString(&g, "same"),
        values.valString(&g, "diff"),
        0,
    ));

    // Symbols (interner-backed canonical names).
    const sy_a = symbols.valSymbol(&sym, "alpha");
    const sy_b = symbols.valSymbol(&sym, "alpha");
    const sy_c = symbols.valSymbol(&sym, "beta");
    try std.testing.expect(values.deepEqual(sy_a, sy_b, 0));
    try std.testing.expect(!values.deepEqual(sy_a, sy_c, 0));

    // Booleans.
    try std.testing.expect(values.deepEqual(values.valBoolean(true), values.valBoolean(true), 0));
    try std.testing.expect(!values.deepEqual(values.valBoolean(true), values.valBoolean(false), 0));
    try std.testing.expect(values.deepEqual(values.valNil(), values.valNil(), 0));

    // Mixed tags never compare equal.
    try std.testing.expect(!values.deepEqual(values.valNumber(1), values.valString(&g, "1"), 0));
}

test "M0 valLambda copies env and sets code after the env alloc" {
    var g = try testInit();
    defer g.deinit();

    // A small GC-allocated env array to copy.
    var env = g.allocArray(types.Value, 2);
    env[0] = values.valNumber(7);
    env[1] = values.valNumber(8);

    const lam = values.valLambda(&g, null, 0, env, 2);
    try std.testing.expectEqual(types.ValTag.lambda, lam.tag);
    try std.testing.expectEqual(@as(i32, 2), lam.payload.lambda.env_len);
    try std.testing.expect(lam.payload.lambda.env != null);
    try std.testing.expect(values.deepEqual(values.valNumber(7), lam.payload.lambda.env.?[0], 0));
    try std.testing.expect(values.deepEqual(values.valNumber(8), lam.payload.lambda.env.?[1], 0));

    // env_len == 0 -> null env, code still set.
    const lam0 = values.valLambda(&g, null, 0, null, 0);
    try std.testing.expect(lam0.payload.lambda.env == null);
    try std.testing.expectEqual(@as(i32, 0), lam0.payload.lambda.env_len);
}

test "M0 valError / valVector / valStream constructors" {
    var g = try testInit();
    defer g.deinit();

    const e = values.valError(&g, "boom");
    try std.testing.expectEqual(types.ValTag.error_, e.tag);
    try std.testing.expect(std.mem.eql(u8, "boom", values.errSlice(e)));

    const v = values.valVector(&g, 4);
    try std.testing.expectEqual(types.ValTag.vector, v.tag);
    try std.testing.expectEqual(@as(i32, 4), v.payload.vector.len);
    try std.testing.expect(v.payload.vector.data != null);
    try std.testing.expect(values.valVector(&g, 0).payload.vector.data == null);

    const si = values.valStreamIn(null);
    try std.testing.expectEqual(types.ValTag.stream, si.tag);
    try std.testing.expectEqual(@as(i32, 1), si.payload.stream.is_input);
    const so = values.valStreamOut(null);
    try std.testing.expectEqual(@as(i32, 0), so.payload.stream.is_input);
}

// =====================================================================
//  M0 — printing
// =====================================================================

test "M0 print_value golden strings" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    try std.testing.expectEqualStrings("42", printValueOf(values.valNumber(42)));
    try std.testing.expectEqualStrings("true", printValueOf(values.valBoolean(true)));
    try std.testing.expectEqualStrings("false", printValueOf(values.valBoolean(false)));
    try std.testing.expectEqualStrings("\"hi\"", printValueOf(values.valString(&g, "hi")));
    try std.testing.expectEqualStrings("abc", printValueOf(symbols.valSymbol(&sym, "abc")));
    try std.testing.expectEqualStrings("[]", printValueOf(values.valNil()));
    try std.testing.expectEqualStrings("mark", printValueOf(values.valMark()));
    try std.testing.expectEqualStrings("[prim reverse]", printValueOf(values.valPrim("reverse")));
    try std.testing.expectEqualStrings("[error \"boom\"]", printValueOf(values.valError(&g, "boom")));
    try std.testing.expectEqualStrings("[vector 3]", printValueOf(values.valVector(&g, 3)));
    try std.testing.expectEqualStrings("[stream in]", printValueOf(values.valStreamIn(null)));
    try std.testing.expectEqualStrings(
        "[cons 1 . [cons 2 . []]]",
        printValueOf(consNums(&g, &.{ 1, 2 })),
    );
}

test "M0 str_value list form and opaque forms" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    try std.testing.expectEqualStrings("42", strValueOf(values.valNumber(42)));
    try std.testing.expectEqualStrings("[1 2 3]", strValueOf(consNums(&g, &.{ 1, 2, 3 })));
    try std.testing.expectEqualStrings("[]", strValueOf(values.valNil()));
    try std.testing.expectEqualStrings("\"x\"", strValueOf(values.valString(&g, "x")));
    try std.testing.expectEqualStrings("<vector 3>", strValueOf(values.valVector(&g, 3)));
    try std.testing.expectEqualStrings("<prim reverse>", strValueOf(values.valPrim("reverse")));
    try std.testing.expectEqualStrings("<lambda>", strValueOf(values.valLambda(&g, null, 0, null, 0)));
    try std.testing.expectEqualStrings("<stream>", strValueOf(values.valStreamIn(null)));
    try std.testing.expectEqualStrings("<error boom>", strValueOf(values.valError(&g, "boom")));
    try std.testing.expectEqualStrings("sym1", strValueOf(symbols.valSymbol(&sym, "sym1")));

    // A dotted tail renders with " . ".
    const dotted = values.valCons(&g, values.valNumber(1), values.valNumber(2));
    try std.testing.expectEqualStrings("[1 . 2]", strValueOf(dotted));
}

test "M0 str_value of a long list exceeds 4096 chars (Test 14c shape)" {
    var g = try testInit();
    defer g.deinit();

    // 2000 cons cells -> >4096 chars of "[1 2 3 ... 2000]".
    var nums: [2000]i64 = undefined;
    var i: usize = 0;
    while (i < nums.len) : (i += 1) nums[i] = @intCast(i + 1);
    const list = consNums(&g, &nums);
    const s = strValueOf(list);
    try std.testing.expect(s.len > 4096);
    // Bracket-balanced and correctly framed.
    try std.testing.expectEqual(@as(u8, '['), s[0]);
    try std.testing.expectEqual(@as(u8, ']'), s[s.len - 1]);
}

// =====================================================================
//  M0 — forced-scavenge survival (uses only the GC API)
// =====================================================================

test "M0 cons chain survives a forced nursery scavenge" {
    var g = try testInit();
    defer g.deinit();

    var head = consNums(&g, &.{ 1, 2, 3 });
    const wm0 = g.rootWatermark();
    g.rootPushValue(&head); // root head across the scavenge

    const head_old = @intFromPtr(head.payload.cons.car.?);
    try std.testing.expect(g.inNursery(head_old));

    g.collectNursery(.@"test");

    // Interior pointers rewritten; contents intact.
    try std.testing.expect(!g.inNursery(@intFromPtr(head.payload.cons.car.?)));

    const expected = consNums(&g, &.{ 1, 2, 3 });
    const equal = values.deepEqual(head, expected, 0);

    g.rootPop(); // unroot head
    try std.testing.expect(equal);

    // Root stack balanced across the whole block.
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

// =====================================================================
//  M0 — Vm skeleton
// =====================================================================

test "M0 Vm skeleton roots err_slot once" {
    var g = try testInit();
    defer g.deinit();

    const wm = g.rootWatermark();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    try std.testing.expectEqual(wm + 1, g.rootWatermark());
    try std.testing.expectEqual(@as(*heap.Gc, &g), v.gc);
    try std.testing.expectEqual(types.ValTag.nil, v.err_slot.tag);
}

// =====================================================================
//  M1 — symbol interner
// =====================================================================

test "M1 intern identity and distinctness" {
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    const a1 = sym.intern("alpha");
    const a2 = sym.intern("alpha");
    const b = sym.intern("beta");

    try std.testing.expect(a1 == a2); // canonical pointer identity
    try std.testing.expect(a1 != b);
    try std.testing.expect(std.mem.eql(u8, "alpha", std.mem.sliceTo(a1, 0)));
}

test "M1 interning past 70% load grows and keeps old pointers canonical" {
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    var names: [180][24]u8 = undefined;
    var ptrs: [180][*:0]const u8 = undefined;
    var i: usize = 0;
    while (i < 180) : (i += 1) {
        const used = std.fmt.bufPrint(&names[i], "sym{d}", .{i}) catch unreachable;
        // bufPrint does not NUL-terminate; write one so the re-intern below can
        // hand back the whole `names[i]` buffer as a C-style name (mirrors C's
        // const char* contract and the sliceTo normalization in intern).
        names[i][used.len] = 0;
        ptrs[i] = sym.intern(used);
    }
    try std.testing.expectEqual(@as(usize, 180), sym.count);
    try std.testing.expectEqual(@as(usize, 256), sym.cap);

    // Intern well past the 70% threshold to force at least one x2 grow.
    var j: usize = 180;
    while (j < 400) : (j += 1) {
        var buf: [24]u8 = undefined;
        const nm = std.fmt.bufPrint(&buf, "sym{d}", .{j}) catch unreachable;
        _ = sym.intern(nm);
    }
    try std.testing.expect(sym.cap >= 512);
    try std.testing.expectEqual(@as(usize, 400), sym.count);

    // Every pre-resize pointer is still the canonical answer after the rehash.
    i = 0;
    while (i < 180) : (i += 1) {
        const again = sym.intern(&names[i]);
        try std.testing.expect(again == ptrs[i]);
    }
}

test "M1 valSymbol tag and name" {
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    const v1 = symbols.valSymbol(&sym, "hello");
    const v2 = symbols.valSymbol(&sym, "hello");
    try std.testing.expectEqual(types.ValTag.symbol, v1.tag);
    try std.testing.expectEqual(types.ValTag.symbol, v2.tag);
    try std.testing.expect(std.mem.eql(u8, "hello", values.symSlice(v1)));

    // Canonical pointer equality: same name -> same interned name pointer.
    try std.testing.expect(v1.payload.sym.name == v2.payload.sym.name);
    try std.testing.expect(values.deepEqual(v1, v2, 0));
}

// =====================================================================
//  M2 — defun/values tables + GC registration
// =====================================================================

test "M2 defun set/get/overwrite/has" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    v.defunSet("f", values.valNumber(1));
    try std.testing.expectEqual(@as(i64, 1), v.defunGet("f").payload.number);
    try std.testing.expect(v.defunHas("f"));

    // Later store wins on overwrite (C: "later store wins").
    v.defunSet("f", values.valNumber(2));
    try std.testing.expectEqual(@as(i64, 2), v.defunGet("f").payload.number);

    try std.testing.expect(!v.defunHas("nope"));
    try std.testing.expect(!v.defunHas("absent"));
}

test "M2 values set/get/overwrite" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    v.valueSet("x", values.valNumber(10));
    try std.testing.expectEqual(@as(i64, 10), v.valueGet("x").payload.number);
    v.valueSet("x", values.valNumber(99)); // overwrite
    try std.testing.expectEqual(@as(i64, 99), v.valueGet("x").payload.number);

    // Different keys don't collide into each other's values.
    v.valueSet("y", values.valNumber(20));
    try std.testing.expectEqual(@as(i64, 99), v.valueGet("x").payload.number);
    try std.testing.expectEqual(@as(i64, 20), v.valueGet("y").payload.number);
}

test "M2 defun/value fallback: unknown names stay symbols" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // Unknown defun name -> valSymbol (macros/*stinput* must stay symbols).
    const gv = v.defunGet("*macros*");
    try std.testing.expectEqual(types.ValTag.symbol, gv.tag);
    try std.testing.expect(std.mem.eql(u8, "*macros*", values.symSlice(gv)));

    // value_get fallback is always val_symbol, no prim fallback (C:667).
    const vg = v.valueGet("+");
    try std.testing.expectEqual(types.ValTag.symbol, vg.tag);
    try std.testing.expectEqual(types.ValTag.symbol, v.valueGet("missing").tag);

    // initGlobals registers the stub prim list as VAL_PRIM globals.
    const plus = v.defunGet("+");
    try std.testing.expectEqual(types.ValTag.prim, plus.tag);
    try std.testing.expect(std.mem.eql(u8, "+", values.primSlice(plus)));
}

test "M2 defunSet marks the slot dirty (nursery value)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    const slot = tables.hashName("dirtytest", tables.DEFUN_TABLE_CAP);
    try std.testing.expect(!g.dirtyDefunsTest(@intCast(slot)));

    const nv = values.valCons(&g, values.valNumber(5), values.valNil());
    v.defunSet("dirtytest", nv);
    try std.testing.expect(g.dirtyDefunsTest(@intCast(slot)));

    // Overwrite also re-marks dirty (may now reference a nursery value).
    v.defunSet("dirtytest", values.valNumber(9));
    try std.testing.expect(g.dirtyDefunsTest(@intCast(slot)));
}

test "M2 defun table cons list survives scavenge + full collect (interior rewrite)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    const list = consNums(&g, &.{ 1, 2, 3 });
    // ALSO hold it via a root so root and table can be compared independently.
    var root_list = list;
    g.rootPushValue(&root_list);
    defer g.rootPop();

    v.defunSet("mylist", list);

    try std.testing.expect(values.deepEqual(v.defunGet("mylist"), root_list, 0));

    g.collectNursery(.@"test");
    g.collect(.@"test"); // full collect

    // Table value and root agree, with interior pointers rewritten in place.
    const got = v.defunGet("mylist");
    try std.testing.expect(values.deepEqual(got, root_list, 0));
    try std.testing.expectEqual(@as(i64, 1), got.payload.cons.car.?.payload.number);
    try std.testing.expectEqual(@as(i64, 2), got.payload.cons.cdr.?.payload.cons.car.?.payload.number);
}

test "M2 values table survives a full collect" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    v.valueSet("num", values.valNumber(42));
    v.valueSet("lst", consNums(&g, &.{ 7, 8 }));

    g.collect(.@"test"); // values table is always full-scanned

    try std.testing.expectEqual(@as(i64, 42), v.valueGet("num").payload.number);
    const lst = v.valueGet("lst");
    try std.testing.expect(values.deepEqual(consNums(&g, &.{ 7, 8 }), lst, 0));
    try std.testing.expectEqual(@as(i64, 7), lst.payload.cons.car.?.payload.number);
}

// =====================================================================
//  M3 — csexp parser + resolve_jumps + print_instr
// =====================================================================

/// print_instr a code array into the shared fixed buffer (testable without
/// stdout; single buffer safe because tests are sequential).
fn printInstrOf(code: [*]types.Instr, len: i32) []const u8 {
    var w: std.Io.Writer = .fixed(&fmtBuf);
    parser.printInstr(&w, code, len, 0) catch unreachable;
    return w.buffered();
}

test "M3 parse test-2 [lambda X X] structure" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(c(a[1:n]0v))", &code);
    try std.testing.expectEqual(@as(i32, 1), len);
    try std.testing.expectEqual(types.Opcode.cur, code.?[0].op);
    try std.testing.expectEqual(@as(i32, 2), code.?[0].closure_len);
    const child: [*]types.Instr = @ptrCast(code.?[0].closure_code.?);
    try std.testing.expectEqual(types.Opcode.access, child[0].op);
    try std.testing.expectEqual(@as(i64, 0), child[0].operand.payload.number);
    try std.testing.expectEqual(types.Opcode.ret, child[1].op);
}

test "M3 parse+print round-trip of zinctest built-in literals" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    // Test 1: [+ 1 2]
    var code1: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(mn[1:n]2n[1:n]1g[1:s]+p)", &code1);
    try std.testing.expectEqualStrings("pushmark\nnumber 2\nnumber 1\nglobal +\napply\n", printInstrOf(code1.?, 5));

    // Test 2: [lambda X X]
    var code2: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(c(a[1:n]0v))", &code2);
    try std.testing.expectEqualStrings("cur (code=2):\n  access 0\n  return\nendcur\n", printInstrOf(code2.?, 1));

    // Test 15: [string? "hi"]
    var code3: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(mS[2:S]hig[7:s]string?p)", &code3);
    try std.testing.expectEqualStrings("pushmark\nstring \"hi\"\nglobal string?\napply\n", printInstrOf(code3.?, 4));
}

test "M3 nested cur parse (test 36 appterm-in-apply)" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    // (mn[2:n]42c(ma[1:n]0c(a[1:n]0v)t)p)
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(mn[2:n]42c(ma[1:n]0c(a[1:n]0v)t)p)", &code);
    try std.testing.expectEqual(@as(i32, 4), len);

    const inner = code.?[2]; // the cur instr
    try std.testing.expectEqual(types.Opcode.cur, inner.op);
    try std.testing.expectEqual(@as(i32, 4), inner.closure_len);
    // inner body: m (pushmark), a 0 (access), c (...) cur, t (appterm)
    const inner_code: [*]types.Instr = @ptrCast(inner.closure_code.?);
    try std.testing.expectEqual(types.Opcode.pushmark, inner_code[0].op);
    try std.testing.expectEqual(types.Opcode.access, inner_code[1].op);
    try std.testing.expectEqual(types.Opcode.cur, inner_code[2].op);
    try std.testing.expectEqual(types.Opcode.appterm, inner_code[3].op);
    // innermost cur body: a 0, v
    const innermost: [*]types.Instr = @ptrCast(inner_code[2].closure_code.?);
    try std.testing.expectEqual(@as(i32, 2), inner_code[2].closure_len);
    try std.testing.expectEqual(types.Opcode.access, innermost[0].op);
    try std.testing.expectEqual(types.Opcode.ret, innermost[1].op);
}

test "M3 resolve_jumps fills jmp_target from numeric operands" {
    var g = try testInit();
    defer g.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    // f[1:n]0j[1:n]2a[1:n]1  → jmpf 0, jmp 2, access 1
    var code: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(f[1:n]0j[1:n]2a[1:n]1)", &code);
    parser.resolveJumps(code.?, 3);
    try std.testing.expectEqual(@as(i32, 0), code.?[0].jmp_target);
    try std.testing.expectEqual(@as(i32, 2), code.?[1].jmp_target);
    try std.testing.expectEqual(@as(i32, 1), code.?[2].jmp_target);

    // Non-numeric operand -> jmp_target 0.
    var code2: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(f[2:s]xx)", &code2);
    parser.resolveJumps(code2.?, 1);
    try std.testing.expectEqual(@as(i32, 0), code2.?[0].jmp_target);
}

test "M3 successful parse leaves shadow stack balanced" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    const wm0 = g.rootWatermark();
    var code: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(c(a[1:n]0c(a[1:n]0v)t)v)", &code);
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M3 error cases return ParseError and leave shadow stack balanced" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    const bad = [_][:0]const u8{
        "(x)", // unknown opcode
        "(n[1:n]1", // missing closing bracket
        "((n[1:n]1))", // unexpected nested list in body
        "(n[abc])", // bad atom (no digits / bad format)
        "nope", // not a list
    };
    for (bad) |src| {
        const wm0 = g.rootWatermark();
        var code: ?[*]types.Instr = null;
        try std.testing.expectError(error.ParseError, parser.parseBytecode(&g, &sym, src, &code));
        try std.testing.expect(code == null);
        // Shadow stack restored to entry watermark (C root_pop_to parity).
        try std.testing.expectEqual(wm0, g.rootWatermark());
    }
}

test "M3 parsed closure survives scavenge + full collect (children reachable)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    var code: ?[*]types.Instr = null;
    _ = try parser.parseBytecode(&g, &sym, "(c(a[1:n]0c(a[1:n]0v)t)v)", &code);
    // Root the outer code array so the closure children stay reachable.
    g.rootPushPtr(@ptrCast(&code));
    defer g.rootPop();

    g.collectNursery(.@"test");
    g.collect(.@"test");

    // Interior pointers rewritten; both levels still valid and callable.
    try std.testing.expectEqual(types.Opcode.cur, code.?[0].op);
    const inner: [*]types.Instr = @ptrCast(code.?[0].closure_code.?);
    try std.testing.expectEqual(types.Opcode.cur, inner[1].op);
    const innermost: [*]types.Instr = @ptrCast(inner[1].closure_code.?);
    try std.testing.expectEqual(types.Opcode.access, innermost[0].op);
    try std.testing.expectEqual(types.Opcode.ret, innermost[1].op);
}

// =====================================================================
//  M4 — the eval loop (interp.vmExecEnv / vmExec)
// =====================================================================

const interp = vm.interp;

/// Parse `src` with a fresh interner, resolve jumps, root the code for the
/// duration of the run (the C host's vm_root_code discipline), vmExec it,
/// and check the numeric result plus shadow-stack balance.  vmExecEnv pops
/// to its entry watermark on EVERY exit path (break, error.ShenError), so
/// the watermark must come back unchanged after parse + run.
fn expectRunNum(g: *heap.Gc, v: *state.Vm, src: [:0]const u8, want: i64) !void {
    const wm0 = g.rootWatermark();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(g, &sym, src, &code);
    parser.resolveJumps(code.?, len);
    // Root the program across vmExec, popping BEFORE the watermark check
    // (the code root is our own +1; the VM itself must balance to wm0).
    g.rootPushPtr(@ptrCast(&code));
    const got = interp.vmExec(v, @ptrCast(code.?), len) catch |e| {
        g.rootPop();
        return e;
    };
    g.rootPop();
    try std.testing.expectEqual(types.ValTag.number, got.tag);
    try std.testing.expectEqual(want, got.payload.number);
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M4 zinctest 2: [lambda X X] returns a closure" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    const wm0 = g.rootWatermark();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(c(a[1:n]0v))", &code);
    parser.resolveJumps(code.?, len);
    const r = r: {
        g.rootPushPtr(@ptrCast(&code));
        defer g.rootPop();
        break :r try interp.vmExec(&v, @ptrCast(code.?), len);
    };
    // C expects "[lambda ...]": a lambda with an empty captured env whose
    // body is the 2-instr [access 0, return] child parsed from the cur.
    try std.testing.expectEqual(types.ValTag.lambda, r.tag);
    try std.testing.expectEqual(@as(i32, 0), r.payload.lambda.env_len);
    try std.testing.expectEqual(@as(i32, 2), r.payload.lambda.code_len);
    try std.testing.expect(r.payload.lambda.code != null);
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M4 zinctest 3: [let X 1 X] binds and reads back" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    try expectRunNum(&g, &v, "(n[1:n]1ea[1:n]0d)", 1);
}

test "M4 zinctest 34: appterm tail-calls the closure (id 42)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    try expectRunNum(&g, &v, "(mn[2:n]42c(a[1:n]0v)t)", 42);
}

test "M4 zinctest 35: appterm 2-arg RTL env indexes rightmost" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // RTL: 99 pushed first, 42 last; env=[42,99]; access 0 -> env[1] = 99.
    try expectRunNum(&g, &v, "(mn[2:n]99n[2:n]42c(a[1:n]0v)t)", 99);
}

test "M4 zinctest 36: appterm-in-apply frame reuse" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    try expectRunNum(&g, &v, "(mn[2:n]42c(ma[1:n]0c(a[1:n]0v)t)p)", 42);
}

test "M4 grab pops an argument from the stack into the env" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // Body [number 1, grab, access 0, return]: grab binds the pushed 1 as
    // the newest env slot; access 0 reads it back.
    try expectRunNum(&g, &v, "(mn[2:n]42c(n[1:n]1ra[1:n]0v)p)", 1);
}

test "M4 pc past end without frames returns acc" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    try expectRunNum(&g, &v, "(n[1:n]5)", 5);
}

test "M4 pc past end with a live frame pops the CallFrame" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // Body [access 0] has no return: running off the end pops the apply's
    // CallFrame and resumes at cf.pc — itself past the top-level end, so
    // both pc-out-of-range unwind paths run in one program.
    try expectRunNum(&g, &v, "(mn[2:n]42c(a[1:n]0)p)", 42);
}

test "M4 env grows past cap 64 under 100 nested lets" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // (n[1:n]7 e×100 a[1:n]99 d×100) built by hand: 100 lets grow the env
    // 4->8->...->128 (well past STACK_INIT_CAP-style 64), access 99 reads
    // the OLDEST binding env[0]=7, then 100 endlets pop back to empty.
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    const head = "(n[1:n]7";
    @memcpy(buf[n..][0..head.len], head);
    n += head.len;
    for (0..100) |_| {
        buf[n] = 'e';
        n += 1;
    }
    const mid = "a[2:n]99";
    @memcpy(buf[n..][0..mid.len], mid);
    n += mid.len;
    for (0..100) |_| {
        buf[n] = 'd';
        n += 1;
    }
    buf[n] = ')';
    n += 1;
    buf[n] = 0;
    const src: [:0]const u8 = buf[0..n :0];

    try expectRunNum(&g, &v, src, 7);
}

test "M4 apply with >64 args throws ShenError (DECISION A catchable)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // (m n[1:n]1 ×65 c(a[1:n]0v) p): collecting the 65th arg overflows the
    // 64-slot argbuf -> vm_throw, i.e. error.ShenError with the message in
    // the once-rooted err_slot.
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const head = "(m";
    @memcpy(buf[n..][0..head.len], head);
    n += head.len;
    for (0..65) |_| {
        const piece = "n[1:n]1";
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
    }
    const tail = "c(a[1:n]0v)p)";
    @memcpy(buf[n..][0..tail.len], tail);
    n += tail.len;
    buf[n] = 0;
    const src: [:0]const u8 = buf[0..n :0];

    const wm0 = g.rootWatermark();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, src, &code);
    parser.resolveJumps(code.?, len);
    g.rootPushPtr(@ptrCast(&code));
    err: {
        defer g.rootPop();
        try std.testing.expectError(error.ShenError, interp.vmExec(&v, @ptrCast(code.?), len));
        break :err;
    }
    try std.testing.expectEqual(types.ValTag.error_, v.err_slot.tag);
    try std.testing.expectEqualStrings(
        "runtime: too many args (>64)",
        std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0),
    );
    // The error unwind also popped to the entry watermark.
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M4 global lookup of an unknown name throws ShenError" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    const wm0 = g.rootWatermark();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(g[3:s]foo)", &code);
    parser.resolveJumps(code.?, len);
    g.rootPushPtr(@ptrCast(&code));
    err: {
        defer g.rootPop();
        try std.testing.expectError(error.ShenError, interp.vmExec(&v, @ptrCast(code.?), len));
        break :err;
    }
    try std.testing.expectEqual(types.ValTag.error_, v.err_slot.tag);
    try std.testing.expectEqualStrings(
        "global not found: foo",
        std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0),
    );
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M4 apply non-callable: hard stop outside trap, throw inside trap" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // Outside any catch site (C:3332-3345): hard stop with acc preserved —
    // the number 42 comes back normally (stderr noise is expected).
    try expectRunNum(&g, &v, "(n[2:n]42p)", 42);

    // Inside a trap-error catch site: the same program throws (catchable).
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(n[2:n]42p)", &code);
    parser.resolveJumps(code.?, len);

    var site = state.CatchSite{ .in_trap_error = true };
    site.parent = v.catch_chain;
    v.catch_chain = &site;
    defer v.catch_chain = site.parent;

    g.rootPushPtr(@ptrCast(&code));
    err: {
        defer g.rootPop();
        try std.testing.expectError(error.ShenError, interp.vmExec(&v, @ptrCast(code.?), len));
        break :err;
    }
    try std.testing.expectEqualStrings(
        "apply non-callable",
        std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0),
    );
}

test "M4 endlet on an empty env is a guarded no-op (C:3387)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    // C guards OP_ENDLET with `if (env_len > 0) env_pop(...)` — so (d) on
    // an empty env neither throws nor dies; it is a no-op and the program
    // simply runs off the end.  envPop's trap-site throw branch is purely
    // defensive (unreachable from the eval loop).
    var site = state.CatchSite{ .in_trap_error = true };
    site.parent = v.catch_chain;
    v.catch_chain = &site;
    defer v.catch_chain = site.parent;

    const wm0 = g.rootWatermark();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(d)", &code);
    parser.resolveJumps(code.?, len);
    const r = r: {
        g.rootPushPtr(@ptrCast(&code));
        defer g.rootPop();
        break :r try interp.vmExec(&v, @ptrCast(code.?), len);
    };
    try std.testing.expectEqual(types.ValTag.nil, r.tag);
    try std.testing.expectEqual(types.ValTag.nil, v.err_slot.tag); // nothing thrown
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M4 apply missing pushmark hard-stops with the function in acc" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();

    // (n[1:n]1 c(a[1:n]0v) p): the arg is collected but no mark follows —
    // C prints "apply missing pushmark" and stops with acc = the closure.
    const wm0 = g.rootWatermark();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &sym, "(n[1:n]1c(a[1:n]0v)p)", &code);
    parser.resolveJumps(code.?, len);
    const r = r: {
        g.rootPushPtr(@ptrCast(&code));
        defer g.rootPop();
        break :r try interp.vmExec(&v, @ptrCast(code.?), len);
    };
    try std.testing.expectEqual(types.ValTag.lambda, r.tag);
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M4 deep 2000-level cur/apply chain churns collections (verbose probe)" {
    // OOM INVESTIGATION (will shrink once diagnosed): at depth 10000 a
    // 64 MB/256 MB-reserved heap OOM'd; at depth 5000 even 128 MB/1 GB
    // reserved OOM'd — the expected live set is ~85 MB (2000..5000 frames
    // x ~2.7 KB, O(D^2) env semantics: each level's closure legitimately
    // captures a copy of the growing env).  This run is instrumented:
    // verbose GC banners print live_pages at each collect so the growth
    // curve is visible; verify_collects is OFF to discriminate a verifier
    // side effect from genuine retention.
    var g = try heap.Gc.init(.{
        .heap_bytes = 128 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
        .verbose = true,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    const depth = 2000;
    const wm0 = g.rootWatermark(); // err_slot root only

    // Programmatic apply chain (no parser recursion):
    //   top        = [pushmark, number 42, cur(body_0), apply]
    //   body_i     = [pushmark, access 0, cur(body_{i+1}), apply, ret]
    //   body_depth = [access 0, ret]
    // Each level applies the next closure with one arg (42), driving
    // frames_sp 10000 deep; the per-level stack/env/closure allocs churn
    // collections while verify_collects re-verifies the heap each time.
    const a = std.heap.page_allocator;
    const slots = try a.alloc(?[*]types.Instr, depth + 1);
    defer a.free(slots);

    const nilv: types.Value = .{ .tag = .nil, .payload = .{ .number = 0 } };

    // Deepest body first; every child array is rooted through its native
    // slot across the next level's alloc (the parser's cc_slot discipline).
    const deepest = g.allocArray(types.Instr, 2);
    deepest[0] = .{ .op = .access, .operand = values.valNumber(0), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    deepest[1] = .{ .op = .ret, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    slots[depth] = deepest;
    g.rootPushPtr(@ptrCast(&slots[depth]));

    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const arr = g.allocArray(types.Instr, 5);
        arr[0] = .{ .op = .pushmark, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[1] = .{ .op = .access, .operand = values.valNumber(0), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        // closure_code read from the ROOTED child slot AFTER this level's
        // alloc — the slot value is post-GC fresh even if it collected.
        arr[2] = .{ .op = .cur, .operand = nilv, .closure_code = @ptrCast(slots[i + 1].?), .closure_len = 5, .jmp_target = 0 };
        arr[3] = .{ .op = .apply, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[4] = .{ .op = .ret, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        slots[i] = arr;
        g.rootPushPtr(@ptrCast(&slots[i]));
    }

    const top_arr = g.allocArray(types.Instr, 4);
    top_arr[0] = .{ .op = .pushmark, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[1] = .{ .op = .number, .operand = values.valNumber(42), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[2] = .{ .op = .cur, .operand = nilv, .closure_code = @ptrCast(slots[0].?), .closure_len = 5, .jmp_target = 0 };
    top_arr[3] = .{ .op = .apply, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };

    // Drop the 10001 build roots and keep ONLY the program root, so the
    // chain is reachable solely via top -> closure_code links — exactly the
    // reachability the eval loop itself must preserve.  No alloc happens
    // between the popTo and the re-push, so nothing can move.
    var top: ?[*]types.Instr = top_arr;
    g.rootPopTo(wm0);
    g.rootPushPtr(@ptrCast(&top));
    defer g.rootPop();

    const r = try interp.vmExec(&v, @ptrCast(top.?), 4);
    try std.testing.expectEqual(types.ValTag.number, r.tag);
    try std.testing.expectEqual(@as(i64, 42), r.payload.number);
    try std.testing.expectEqual(wm0 + 1, g.rootWatermark());
}

// =====================================================================
//  M5 — exec_primitive, the pure subset (prims.zig)
// =====================================================================

/// expectRunNum's generalization: run `src`, return the raw result Value
/// (consumed before any further allocation), and check shadow balance.
fn expectRunVal(g: *heap.Gc, v: *state.Vm, src: [:0]const u8) !types.Value {
    const wm0 = g.rootWatermark();
    var sym = symbols.SymbolInterner.init();
    defer sym.deinit();
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(g, &sym, src, &code);
    parser.resolveJumps(code.?, len);
    g.rootPushPtr(@ptrCast(&code));
    const got = interp.vmExec(v, @ptrCast(code.?), len) catch |e| {
        g.rootPop();
        return e;
    };
    g.rootPop();
    try std.testing.expectEqual(wm0, g.rootWatermark());
    return got;
}

fn expectRunBool(g: *heap.Gc, v: *state.Vm, src: [:0]const u8, want: bool) !void {
    const r = try expectRunVal(g, v, src);
    try std.testing.expectEqual(types.ValTag.boolean, r.tag);
    try std.testing.expectEqual(@as(i64, if (want) 1 else 0), r.payload.boolean);
}

fn expectRunStr(g: *heap.Gc, v: *state.Vm, src: [:0]const u8, want: []const u8) !void {
    const r = try expectRunVal(g, v, src);
    try std.testing.expectEqual(types.ValTag.string, r.tag);
    try std.testing.expectEqualStrings(want, values.strSlice(r));
}

/// Call a primitive directly with a synthetic stack (the unit-test half of
/// M5): `args` are in POP order — args[0] is popped first (a1, the FIRST
/// Shen arg), matching the RTL push convention (rightmost pushed first).
/// The stack's data slot is rooted exactly like the eval loop's prologue
/// root (4), and the watermark must balance.
fn primExec(
    g: *heap.Gc,
    v: *state.Vm,
    name: []const u8,
    args: []const types.Value,
    acc: *types.Value,
) !void {
    const wm0 = g.rootWatermark();
    var stack: types.ValueArray = .{ .data = null, .len = 0, .cap = 0 };
    g.rootPushPtr(@ptrCast(&stack.data));
    interp.vaInit(g, &stack);
    // Push in REVERSE so args[0] lands on top (popped first, = a1).
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        interp.vaPush(g, &stack, args[i]);
    }
    try prims.execPrimitive(v, name, acc, &stack);
    g.rootPop(); // stack.data
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M5 zinctest 1,4,5,6: arithmetic +,-,*,/" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    try expectRunNum(&g, &v, "(mn[1:n]2n[1:n]1g[1:s]+p)", 3);
    try expectRunNum(&g, &v, "(mn[1:n]2n[1:n]1g[1:s]-p)", -1);
    try expectRunNum(&g, &v, "(mn[1:n]4n[1:n]3g[1:s]*p)", 12);
    try expectRunNum(&g, &v, "(mn[1:n]2n[2:n]10g[1:s]/p)", 5);
}

test "M5 zinctest 7-11,24,25: comparisons =,<,>,<=,>=" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    try expectRunBool(&g, &v, "(mn[1:n]1n[1:n]1g[1:s]=p)", true);
    try expectRunBool(&g, &v, "(mn[1:n]2n[1:n]1g[1:s]<p)", true);
    try expectRunBool(&g, &v, "(mn[1:n]3n[1:n]5g[1:s]>p)", true);
    try expectRunBool(&g, &v, "(mn[1:n]2n[1:n]2g[2:s]<=p)", true);
    try expectRunBool(&g, &v, "(mn[1:n]3n[1:n]5g[2:s]>=p)", true);
    try expectRunBool(&g, &v, "(mS[2:S]abS[2:S]abg[1:s]=p)", true);
    try expectRunBool(&g, &v, "(mn[1:n]2n[1:n]1g[1:s]=p)", false);
    // cross-type = never crashes: number vs string is false.
    try expectRunBool(&g, &v, "(mS[1:S]1n[1:n]1g[1:s]=p)", false);
}

test "M5 zinctest 12-16: type predicates" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    try expectRunBool(&g, &v, "(mn[2:n]42g[7:s]number?p)", true);
    try expectRunBool(&g, &v, "(ms[5:s]hellog[7:s]symbol?p)", true);
    try expectRunBool(&g, &v, "(mb[4:b]trueg[8:s]boolean?p)", true);
    try expectRunBool(&g, &v, "(mS[2:S]hig[7:s]string?p)", true);
    try expectRunBool(&g, &v, "(mn[2:n]42g[7:s]string?p)", false);
}

test "M5 zinctest 17: cons" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const r = try expectRunVal(&g, &v, "(mn[1:n]2n[1:n]1g[4:s]consp)");
    try std.testing.expectEqual(types.ValTag.cons, r.tag);
    const want = values.valCons(&g, values.valNumber(1), values.valNumber(2));
    try std.testing.expect(values.deepEqual(r, want, 0));
}

test "M5 zinctest 18-23: string prims cn/n->string/string->n/str/tlstr/intern" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    try expectRunStr(&g, &v, "(mS[5:S]worldS[5:S]hellog[2:s]cnp)", "helloworld");
    try expectRunStr(&g, &v, "(mn[2:n]42g[9:s]n->stringp)", "*"); // ASCII 42
    try expectRunNum(&g, &v, "(mS[2:S]42g[9:s]string->np)", 52); // ASCII '4'
    try expectRunStr(&g, &v, "(ms[5:s]hellog[3:s]strp)", "hello");
    try expectRunStr(&g, &v, "(mS[3:S]abcg[5:s]tlstrp)", "bc");
    const r = try expectRunVal(&g, &v, "(mS[3:S]foog[6:s]internp)");
    try std.testing.expectEqual(types.ValTag.symbol, r.tag);
    try std.testing.expectEqualStrings("foo", values.symSlice(r));
}

test "M5 zinctest 26: simple-error throws ShenError with the message" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    try std.testing.expectError(
        error.ShenError,
        expectRunVal(&g, &v, "(mS[4:S]boomg[12:s]simple-errorp)"),
    );
    try std.testing.expectEqualStrings(
        "boom",
        std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0),
    );
}

test "M5 zinctest 27: trap-error runs the handler on the error" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    // (trap-error (simple-error "oops") (lambda E "caught")) — handler pushed
    // FIRST (bottom), body LAST (top), exactly the zinctest RTL comment.
    try expectRunStr(
        &g,
        &v,
        "(mc(S[6:S]caughtv)c(mS[4:S]oopsg[12:s]simple-errorpv)g[10:s]trap-errorp)",
        "caught",
    );
    // Non-throwing body: trap-error returns the body value untouched.
    try expectRunNum(
        &g,
        &v,
        "(mc(S[6:S]caughtv)c(mn[1:n]7v)g[10:s]trap-errorp)",
        7,
    );
}

test "M5 trap-error handler sees the error: error-to-string through the trap path" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    // Handler = (lambda E (error-to-string E)): access 0 reads the appended
    // error from the handler env, primErrorToString copies it through the
    // slot-rooted valStringFromErr (the C:1973 latent-bug port-fix).
    try expectRunStr(
        &g,
        &v,
        "(mc(ma[1:n]0g[15:s]error-to-stringpv)c(mS[4:S]boomg[12:s]simple-errorpv)g[10:s]trap-errorp)",
        "boom",
    );
}

test "M5 zinctest 28: get-time unix returns a sane epoch-seconds number" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const r = try expectRunVal(&g, &v, "(ms[4:s]unixg[8:s]get-timep)");
    try std.testing.expectEqual(types.ValTag.number, r.tag);
    try std.testing.expect(r.payload.number > 1_600_000_000); // > 2020-09
    try std.testing.expect(r.payload.number < 4_000_000_000); // < 2096
}

test "M5 zinctest 33: appterm to a primitive" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    try expectRunNum(&g, &v, "(mn[1:n]2n[1:n]1g[1:s]+t)", 3);
}

test "M5 zinctest 37/38: appterm hard stops preserve acc (the closure)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    // 37: zero args — the eval loop prints and breaks to done, acc = closure.
    const r37 = try expectRunVal(&g, &v, "(c(a[1:n]0v)t)");
    try std.testing.expectEqual(types.ValTag.lambda, r37.tag);
    // 38: missing pushmark — same hard-stop shape.
    const r38 = try expectRunVal(&g, &v, "(n[2:n]42c(a[1:n]0v)t)");
    try std.testing.expectEqual(types.ValTag.lambda, r38.tag);
}

test "M5 unknown prim hard-stops (C: print + return -1)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = values.valNumber(99);
    // "frobnicate" is not in prim_table — error.Halt (the C `return -1`),
    // acc preserved.
    try std.testing.expectError(error.Halt, primExec(&g, &v, "frobnicate", &.{}, &acc));
    try std.testing.expectEqual(@as(i64, 99), acc.payload.number);
    // isValid/lookupDef agree with the table.
    try std.testing.expect(prims.isValid("+"));
    try std.testing.expect(!prims.isValid("frobnicate"));
    try std.testing.expect(prims.lookupDef("trap-error") != null);
}

test "M5 initGlobals registers every prim: defunGet falls back to valPrim" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    // [global absvector] resolves to the VAL_PRIM (M5 defunGet fallback);
    // a non-prim unknown name still falls back to a bare symbol.
    const p = v.defunGet("absvector");
    try std.testing.expectEqual(types.ValTag.prim, p.tag);
    try std.testing.expectEqualStrings("absvector", values.primSlice(p));
    const s = v.defunGet("*shen-macro*");
    try std.testing.expectEqual(types.ValTag.symbol, s.tag);
    // Every table name is registered (defunHas sees it).
    for (prims.primNames()) |def| {
        try std.testing.expect(v.defunHas(def.name));
    }
}

test "M5 hd/tl/empty? and list ops reverse/append/assoc/element?" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    const list = consNums(&g, &.{ 1, 2, 3 }); // [1 2 3]
    const pair = values.valCons(&g, values.valNumber(1), values.valNumber(2));

    try primExec(&g, &v, "hd", &.{list}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.number);
    try primExec(&g, &v, "tl", &.{list}, &acc);
    try std.testing.expect(values.deepEqual(acc, consNums(&g, &.{ 2, 3 }), 0));
    try primExec(&g, &v, "hd", &.{values.valNil()}, &acc); // nil -> nil
    try std.testing.expectEqual(types.ValTag.nil, acc.tag);
    try primExec(&g, &v, "tl", &.{values.valNil()}, &acc);
    try std.testing.expectEqual(types.ValTag.nil, acc.tag);
    try primExec(&g, &v, "empty?", &.{values.valNil()}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);
    try primExec(&g, &v, "empty?", &.{list}, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);

    // reverse (and the non-list throw).
    try primExec(&g, &v, "reverse", &.{list}, &acc);
    try std.testing.expect(values.deepEqual(acc, consNums(&g, &.{ 3, 2, 1 }), 0));
    try std.testing.expectError(
        error.ShenError,
        primExec(&g, &v, "reverse", &.{values.valNumber(1)}, &acc),
    );
    try std.testing.expectEqualStrings(
        "attempt to reverse a non-list",
        std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0),
    );

    // append [1 2] [3] = [1 2 3]; append nil x = x.
    try primExec(&g, &v, "append", &.{ consNums(&g, &.{ 1, 2 }), consNums(&g, &.{3}) }, &acc);
    try std.testing.expect(values.deepEqual(acc, list, 0));
    try primExec(&g, &v, "append", &.{ values.valNil(), pair }, &acc);
    try std.testing.expect(values.deepEqual(acc, pair, 0));

    // assoc: hit returns the pair, miss nil, non-list throws.
    const p12 = values.valCons(&g, values.valNumber(1), values.valNumber(2));
    const p34 = values.valCons(&g, values.valNumber(3), values.valNumber(4));
    const pairs = values.valCons(&g, p12, values.valCons(&g, p34, values.valNil()));
    try primExec(&g, &v, "assoc", &.{ values.valNumber(3), pairs }, &acc);
    try std.testing.expect(values.deepEqual(acc, p34, 0));
    try primExec(&g, &v, "assoc", &.{ values.valNumber(9), pairs }, &acc);
    try std.testing.expectEqual(types.ValTag.nil, acc.tag);
    try std.testing.expectError(
        error.ShenError,
        primExec(&g, &v, "assoc", &.{ values.valNumber(1), values.valNumber(7) }, &acc),
    );

    // element?
    try primExec(&g, &v, "element?", &.{ values.valNumber(2), list }, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);
    try primExec(&g, &v, "element?", &.{ values.valNumber(9), list }, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);
}

test "M5 vectors: absvector/address->/<-address with a forced scavenge (write barrier)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    try primExec(&g, &v, "absvector", &.{values.valNumber(100)}, &acc);
    try std.testing.expectEqual(types.ValTag.vector, acc.tag);
    try std.testing.expectEqual(@as(i32, 100), acc.payload.vector.len);

    // Store a NURSERY cons at slot 7 (address-> args in pop order:
    // vector, index, value).  acc is the only reference to the vector, so
    // root it across the scavenge below.
    g.rootPushValue(&acc);
    defer g.rootPop();
    const nursery_val = values.valCons(&g, values.valNumber(1), values.valNumber(2));
    try primExec(&g, &v, "address->", &.{ acc, values.valNumber(7), nursery_val }, &acc);
    try std.testing.expectEqual(types.ValTag.vector, acc.tag); // address-> returns the vector

    // Force a nursery scavenge: the vector element array must be re-scanned
    // via the remembered set (writeBarrierVectorStore) so the moved cons
    // stays reachable and the read-back is intact.
    g.collectNursery(.@"test");

    var got: types.Value = undefined;
    try primExec(&g, &v, "<-address", &.{ acc, values.valNumber(7) }, &got);
    try std.testing.expect(values.deepEqual(got, nursery_val, 0));
    // Fresh vector elements are zeroed Values: VAL_NUMBER(0) is tag 0
    // (C calloc parity — NOT nil).
    try primExec(&g, &v, "<-address", &.{ acc, values.valNumber(0) }, &got);
    try std.testing.expectEqual(types.ValTag.number, got.tag);
    try std.testing.expectEqual(@as(i64, 0), got.payload.number);

    try primExec(&g, &v, "absvector?", &.{acc}, &got);
    try std.testing.expectEqual(@as(i64, 1), got.payload.boolean);
    try primExec(&g, &v, "emptylist", &.{values.valNumber(0)}, &got);
    try std.testing.expectEqual(types.ValTag.nil, got.tag);
}

test "M5 error-to-string port-fix: message copy survives churn (valStringFromErr)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    // An error whose message sits in the NURSERY; churn the nursery, then
    // copy the message through the slot-rooted helper and check content.
    var err = values.valError(&g, "stale-pointer probe message");
    var guard = g.rootValue(&err);
    defer guard.end();
    var junk: types.Value = values.valNil();
    var jguard = g.rootValue(&junk);
    defer jguard.end();
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        junk = values.valCons(&g, values.valNumber(@intCast(i)), junk);
        if (i % 512 == 511) g.collectNursery(.@"test");
    }
    const s = values.valStringFromErr(&g, &err);
    try std.testing.expectEqual(types.ValTag.string, s.tag);
    try std.testing.expectEqualStrings("stale-pointer probe message", values.strSlice(s));

    // And through the prim: error->string, string passes through, anything
    // else becomes "unknown error".
    try primExec(&g, &v, "error-to-string", &.{err}, &acc);
    try std.testing.expectEqualStrings("stale-pointer probe message", values.strSlice(acc));
    try primExec(&g, &v, "error-to-string", &.{values.valNumber(1)}, &acc);
    try std.testing.expectEqualStrings("unknown error", values.strSlice(acc));
    try primExec(&g, &v, "error?", &.{err}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);
}

test "M5 string prims unit: pos/hdstr/substring/char-code/c-strlen/cn/str/bytes" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    const abc = values.valString(&g, "abc");
    try primExec(&g, &v, "pos", &.{ abc, values.valNumber(1) }, &acc);
    try std.testing.expectEqualStrings("b", values.strSlice(acc));
    try primExec(&g, &v, "pos", &.{ abc, values.valNumber(9) }, &acc);
    try std.testing.expectEqualStrings("", values.strSlice(acc)); // OOB outside trap
    try primExec(&g, &v, "hdstr", &.{abc}, &acc);
    try std.testing.expectEqualStrings("a", values.strSlice(acc));
    try primExec(&g, &v, "tlstr", &.{values.valString(&g, "a")}, &acc);
    try std.testing.expectEqualStrings("", values.strSlice(acc)); // safe len<=1 deviation
    try primExec(&g, &v, "substring", &.{ abc, values.valNumber(1), values.valNumber(5) }, &acc);
    try std.testing.expectEqualStrings("bc", values.strSlice(acc)); // clamped
    try primExec(&g, &v, "substring", &.{ abc, values.valNumber(-3), values.valNumber(2) }, &acc);
    try std.testing.expectEqualStrings("ab", values.strSlice(acc));
    try primExec(&g, &v, "char-code", &.{ abc, values.valNumber(0) }, &acc);
    try std.testing.expectEqual(@as(i64, 97), acc.payload.number);
    try primExec(&g, &v, "char-code", &.{ abc, values.valNumber(9) }, &acc);
    try std.testing.expectEqual(@as(i64, -1), acc.payload.number); // OOB
    try primExec(&g, &v, "c-strlen", &.{abc}, &acc);
    try std.testing.expectEqual(@as(i64, 3), acc.payload.number);

    // cn over numbers (pre-formatted into stack buffers) + symbols + nil.
    try primExec(&g, &v, "cn", &.{ values.valNumber(42), values.valString(&g, "x") }, &acc);
    try std.testing.expectEqualStrings("42x", values.strSlice(acc));
    try primExec(&g, &v, "cn", &.{ values.valBoolean(true), values.valNil() }, &acc);
    try std.testing.expectEqualStrings("true[]", values.strSlice(acc));

    // str of a composite renders the [a b c] list form (grow-loop path).
    const list = consNums(&g, &.{ 1, 2, 3 });
    try primExec(&g, &v, "str", &.{list}, &acc);
    try std.testing.expectEqualStrings("[1 2 3]", values.strSlice(acc));
    try primExec(&g, &v, "str", &.{values.valBoolean(false)}, &acc);
    try std.testing.expectEqualStrings("false", values.strSlice(acc));

    // str->bytes / bytes->string round-trip.
    const hi = values.valString(&g, "hi");
    try primExec(&g, &v, "shen.str->bytes", &.{hi}, &acc);
    try primExec(&g, &v, "shen.bytes->string", &.{acc}, &acc);
    try std.testing.expectEqualStrings("hi", values.strSlice(acc));
}

test "M5 set/value, gensym/newvar, @p/fst/snd, shen.fail!, variable?" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    // (set "counter" 42) returns the value; (value "counter") reads it back.
    const sym = symbols.valSymbol(&v.symbols, "counter");
    try primExec(&g, &v, "set", &.{ sym, values.valNumber(42) }, &acc);
    try std.testing.expectEqual(@as(i64, 42), acc.payload.number);
    try primExec(&g, &v, "value", &.{sym}, &acc);
    try std.testing.expectEqual(@as(i64, 42), acc.payload.number);
    // Unset (value X): symbol fallback (value_get has no prim fallback).
    try primExec(&g, &v, "value", &.{symbols.valSymbol(&v.symbols, "nope")}, &acc);
    try std.testing.expectEqual(types.ValTag.symbol, acc.tag);

    // gensym / newvar counters.
    try primExec(&g, &v, "gensym", &.{}, &acc);
    try std.testing.expectEqualStrings("shen.gensym_0", values.symSlice(acc));
    try primExec(&g, &v, "gensym", &.{}, &acc);
    try std.testing.expectEqualStrings("shen.gensym_1", values.symSlice(acc));
    try primExec(&g, &v, "newvar", &.{}, &acc);
    try std.testing.expectEqualStrings("V_0", values.symSlice(acc));

    // @p / fst / snd.
    try primExec(&g, &v, "@p", &.{ values.valNumber(1), values.valNumber(2) }, &acc);
    try std.testing.expectEqual(types.ValTag.cons, acc.tag);
    try primExec(&g, &v, "fst", &.{acc}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.number);
    try primExec(&g, &v, "@p", &.{ values.valNumber(3), values.valNumber(4) }, &acc);
    try primExec(&g, &v, "snd", &.{acc}, &acc);
    try std.testing.expectEqual(@as(i64, 4), acc.payload.number);

    // shen.fail! with an arg builds (fail Arg); without one it throws.
    try primExec(&g, &v, "shen.fail!", &.{values.valNumber(7)}, &acc);
    try std.testing.expectEqual(types.ValTag.cons, acc.tag);
    try std.testing.expectEqualStrings("fail", values.symSlice(acc.payload.cons.car.?.*));
    try std.testing.expectError(error.ShenError, primExec(&g, &v, "shen.fail!", &.{}, &acc));

    // variable?: uppercase-initial alnum/punct continuation.
    try primExec(&g, &v, "variable?", &.{symbols.valSymbol(&v.symbols, "X2?")}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);
    try primExec(&g, &v, "variable?", &.{symbols.valSymbol(&v.symbols, "x")}, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);
    try primExec(&g, &v, "variable?", &.{values.valNumber(1)}, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);

    // function? sees both lambdas and prims; stream? sees streams.
    try primExec(&g, &v, "function?", &.{values.valPrim("+")}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);
    try primExec(&g, &v, "function?", &.{values.valNumber(1)}, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);
    try primExec(&g, &v, "stream?", &.{values.valStreamIn(null)}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);
    try primExec(&g, &v, "cons?", &.{values.valNil()}, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);
}

test "M5 simple-error caps the message at 255 bytes (C snprintf parity)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    var big: [300]u8 = undefined;
    @memset(&big, 'x');
    const bigs = values.valString(&g, big[0..]);
    try std.testing.expectError(
        error.ShenError,
        primExec(&g, &v, "simple-error", &.{bigs}, &acc),
    );
    const msg = std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0);
    try std.testing.expectEqual(@as(usize, 255), msg.len);
    try std.testing.expectError(
        error.ShenError,
        primExec(&g, &v, "simple-error", &.{values.valNumber(3)}, &acc),
    );
    try std.testing.expectEqualStrings(
        "simple-error called",
        std.mem.sliceTo(v.err_slot.payload.error_.message.?, 0),
    );
}

// =====================================================================
//  M6 — bundle loader (parse_bundle + vm_load_bundle)
// =====================================================================

test "M6 loadBundle: entry parsed, defun-registered, callable" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const wm0 = g.rootWatermark();

    // One entry: (plus2 (cur body)) with body = the toplevel shape
    // [pushmark 2 1 global + apply ret] — a 0-arg closure computing 2+1.
    // The ret lives INSIDE the cur parens (the bundle cur convention); the
    // name atom is csexp form [5:s]plus2.
    const n = v.loadBundle("(([5:s]plus2 (c(mn[1:n]2n[1:n]1g[1:s]+pv))))");
    try std.testing.expectEqual(@as(i32, 1), n);
    try std.testing.expectEqual(wm0, g.rootWatermark());

    // defunGet resolves to the bundled lambda (explicit entry beats the
    // val_symbol fallback).
    const f = v.defunGet("plus2");
    try std.testing.expectEqual(types.ValTag.lambda, f.tag);

    // Call it: pushmark + global + apply -> nargs 0 -> run the body -> 3.
    try expectRunNum(&g, &v, "(mmg[5:s]plus2p)", 3);
}

test "M6 loadBundle: keywords, streams, tables, primitive?-names" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    _ = v.loadBundle("(([5:s]plus2 (c(mn[1:n]2n[1:n]1g[1:s]+pv))))");

    // Pattern keywords resolve to bare symbols (structural matching);
    // bundled entries keep their closures.
    try std.testing.expectEqual(types.ValTag.symbol, v.defunGet("number").tag);
    try std.testing.expectEqual(types.ValTag.symbol, v.defunGet("lookup").tag);
    try std.testing.expectEqual(types.ValTag.lambda, v.defunGet("plus2").tag);

    // A bundled `lookup` must NOT be clobbered by keyword registration
    // (C:4042-4051 — the metacircular interp needs [global lookup] to stay
    // its closure).
    var g2 = try testInit();
    defer g2.deinit();
    var v2: state.Vm = undefined;
    v2.init(&g2);
    defer v2.deinit();
    try std.testing.expectEqual(@as(i32, 2), v2.loadBundle(
        "(([6:s]lookup (c(mn[1:n]2n[1:n]1g[1:s]+pv))) ([5:s]plus2 (c(mn[1:n]2n[1:n]1g[1:s]+pv))))",
    ));
    try std.testing.expectEqual(types.ValTag.lambda, v2.defunGet("lookup").tag);
    try expectRunNum(&g2, &v2, "(mmg[6:s]lookupp)", 3);

    // Streams: value variables with in/out flags (files are the I/O
    // milestone's; null for now).
    const stin = v.valueGet("*stinput*");
    try std.testing.expectEqual(types.ValTag.stream, stin.tag);
    try std.testing.expectEqual(@as(i64, 1), stin.payload.stream.is_input);
    const stout = v.valueGet("*stoutput*");
    try std.testing.expectEqual(types.ValTag.stream, stout.tag);
    try std.testing.expectEqual(@as(i64, 0), stout.payload.stream.is_input);
    const sterr = v.valueGet("*sterror*");
    try std.testing.expectEqual(types.ValTag.stream, sterr.tag);

    // global-table / value-table start as empty alists, not bare symbols.
    try std.testing.expectEqual(types.ValTag.nil, v.valueGet("global-table").tag);
    try std.testing.expectEqual(types.ValTag.nil, v.valueGet("value-table").tag);

    // primitive?-names: exactly one entry per prim, head = LAST table name
    // (C forward-build parity).
    const names = prims.primNames();
    var pn = v.valueGet("primitive?-names");
    var count: usize = 0;
    while (pn.tag == .cons) : (count += 1) pn = pn.payload.cons.cdr.?.*;
    try std.testing.expectEqual(names.len, count);
    const head = v.valueGet("primitive?-names").payload.cons.car.?.*;
    try std.testing.expectEqualStrings(names[names.len - 1].name, values.symSlice(head));
}

test "M6 loadBundle: nested curs, scavenge survival, error paths" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const wm0 = g.rootWatermark();

    // Three entries: a plain body, a nested cur (inner closure applied at
    // runtime — the parser's cc-slot rooting across bundle entries), and a
    // string body.
    try std.testing.expectEqual(@as(i32, 3), v.loadBundle(
        "(([5:s]plus2 (c(mn[1:n]2n[1:n]1g[1:s]+pv))) ([5:s]seven (c(mc(mn[1:n]7v)pv))) ([2:s]hi (c(mS[2:S]hiv))))",
    ));
    try std.testing.expectEqual(wm0, g.rootWatermark());
    try expectRunNum(&g, &v, "(mmg[5:s]plus2p)", 3);
    try expectRunNum(&g, &v, "(mmg[5:s]sevenp)", 7);
    try expectRunStr(&g, &v, "(mmg[2:s]hip)", "hi");

    // The bundled closures live in the defun table: force a scavenge and
    // call again — the body code arrays must stay reachable and their
    // defun-table entries re-scanned (the dirty-scan path).
    g.collectNursery(.@"test");
    try expectRunNum(&g, &v, "(mmg[5:s]sevenp)", 7);
    try expectRunNum(&g, &v, "(mmg[5:s]plus2p)", 3);

    // Error paths (C semantics: print + partial count, never throw), each
    // leaving the shadow stack balanced.
    // Not a bundle (no '((*').
    try std.testing.expectEqual(@as(i32, 0), v.loadBundle("(mn[1:n]1g[1:s]+p)"));
    // Name atom is not a symbol.
    try std.testing.expectEqual(@as(i32, 0), v.loadBundle("(([1:n]5 (c(mn[1:n]1v))))"));
    // Code list has no cur wrapper.
    try std.testing.expectEqual(@as(i32, 0), v.loadBundle("(([1:s]f (mn[1:n]1v)))"));
    // Mid-bundle failure after one good entry: partial count.
    try std.testing.expectEqual(@as(i32, 1), v.loadBundle(
        "(([5:s]plus2 (c(mn[1:n]2n[1:n]1g[1:s]+pv))) (bad",
    ));
    try std.testing.expectEqual(wm0, g.rootWatermark());
    // The good entry is still callable after all that.
    try expectRunNum(&g, &v, "(mmg[5:s]plus2p)", 3);
}

// =====================================================================
//  M6b — real-bundle load canary (../globals.csexp)
// =====================================================================

/// Read a whole file into a sentinel-terminated owned buffer via raw POSIX
/// (Zig 0.16 has no std.fs; std.Io requires a threaded instance).  Returns
/// null if the file cannot be opened (skip-if-absent).  Caller frees with
/// std.heap.page_allocator.
fn readFileMaybe(path: []const u8) !?[:0]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => return null,
        else => return e,
    };
    defer _ = std.posix.system.close(fd);

    const a = std.heap.page_allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(a);
    var tmp: [65536]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &tmp);
        if (n == 0) break;
        try buf.appendSlice(a, tmp[0..n]);
    }
    return @as(?[:0]u8, try buf.toOwnedSliceSentinel(a, 0));
}

test "M6b realBundleLoad: 725KB globals.csexp loads and defuns stay callable" {
    // Bundle path is relative to cwd (the dir `zig build` runs from, i.e.
    // shen/zig).  Skip cleanly when absent rather than failing the gate.
    const maybe_buf = try readFileMaybe("../globals.csexp");
    if (maybe_buf == null) {
        std.debug.print("realBundleLoad: skipped (no ../globals.csexp)\n", .{});
        return;
    }
    const buf = maybe_buf.?;
    defer std.heap.page_allocator.free(buf);

    // C uses a 256MB heap / 65536-frame stack for the full OS bundle; give
    // the Zig port a comparable heap so mid-parse allocation churn never
    // forces a growth that changes the failure mode being probed.
    var g = try heap.Gc.init(.{
        .heap_bytes = 256 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const wm0 = g.rootWatermark();

    const n = v.loadBundle(buf);
    std.debug.print("realBundleLoad: loaded {d} closures\n", .{n});
    try std.testing.expect(n > 300);

    // The defun-table is rooted (registered with the GC at Vm.init), so the
    // loaded lambdas survive a forced scavenge + full collect and keep their
    // code arrays.  Assert every target name resolves to a lambda-tag value.
    const targets = [_][]const u8{
        "shen-parse-exprs", "extract-kl", "kl->zinc",
        "toplevel-interp",  "interp-eval", "tc-hm-init",
        "shen-read-file",
    };
    for (targets) |name| {
        try std.testing.expect(v.defunHas(name));
        const f = v.defunGet(name);
        try std.testing.expectEqual(types.ValTag.lambda, f.tag);
        try std.testing.expect(f.payload.lambda.code != null);
        try std.testing.expect(f.payload.lambda.code_len > 0);
    }

    // Force a scavenge then a full collect, then re-check three targets keep
    // their callable (lambda) shape — the code arrays must have been
    // forwarded/updated, not left as stale interior pointers.
    g.collectNursery(.@"test");
    g.collect(.@"test");
    for (targets[0..3]) |name| {
        const f = v.defunGet(name);
        try std.testing.expectEqual(types.ValTag.lambda, f.tag);
        try std.testing.expect(f.payload.lambda.code != null);
        try std.testing.expect(f.payload.lambda.code_len > 0);
    }

    // loadBundle must leave the shadow stack balanced (no leaked roots).
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

// =====================================================================
//  M1 — stream I/O prims (streams.zig): string streams + file streams
// =====================================================================

test "M1 string-stream read round-trip via open+read-byte+close" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    // Build a string stream directly through the registry (the path stored is
    // a page_allocator buffer).  Reading it back must yield the bytes.
    const ss = v.streams.valStringStreamIn(&g, "hello");
    try std.testing.expectEqual(types.ValTag.stream, ss.tag);
    try std.testing.expectEqual(@as(i64, 1), ss.payload.stream.is_string);

    // stream? on a string stream.
    try primExec(&g, &v, "stream?", &.{ss}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);

    // read-byte round-trip: 'h' 'e' 'l' 'l' 'o' then EOF (-1).
    const expect = "hello";
    for (expect) |c| {
        try primExec(&g, &v, "read-byte", &.{ss}, &acc);
        try std.testing.expectEqual(@as(i64, @intCast(c)), acc.payload.number);
    }
    try primExec(&g, &v, "read-byte", &.{ss}, &acc);
    try std.testing.expectEqual(@as(i64, -1), acc.payload.number);

    // close the string stream: nil result, slot data freed + nulled.
    try primExec(&g, &v, "close", &.{ss}, &acc);
    try std.testing.expectEqual(types.ValTag.nil, acc.tag);
    try std.testing.expect(v.streams.slots[0].data == null);
}

test "M1 open missing file becomes a string stream of the PATH bytes" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    const path = values.valString(&g, "/nonexistent-m1-path-xyz/definitely-absent");
    const dir = symbols.valSymbol(&v.symbols, "in");
    // open (2 args): args[0]=path popped first (a1), args[1]=dir.
    try primExec(&g, &v, "open", &.{ path, dir }, &acc);
    try std.testing.expectEqual(types.ValTag.stream, acc.tag);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.stream.is_string);

    // Reading the stream yields the PATH bytes verbatim (the C quirk).
    const s = acc; // capture the string stream (the read results clobber acc)
    const pbytes = values.strSlice(path);
    for (pbytes) |c| {
        try primExec(&g, &v, "read-byte", &.{s}, &acc);
        try std.testing.expectEqual(@as(i64, @intCast(c)), acc.payload.number);
    }
    try primExec(&g, &v, "read-byte", &.{s}, &acc);
    try std.testing.expectEqual(@as(i64, -1), acc.payload.number);

    try primExec(&g, &v, "close", &.{s}, &acc);
}

test "M1 open-out + write-byte + close + read-file-as-string round-trip on /tmp" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    const tmp = "/tmp/m1-writebyte-test-7f3a9c2e.txt";
    // Clean any stale file first (best-effort): ignore the fd, just unlink.
    _ = std.posix.system.unlink(tmp);

    const path = values.valString(&g, tmp);
    const dir_out = symbols.valSymbol(&v.symbols, "out");
    try primExec(&g, &v, "open", &.{ path, dir_out }, &acc);
    try std.testing.expectEqual(types.ValTag.stream, acc.tag);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.stream.is_string); // a real file stream
    try std.testing.expectEqual(@as(i64, 0), acc.payload.stream.is_input);
    try std.testing.expect(acc.payload.stream.file != null);

    // write-byte (2 args: args[0]=byte popped first, args[1]=stream).
    const out = acc; // capture the output file stream (write results clobber acc)
    const bytes = "ab";
    for (bytes) |c| {
        try primExec(&g, &v, "write-byte", &.{ values.valNumber(c), out }, &acc);
        try std.testing.expectEqual(@as(i64, @intCast(c)), acc.payload.number); // returns the byte
    }
    try primExec(&g, &v, "close", &.{out}, &acc);
    try std.testing.expectEqual(types.ValTag.nil, acc.tag);

    // read-file-as-string on the written file: "ab".
    try primExec(&g, &v, "read-file-as-string", &.{path}, &acc);
    try std.testing.expectEqual(types.ValTag.string, acc.tag);
    try std.testing.expectEqualStrings("ab", values.strSlice(acc));

    // Cleanup the temp file.
    _ = std.posix.system.unlink(tmp);
}

test "M1 read-file-as-string on a written temp file + stream? on a file stream" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    var acc: types.Value = undefined;

    const tmp = "/tmp/m1-readfile-test-4b81d0f3.txt";
    const content = "line one\nline two\n";
    // Write the temp file with raw POSIX before exercising the prim.
    {
        const fd = std.posix.openat(std.posix.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600) catch return error.TestUnexpectedResult;
        defer _ = std.posix.system.close(fd);
        _ = std.posix.system.write(fd, content.ptr, content.len);
    }

    // read-file-as-string returns the whole file.
    const path = values.valString(&g, tmp);
    try primExec(&g, &v, "read-file-as-string", &.{path}, &acc);
    try std.testing.expectEqual(types.ValTag.string, acc.tag);
    try std.testing.expectEqualStrings(content, values.strSlice(acc));

    // stream? on a real open-'in' file stream.
    const dir_in = symbols.valSymbol(&v.symbols, "in");
    try primExec(&g, &v, "open", &.{ path, dir_in }, &acc);
    try std.testing.expectEqual(types.ValTag.stream, acc.tag);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.stream.is_string);
    const fstr = acc; // capture the file stream (results clobber acc)
    try primExec(&g, &v, "stream?", &.{fstr}, &acc);
    try std.testing.expectEqual(@as(i64, 1), acc.payload.boolean);

    // Read a couple bytes back from the real file stream then close it.
    try primExec(&g, &v, "read-byte", &.{fstr}, &acc);
    try std.testing.expectEqual(@as(i64, 'l'), acc.payload.number);
    try primExec(&g, &v, "close", &.{fstr}, &acc);
    try std.testing.expectEqual(types.ValTag.nil, acc.tag);

    // stream? on a non-stream returns false.
    try primExec(&g, &v, "stream?", &.{values.valNumber(1)}, &acc);
    try std.testing.expectEqual(@as(i64, 0), acc.payload.boolean);

    _ = std.posix.system.unlink(tmp);
}

// =====================================================================
//  M2 — marshal/demarshal + eval-kl (marshal.zig, hostcall.zig)
// =====================================================================

/// Deterministic LCG for the property test (std.rand is thread-scoped and
/// heavyweight for a test; a plain PCG-style step is enough here).
fn m2NextRand(rng: *u64) u64 {
    rng.* = rng.* *% 6364136223846793005 +% 1442695040888963407;
    return rng.* >> 33;
}

/// Build a random tree with leaves from {number, string, boolean, nil,
/// symbol foo|bar|quux} and cons nodes.  SYMBOLS ARE SAFE IN CAR POSITIONS:
/// the demarshal protocol only special-cases the five reserved tag symbols
/// (number/symbol/string/boolean/cons) and 'mark' — none of which this
/// generator can emit — so every generated tree is a fixed point of
/// demarshal∘marshal (the round-trip property under test).  The car is
/// rooted across the cdr build (valCons roots its own params internally).
fn m2BuildTree(v: *state.Vm, rng: *u64, depth: u32, counter: *u32) types.Value {
    const g = v.gc;
    if (depth == 0 or m2NextRand(rng) % 5 == 0) {
        switch (m2NextRand(rng) % 5) {
            0 => return values.valNumber(@intCast(m2NextRand(rng) % 1000)),
            1 => {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "s{d}", .{counter.*}) catch unreachable;
                counter.* += 1;
                return values.valString(g, s);
            },
            2 => return values.valBoolean(m2NextRand(rng) % 2 == 0),
            3 => return values.valNil(),
            else => return switch (m2NextRand(rng) % 3) {
                0 => symbols.valSymbol(&v.symbols, "foo"),
                1 => symbols.valSymbol(&v.symbols, "bar"),
                else => symbols.valSymbol(&v.symbols, "quux"),
            },
        }
    }
    var car = m2BuildTree(v, rng, depth - 1, counter);
    var car_guard = g.rootValue(&car);
    defer car_guard.end();
    const cdr = m2BuildTree(v, rng, depth - 1, counter);
    return values.valCons(g, car, cdr);
}

/// Build a proper list [i0 i1 ... ik] from values (the eval-kl form
/// builder).  The items are copied into a rooted buffer so string items
/// survive the valCons churn (numbers/symbols carry no GC interiors, but
/// strings do).
fn m2List(g: *heap.Gc, items: []const types.Value) types.Value {
    var buf: [16]types.Value = undefined;
    var n: i32 = @intCast(items.len);
    for (items, 0..) |it, idx| buf[idx] = it;
    g.rootPushValueArray(&buf, &n);
    defer g.rootPop();
    var head = values.valNil();
    var guard = g.rootValue(&head);
    defer guard.end();
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        head = values.valCons(g, buf[i], head);
    }
    return head;
}

test "M2 marshal/demarshal: scalar tags, [cons] empty, mark, passthroughs" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // [number 5] shape: cons(symbol number, cons(5, nil)); round-trips.
    const m5 = vm.marshal.marshalToTagged(&v, values.valNumber(5));
    try std.testing.expectEqual(types.ValTag.cons, m5.tag);
    try std.testing.expectEqualStrings("number", values.symSlice(m5.payload.cons.car.?.*));
    const cdr5 = m5.payload.cons.cdr.?.*;
    try std.testing.expectEqual(@as(i64, 5), cdr5.payload.cons.car.?.payload.number);
    try std.testing.expectEqual(types.ValTag.nil, cdr5.payload.cons.cdr.?.tag);
    try std.testing.expectEqual(@as(i64, 5), vm.marshal.demarshalFromTagged(&v, m5).payload.number);

    // Strings / symbols / booleans round-trip through their tags.
    const ms = vm.marshal.marshalToTagged(&v, values.valString(&g, "ab"));
    try std.testing.expectEqualStrings("ab", values.strSlice(vm.marshal.demarshalFromTagged(&v, ms)));
    const msym = vm.marshal.marshalToTagged(&v, symbols.valSymbol(&v.symbols, "foo"));
    try std.testing.expectEqualStrings("foo", values.symSlice(vm.marshal.demarshalFromTagged(&v, msym)));
    const mb = vm.marshal.marshalToTagged(&v, values.valBoolean(true));
    try std.testing.expectEqual(@as(i64, 1), vm.marshal.demarshalFromTagged(&v, mb).payload.boolean);

    // nil marshals to [cons] (symbol cons + nil cdr) and demarshals back.
    const mnil = vm.marshal.marshalToTagged(&v, values.valNil());
    try std.testing.expectEqualStrings("cons", values.symSlice(mnil.payload.cons.car.?.*));
    try std.testing.expectEqual(types.ValTag.nil, mnil.payload.cons.cdr.?.tag);
    try std.testing.expectEqual(types.ValTag.nil, vm.marshal.demarshalFromTagged(&v, mnil).tag);

    // mark marshals to the SYMBOL 'mark; the symbol 'mark demarshals to nil.
    const mmark = vm.marshal.marshalToTagged(&v, values.valMark());
    try std.testing.expectEqual(types.ValTag.symbol, mmark.tag);
    try std.testing.expectEqualStrings("mark", values.symSlice(mmark));
    try std.testing.expectEqual(types.ValTag.nil, vm.marshal.demarshalFromTagged(&v, symbols.valSymbol(&v.symbols, "mark")).tag);

    // Lambdas / vectors / errors pass through BOTH directions unchanged.
    const lam = values.valLambda(&g, null, 0, null, 0);
    try std.testing.expectEqual(types.ValTag.lambda, vm.marshal.marshalToTagged(&v, lam).tag);
    try std.testing.expectEqual(types.ValTag.lambda, vm.marshal.demarshalFromTagged(&v, lam).tag);
    const vec = values.valVector(&g, 2);
    try std.testing.expectEqual(types.ValTag.vector, vm.marshal.marshalToTagged(&v, vec).tag);
    const errv = values.valError(&g, "boom");
    try std.testing.expectEqual(types.ValTag.error_, vm.marshal.demarshalFromTagged(&v, errv).tag);

    // marshal of a cons is the 3-ELEMENT LIST [cons X Y] with RAW car/cdr
    // (the no-recursion rule, C:763-767): cadr is the raw number 1, and the
    // actual cdr rides in a SINGLETON wrapper (the 3rd element is (2 nil)).
    var pair = values.valCons(&g, values.valNumber(1), values.valNumber(2));
    var pair_guard = g.rootValue(&pair);
    defer pair_guard.end();
    const mp = vm.marshal.marshalToTagged(&v, pair);
    try std.testing.expectEqualStrings("cons", values.symSlice(mp.payload.cons.car.?.*));
    const mp_cdr = mp.payload.cons.cdr.?.*; // (1 (2 nil))
    try std.testing.expectEqual(@as(i64, 1), mp_cdr.payload.cons.car.?.payload.number); // RAW 1
    const wrapper = mp_cdr.payload.cons.cdr.?.*; // ((2 nil))
    try std.testing.expectEqual(types.ValTag.cons, wrapper.tag);
    try std.testing.expectEqual(@as(i64, 2), wrapper.payload.cons.car.?.payload.number); // RAW 2
    try std.testing.expectEqual(types.ValTag.nil, wrapper.payload.cons.cdr.?.tag);
    // ...and demarshal rebuilds the DOTTED pair cons(1 . 2).
    const back = vm.marshal.demarshalFromTagged(&v, mp);
    try std.testing.expect(values.deepEqual(pair, back, 0));
    try std.testing.expectEqual(types.ValTag.number, back.payload.cons.cdr.?.tag);
}

test "M2 marshal/demarshal round-trip property: random nested cons trees" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    var rng: u64 = 0x5eed_cafe_f00d;
    var counter: u32 = 0;
    var iter: usize = 0;
    while (iter < 64) : (iter += 1) {
        var tree = m2BuildTree(&v, &rng, 4, &counter);
        var tree_guard = g.rootValue(&tree);
        defer tree_guard.end();

        var tagged = vm.marshal.marshalToTagged(&v, tree);
        var tagged_guard = g.rootValue(&tagged);
        defer tagged_guard.end();

        // Churn + a forced scavenge BETWEEN marshal and demarshal: the
        // tagged form survives only via its root (its cons car/cdr interior
        // pointers must be re-read fresh through the rooted slot).
        var junk = values.valNil();
        var junk_guard = g.rootValue(&junk);
        defer junk_guard.end();
        var k: usize = 0;
        while (k < 200) : (k += 1)
            junk = values.valCons(&g, values.valNumber(@intCast(k)), junk);
        g.collectNursery(.@"test");

        var back = vm.marshal.demarshalFromTagged(&v, tagged);
        var back_guard = g.rootValue(&back);
        defer back_guard.end();
        try std.testing.expect(values.deepEqual(tree, back, 0));
    }
}

test "M2 eval-kl without a bundle: missing closure returns the input form" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // No loadBundle: extract-kl resolves to a bare symbol (defunGet's
    // fallback), the stage warns on stderr, and eval-kl's acc is the INPUT
    // FORM (C goto eval_kl_done with result = a).
    var form = m2List(&g, &.{ symbols.valSymbol(&v.symbols, "+"), values.valNumber(1), values.valNumber(2) });
    var acc: types.Value = values.valNil();
    try primExecRooted(&g, &v, "eval-kl", &form, &acc);
    try std.testing.expect(values.deepEqual(form, acc, 0));

    // Scalar forms too (marshal still runs first, then the fallback).
    var form2 = values.valNumber(42);
    try primExecRooted(&g, &v, "eval-kl", &form2, &acc);
    try std.testing.expectEqual(@as(i64, 42), acc.payload.number);
}

test "M2 eval-kl on the real bundle: zinctest 5/11/12/13/14/14b parity" {
    // Inline setup (M6b pattern) — the Vm must NOT be moved after init
    // (state.zig: &vm.err_slot / &vm.defun_table_cap are GC-registered
    // addresses), so no helper returning it by value.
    const maybe_buf = try readFileMaybe("../globals.csexp");
    if (maybe_buf == null) {
        std.debug.print("M2 eval-kl: skipped (no ../globals.csexp)\n", .{});
        return;
    }
    const buf = maybe_buf.?;
    var g = try heap.Gc.init(.{
        .heap_bytes = 256 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    _ = v.loadBundle(buf);
    var acc: types.Value = values.valNil();

    // --- Test 5 parity: [+ 1 2] -> 3 (direct exec_primitive path, the
    //     eval_kl_form shape shensh.c:329-338 uses).
    {
        const plus = symbols.valSymbol(&v.symbols, "+");
        var form = m2List(&g, &.{ plus, values.valNumber(1), values.valNumber(2) });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.number, acc.tag);
        try std.testing.expectEqual(@as(i64, 3), acc.payload.number);
    }

    // --- Test 11 parity: [cons 1 2] -> the DOTTED pair [cons 1 . 2].
    {
        const csym = symbols.valSymbol(&v.symbols, "cons");
        var form = m2List(&g, &.{ csym, values.valNumber(1), values.valNumber(2) });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.cons, acc.tag);
        try std.testing.expectEqual(@as(i64, 1), acc.payload.cons.car.?.payload.number);
        try std.testing.expectEqual(types.ValTag.number, acc.payload.cons.cdr.?.tag);
        try std.testing.expectEqual(@as(i64, 2), acc.payload.cons.cdr.?.payload.number);
    }

    // --- Test 12 parity: [+ [* 2 3] 4] -> 10 (nested form, rooted inner).
    {
        const plus = symbols.valSymbol(&v.symbols, "+");
        const mul = symbols.valSymbol(&v.symbols, "*");
        var inner = m2List(&g, &.{ mul, values.valNumber(2), values.valNumber(3) });
        var iguard = g.rootValue(&inner);
        defer iguard.end();
        var form = m2List(&g, &.{ plus, inner, values.valNumber(4) });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.number, acc.tag);
        try std.testing.expectEqual(@as(i64, 10), acc.payload.number);
    }

    // --- Test 13 parity: [cn "hello" "world"] -> "helloworld".
    {
        const cn = symbols.valSymbol(&v.symbols, "cn");
        var form = m2List(&g, &.{ cn, values.valString(&g, "hello"), values.valString(&g, "world") });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.string, acc.tag);
        try std.testing.expectEqualStrings("helloworld", values.strSlice(acc));
    }

    // --- Test 14 parity: [hd 42] -> an ERROR VALUE (the metacircular
    //     interp's "unknown prim" throw), caught by eval-kl's CatchSite and
    //     returned in acc — NOT propagated as a VmError (primExecRooted's
    //     `try` would fail the test if it were).
    {
        const hd = symbols.valSymbol(&v.symbols, "hd");
        var form = m2List(&g, &.{ hd, values.valNumber(42) });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.error_, acc.tag);
        try std.testing.expect(std.mem.indexOf(u8, values.errSlice(acc), "unknown prim") != null);
    }

    // --- Test 14b parity: [/ 1 0] -> error VALUE "division by zero" (the
    //     safe./ wrapper intercepts; the raw / prim never sees the zero).
    {
        const div = symbols.valSymbol(&v.symbols, "/");
        var form = m2List(&g, &.{ div, values.valNumber(1), values.valNumber(0) });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.error_, acc.tag);
        try std.testing.expectEqualStrings("division by zero", values.errSlice(acc));
    }
}

test "M2 eval-kl on the real bundle: set/value, bytecode path, GC-verified chain" {
    // verify_collects: every collection during the eval-kl chain re-verifies
    // the heap — the whole-stack precise-rooting proof for the new path.
    const maybe_buf = try readFileMaybe("../globals.csexp");
    if (maybe_buf == null) {
        std.debug.print("M2 eval-kl: skipped (no ../globals.csexp)\n", .{});
        return;
    }
    const buf = maybe_buf.?;
    var g = try heap.Gc.init(.{
        .heap_bytes = 256 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
        .verify_collects = true,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    _ = v.loadBundle(buf);
    var acc: types.Value = values.valNil();

    // (set x "v") — the boot_set_kl_string path (shensh.c:355-364): the
    // value lands TAGGED in the values table via the interp's [prim set]
    // rule, and eval-kl's demarshal returns the plain string.
    {
        const setsym = symbols.valSymbol(&v.symbols, "set");
        const xsym = symbols.valSymbol(&v.symbols, "x");
        var form = m2List(&g, &.{ setsym, xsym, values.valString(&g, "v") });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.string, acc.tag);
        try std.testing.expectEqualStrings("v", values.strSlice(acc));
    }

    // (value x) -> "v" — reads back through the interp's [prim value] rule.
    {
        const valuesym = symbols.valSymbol(&v.symbols, "value");
        const xsym = symbols.valSymbol(&v.symbols, "x");
        var form = m2List(&g, &.{ valuesym, xsym });
        try primExecRooted(&g, &v, "eval-kl", &form, &acc);
        try std.testing.expectEqual(types.ValTag.string, acc.tag);
        try std.testing.expectEqualStrings("v", values.strSlice(acc));
    }

    // Bytecode path — zinctest.c:1598-1600 verbatim: defun_set("*ev1*", form)
    // then run (g[5:s]*ev1*P[7:s]eval-kl) through vmExec (OP_PRIM inline).
    {
        const plus = symbols.valSymbol(&v.symbols, "+");
        const form = m2List(&g, &.{ plus, values.valNumber(1), values.valNumber(2) });
        v.defunSet("*ev1*", form);
        try expectRunNum(&g, &v, "(g[5:s]*ev1*P[7:s]eval-kl)", 3);
    }

    // A few repeat runs under verify_collects — the compile+interp chain
    // allocates heavily, so natural scavenges fire and get re-verified.
    {
        const plus = symbols.valSymbol(&v.symbols, "+");
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            var form = m2List(&g, &.{ plus, values.valNumber(@intCast(i)), values.valNumber(2) });
            try primExecRooted(&g, &v, "eval-kl", &form, &acc);
            try std.testing.expectEqual(types.ValTag.number, acc.tag);
            try std.testing.expectEqual(@as(i64, @intCast(i + 2)), acc.payload.number);
        }
    }
}

/// primExec's rooting-safe variant for stress churn: roots the ARG SLOT
/// itself (not a caller-copied slice) so a scavenge during vaInit/vaPush —
/// certain under stress — can never push a stale interior pointer.  The
/// arg value is re-read through the root at push time (post-GC fresh).
fn primExecRooted(
    g: *heap.Gc,
    v: *state.Vm,
    name: []const u8,
    arg: *types.Value,
    acc: *types.Value,
) !void {
    const wm0 = g.rootWatermark();
    g.rootPushValue(arg);
    g.rootPushValue(acc);
    var stack: types.ValueArray = .{ .data = null, .len = 0, .cap = 0 };
    g.rootPushPtr(@ptrCast(&stack.data));
    interp.vaInit(g, &stack);
    interp.vaPush(g, &stack, arg.*); // fresh read through the root
    try prims.execPrimitive(v, name, acc, &stack);
    g.rootPop(); // stack.data
    g.rootPop(); // acc
    g.rootPop(); // arg
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

/// Two-arg variant of primExecRooted (append-shaped prims).  a1/a2 must be
/// distinct rooted slots (assign a copy with no intervening allocation).
fn primExecRooted2(
    g: *heap.Gc,
    v: *state.Vm,
    name: []const u8,
    a1: *types.Value,
    a2: *types.Value,
    acc: *types.Value,
) !void {
    const wm0 = g.rootWatermark();
    g.rootPushValue(a1);
    g.rootPushValue(a2);
    g.rootPushValue(acc);
    var stack: types.ValueArray = .{ .data = null, .len = 0, .cap = 0 };
    g.rootPushPtr(@ptrCast(&stack.data));
    interp.vaInit(g, &stack);
    // Push in REVERSE so a1 lands on top (popped first = first Shen arg).
    interp.vaPush(g, &stack, a2.*);
    interp.vaPush(g, &stack, a1.*);
    try prims.execPrimitive(v, name, acc, &stack);
    g.rootPop(); // stack.data
    g.rootPop(); // acc
    g.rootPop(); // a2
    g.rootPop(); // a1
    try std.testing.expectEqual(wm0, g.rootWatermark());
}

test "M7 stress: 50k-cons build/reverse/append churn under verify_collects" {
    var g = try heap.Gc.init(.{
        .heap_bytes = 128 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
        .verify_collects = true,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    var acc: types.Value = values.valNil();
    var acc2: types.Value = values.valNil();
    var hd: types.Value = values.valNil();

    var iter: usize = 0;
    while (iter < 50) : (iter += 1) {
        // Rooted 50k-cons build of [0..49999] (consNums is unsafe at this
        // scale — it never roots its accumulator).
        var list = values.valNil();
        var lguard = g.rootValue(&list);
        defer lguard.end();
        var i: usize = 50000;
        while (i > 0) {
            i -= 1;
            list = values.valCons(&g, values.valNumber(@intCast(i)), list);
        }

        // reverse: 50k fresh conses allocated inside execPrimitive.
        try primExecRooted(&g, &v, "reverse", &list, &acc);
        try primExecRooted(&g, &v, "hd", &acc, &hd);
        try std.testing.expectEqual(@as(i64, 49999), hd.payload.number);

        // append the reversed list to itself: 100k fresh conses.
        acc2 = acc; // no allocation between the copy and the rooted call
        try primExecRooted2(&g, &v, "append", &acc, &acc2, &hd);
        try primExecRooted(&g, &v, "hd", &hd, &acc2);
        try std.testing.expectEqual(@as(i64, 49999), acc2.payload.number);

        // Occasional full collect — verified end to end.
        if (iter % 25 == 24) g.collect(.@"test");
    }
}

test "M7 stress: 600-level cur/apply chain with prim calls interleaved" {
    var g = try heap.Gc.init(.{
        .heap_bytes = 128 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // Chain shape (M4's deep-recursion test with a + prim call per level):
    //   top     = [pushmark, number 41, number 1, global +, apply,
    //              cur(body_0), apply]
    //   body_i  = [pushmark, access 0, number 1, global +, apply,
    //              cur(body_{i+1}), apply, ret]
    //   deepest = [access 0, ret]
    // The prim apply leaves N+1 on the stack under the still-open mark,
    // which then becomes the recursive call's single argument; each frame's
    // cur captures its own env, so envs grow linearly with depth (deeper
    // write-barrier/nursery-reference churn than the M4 chain).
    const depth: usize = 600;
    const wm0 = g.rootWatermark();
    const a = std.heap.page_allocator;
    const slots = try a.alloc(?[*]types.Instr, depth + 1);
    defer a.free(slots);
    const nilv: types.Value = .{ .tag = .nil, .payload = .{ .number = 0 } };
    const plus = symbols.valSymbol(&v.symbols, "+");

    const deepest = g.allocArray(types.Instr, 2);
    deepest[0] = .{ .op = .access, .operand = values.valNumber(0), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    deepest[1] = .{ .op = .ret, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    slots[depth] = deepest;
    g.rootPushPtr(@ptrCast(&slots[depth]));

    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const arr = g.allocArray(types.Instr, 8);
        arr[0] = .{ .op = .pushmark, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[1] = .{ .op = .access, .operand = values.valNumber(0), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[2] = .{ .op = .number, .operand = values.valNumber(1), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[3] = .{ .op = .global, .operand = plus, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[4] = .{ .op = .apply, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        // closure_code read from the ROOTED child slot AFTER this level's
        // alloc — post-GC fresh even if it collected.
        arr[5] = .{ .op = .cur, .operand = nilv, .closure_code = @ptrCast(slots[i + 1].?), .closure_len = 8, .jmp_target = 0 };
        arr[6] = .{ .op = .apply, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        arr[7] = .{ .op = .ret, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
        slots[i] = arr;
        g.rootPushPtr(@ptrCast(&slots[i]));
    }

    const top_arr = g.allocArray(types.Instr, 7);
    top_arr[0] = .{ .op = .pushmark, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[1] = .{ .op = .number, .operand = values.valNumber(41), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[2] = .{ .op = .number, .operand = values.valNumber(1), .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[3] = .{ .op = .global, .operand = plus, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[4] = .{ .op = .apply, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };
    top_arr[5] = .{ .op = .cur, .operand = nilv, .closure_code = @ptrCast(slots[0].?), .closure_len = 8, .jmp_target = 0 };
    top_arr[6] = .{ .op = .apply, .operand = nilv, .closure_code = null, .closure_len = 0, .jmp_target = 0 };

    // Keep ONLY the program root, exactly like the M4 chain test.
    var top: ?[*]types.Instr = top_arr;
    g.rootPopTo(wm0);
    g.rootPushPtr(@ptrCast(&top));
    defer g.rootPop();

    const r = try interp.vmExec(&v, @ptrCast(top.?), 7);
    try std.testing.expectEqual(types.ValTag.number, r.tag);
    try std.testing.expectEqual(@as(i64, 42 + @as(i64, @intCast(depth))), r.payload.number);
    try std.testing.expectEqual(wm0 + 1, g.rootWatermark());
}

test "M7 stress: defun mutation under forced scavenges keeps table integrity" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const wm0 = g.rootWatermark();

    var junk: types.Value = values.valNil();
    var jguard = g.rootValue(&junk);
    defer jguard.end();

    var i: usize = 0;
    while (i < 512) : (i += 1) {
        // A fresh NURSERY cons stored straight into the registered global
        // table (dirty-marked by defunSet) — no alloc between valCons and
        // defunSet, so the hand-off is safe.
        v.defunSet("stress-fn", values.valCons(&g, values.valNumber(@intCast(i)), values.valNil()));
        // Churn + a forced scavenge: the dirty slot must be re-scanned so
        // the moved cons (and its car cell) stays reachable and updated.
        junk = values.valCons(&g, values.valNumber(0), junk);
        g.collectNursery(.@"test");
        const got = v.defunGet("stress-fn");
        try std.testing.expectEqual(types.ValTag.cons, got.tag);
        try std.testing.expectEqual(@as(i64, @intCast(i)), got.payload.cons.car.?.*.payload.number);
    }
    // wm0 + 1: the junk guard root is still held (its defer ends later).
    try std.testing.expectEqual(wm0 + 1, g.rootWatermark());
}

// =====================================================================
//  M3 — the process layer (execplan.zig): zinctest.c 41-52 + gate extras
// =====================================================================

// ---- tagged plan builders (zinctest.c:117-249, mirrored rooting) ----
// Same tagged forms the metacircular interp produces ([cons H T] as a
// 3-element list, [cons] = empty).  The string/number/nil/cons builders are
// the PUB execplan helpers themselves (each roots its args internally); only
// [symbol X] needs a local twin.  A Value passed as an argument is DEAD
// after the call (it may move) — never reuse it.

fn tsymZ(v: *state.Vm, s: []const u8) types.Value {
    const g = v.gc;
    var sv = symbols.valSymbol(&v.symbols, s);
    g.rootPushValue(&sv);
    var inner = values.valCons(g, sv, values.valNil());
    g.rootPushValue(&inner);
    const result = values.valCons(g, symbols.valSymbol(&v.symbols, "symbol"), inner);
    g.rootPop();
    g.rootPop();
    return result;
}

fn tlist2Z(v: *state.Vm, a: types.Value, b: types.Value) types.Value {
    const g = v.gc;
    var av = a;
    var bv = b;
    g.rootPushValue(&av);
    g.rootPushValue(&bv);
    const l = execplan.makeTaggedNil(v);
    const r = execplan.makeTaggedCons(v, bv, l);
    g.rootPop();
    g.rootPop();
    return execplan.makeTaggedCons(v, av, r);
}

/// [cons a [cons]] — ONE-element tagged list (zinctest.c tlist1_).
fn tlist1Z(v: *state.Vm, a: types.Value) types.Value {
    const g = v.gc;
    var av = a;
    g.rootPushValue(&av);
    const nil = execplan.makeTaggedNil(v);
    const r = execplan.makeTaggedCons(v, av, nil);
    g.rootPop();
    return r;
}

fn tlist3Z(v: *state.Vm, a: types.Value, b: types.Value, c: types.Value) types.Value {
    const g = v.gc;
    var av = a;
    var bv = b;
    var cv = c;
    g.rootPushValue(&av);
    g.rootPushValue(&bv);
    g.rootPushValue(&cv);
    const l = execplan.makeTaggedNil(v);
    const r2 = execplan.makeTaggedCons(v, cv, l);
    const r1 = execplan.makeTaggedCons(v, bv, r2);
    g.rootPop();
    g.rootPop();
    g.rootPop();
    return execplan.makeTaggedCons(v, av, r1);
}

fn targvZ(v: *state.Vm, argv: []const []const u8) types.Value {
    const g = v.gc;
    var av = execplan.makeTaggedNil(v);
    g.rootPushValue(&av);
    defer g.rootPop();
    var i = argv.len;
    while (i > 0) {
        i -= 1;
        const s = execplan.makeTaggedString(v, argv[i]);
        av = execplan.makeTaggedCons(v, s, av);
    }
    return av;
}

/// Cmd = [argv [] ()] (zinctest.c tcmd_).
fn tcmdZ(v: *state.Vm, argv: []const []const u8) types.Value {
    const g = v.gc;
    var av = targvZ(v, argv);
    g.rootPushValue(&av);
    var redirs = execplan.makeTaggedNil(v);
    g.rootPushValue(&redirs);
    const sub = execplan.makeTaggedNil(v);
    g.rootPop();
    g.rootPop();
    return tlist3Z(v, av, redirs, sub);
}

/// Cmd = [argv Redirs ()] (zinctest.c tcmd_r_); redirs pre-built.
fn tcmdRZ(v: *state.Vm, argv: []const []const u8, redirs: types.Value) types.Value {
    const g = v.gc;
    var rv = redirs;
    g.rootPushValue(&rv);
    var av = targvZ(v, argv);
    g.rootPushValue(&av);
    const sub = execplan.makeTaggedNil(v);
    g.rootPop();
    g.rootPop();
    return tlist3Z(v, av, rv, sub);
}

/// Redirs = [[op fd target]] (one-element redirect list, zinctest.c tredir_).
fn tredirZ(v: *state.Vm, op: types.Value, fd: types.Value, target: types.Value) types.Value {
    const r = tlist3Z(v, op, fd, target);
    var rv = r;
    v.gc.rootPushValue(&rv);
    const out = tlist1Z(v, rv);
    v.gc.rootPop();
    return out;
}

/// Chain = [op pipe] (zinctest.c tchain_).
fn tchainZ(v: *state.Vm, op: []const u8, pipe: types.Value) types.Value {
    const g = v.gc;
    var pv = pipe;
    g.rootPushValue(&pv);
    const o = tsymZ(v, op);
    g.rootPop();
    return tlist2Z(v, o, pv);
}

/// Program = [[seq [cmd]]] — single chain, single plain command (tplan1_).
fn tplan1Z(v: *state.Vm, argv: []const []const u8) types.Value {
    const g = v.gc;
    var cmd = tcmdZ(v, argv);
    g.rootPushValue(&cmd);
    var pipe = tlist1Z(v, cmd);
    g.rootPushValue(&pipe);
    const chain = tchainZ(v, "seq", pipe);
    g.rootPop();
    g.rootPop();
    var cv = chain;
    g.rootPushValue(&cv);
    const out = tlist1Z(v, cv);
    g.rootPop();
    return out;
}

/// Cmd = [[] [] Program] — a subshell command carrying a nested program.
/// `sub` must be a caller-rooted slot (read through the root AFTER the nils).
fn tcmdSubZ(v: *state.Vm, sub: *types.Value) types.Value {
    const g = v.gc;
    var av = execplan.makeTaggedNil(v);
    g.rootPushValue(&av);
    var redirs = execplan.makeTaggedNil(v);
    g.rootPushValue(&redirs);
    const r = tlist3Z(v, av, redirs, sub.*);
    g.rootPop();
    g.rootPop();
    return r;
}

// ---- tagged-list walkers (pure reads, no allocation) ----

/// Head of a 3-element tagged cons cell [cons H T].
fn tgHead(v: types.Value) types.Value {
    const wrapper = v.payload.cons.cdr.?.*;
    return wrapper.payload.cons.car.?.*;
}

/// Tail of a 3-element tagged cons cell (the wrapped T).
fn tgTail(v: types.Value) types.Value {
    const wrapper = v.payload.cons.cdr.?.*;
    const singleton = wrapper.payload.cons.cdr.?.*;
    return singleton.payload.cons.car.?.*;
}

/// [cons] (empty tagged list) detector.
fn tgIsEmpty(v: types.Value) bool {
    return v.payload.cons.cdr.?.*.tag == .nil;
}

/// Unpack a TAGGED exec-plan result [code out err] (borrowed slices).
/// The result is the tagged-tree encoding (zincvm.c:2145 final =
/// make_tagged_cons(make_tagged_number(code), ...)), so each element is
/// ITSELF a [number N]/[string S] 3-element tagged wrapper — unwrap it with
/// tgHead to reach the raw number/string value.
const Ep = struct { code: i64, out: []const u8, err: []const u8 };

fn epUnpack(v: types.Value) Ep {
    const code = tgHead(tgHead(v));
    const p1 = tgTail(v);
    const out = tgHead(tgHead(p1));
    const p2 = tgTail(p1);
    const err = tgHead(tgHead(p2));
    return .{ .code = code.payload.number, .out = values.strSlice(out), .err = values.strSlice(err) };
}

/// Run a bytecode source through the eval loop and unpack the tagged result.
fn epRun(g: *heap.Gc, v: *state.Vm, src: [:0]const u8) !Ep {
    const r = try expectRunVal(g, v, src);
    return epUnpack(r);
}

fn epExpect(g: *heap.Gc, v: *state.Vm, src: [:0]const u8, code: i64, out: []const u8, err: []const u8) !void {
    const got = try epRun(g, v, src);
    try std.testing.expectEqual(code, got.code);
    try std.testing.expectEqualStrings(out, got.out);
    try std.testing.expectEqualStrings(err, got.err);
}

test "M3 zinctest 41: getcwd" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const r = try expectRunVal(&g, &v, "(mg[6:s]getcwdp)");
    try std.testing.expectEqual(types.ValTag.string, r.tag);
    const s = values.strSlice(r);
    try std.testing.expect(s.len > 0);
    try std.testing.expect(s[0] == '/');
}

test "M3 zinctest 42: cd /tmp + getcwd roundtrip" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const saved = try cwdAlloc();
    defer chdirZ(saved);
    try expectRunStr(&g, &v, "(mS[4:S]/tmpg[2:s]cdpmg[6:s]getcwdp)", "/tmp");
    // cd returns true
    try expectRunBool(&g, &v, "(mS[4:S]/tmpg[2:s]cdp)", true);
}

test "M3 zinctest 43: glob on a temp dir (star, bracket, dotfile, nomatch)" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // Deterministic fixture dir (C globs *.c in the repo root; the temp dir
    // avoids coupling the test to the source tree contents).
    globFixture();
    const saved = try cwdAlloc();
    defer chdirZ(saved);
    chdirZ("/tmp/zig-m3-glob");

    try globExpect(&g, &v, "*.txt", &.{ ".dot.txt", "a.txt", "b.txt" }); // C parity: dotfiles DO match * patterns (the guard only covers "." / "..")
    try globExpect(&g, &v, "[ab].txt", &.{ "a.txt", "b.txt" }); // real libc fnmatch brackets
    // '?' matches exactly ONE character (fnmatch, no FNM_PERIOD): only the
    // 5-char names match; 8-char .dot.txt cannot.  (Dotfiles still match
    // '?' — a file named ".x" would match "?.x" — the length rules it out
    // here, not the leading dot.)
    try globExpect(&g, &v, "?.txt", &.{ "a.txt", "b.txt" });
    try globExpect(&g, &v, "*.log", &.{"other.log"});
    try globExpect(&g, &v, "nomatch.xyz", &.{});
    // C quirk kept: a leading '/' makes dir="" and opendir("") fails -> nil.
    try globExpect(&g, &v, "/nomatch-*.txt", &.{});
}

fn globExpect(g: *heap.Gc, v: *state.Vm, pattern: []const u8, want: []const []const u8) !void {
    var buf: [256]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&buf, "(mS[{d}:S]{s}g[4:s]globp)", .{ pattern.len, pattern });
    const r = try expectRunVal(g, v, src);
    var cur = r;
    var i: usize = 0;
    while (!tgIsEmpty(cur)) : (i += 1) {
        try std.testing.expect(i < want.len); // more matches than expected
        const elem = tgHead(cur); // [string S]
        const s = tgHead(elem); // the raw string Value
        try std.testing.expectEqual(types.ValTag.string, s.tag);
        try std.testing.expectEqualStrings(want[i], values.strSlice(s));
        cur = tgTail(cur);
    }
    try std.testing.expectEqual(want.len, i); // fewer matches than expected
}

test "M3 zinctest 44+45: getenv PATH, setenv/getenv roundtrip" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // 44: getenv PATH -> a (non-empty) string in the test environment.
    {
        const r = try expectRunVal(&g, &v, "(mS[4:S]PATHg[6:s]getenvp)");
        try std.testing.expectEqual(types.ValTag.string, r.tag);
        try std.testing.expect(values.strSlice(r).len > 0);
    }

    // 45: setenv NAME VAL -> true (RTL: Val pushed first, NAME last), then
    // read it back through getenv.
    try expectRunBool(&g, &v, "(mS[3:S]barS[12:S]SHENZIG_M3_Vg[6:s]setenvp)", true);
    try expectRunStr(&g, &v, "(mS[12:S]SHENZIG_M3_Vg[6:s]getenvp)", "bar");
}

test "M3 zinctest 46: exec-plan echo hi (child builtin) -> [0 hi\\n ]" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    v.defunSet("*epA*", tplan1Z(&v, &.{ "echo", "hi" }));
    try epExpect(&g, &v, "(g[5:s]*epA*P[9:s]exec-plan)", 0, "hi\n", "");
}

test "M3 zinctest 47: exec-plan pipeline echo hello | wc -c -> [0 6\\n ]" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    {
        const g_ = v.gc;
        var c1 = tcmdZ(&v, &.{ "echo", "hello" });
        g_.rootPushValue(&c1);
        var c2 = tcmdZ(&v, &.{ "wc", "-c" });
        g_.rootPushValue(&c2);
        var pipe = tlist2Z(&v, c1, c2);
        g_.rootPushValue(&pipe);
        const chain = tchainZ(&v, "seq", pipe);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        var cv = chain;
        g_.rootPushValue(&cv);
        const plan = tlist1Z(&v, cv);
        g_.rootPop();
        v.defunSet("*epB*", plan);
    }
    try epExpect(&g, &v, "(g[5:s]*epB*P[9:s]exec-plan)", 0, "6\n", "");
}

test "M3 zinctest 48: exec-plan chains false || echo yes -> [0 yes\\n ]" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    {
        const g_ = v.gc;
        var c1 = tcmdZ(&v, &.{"false"});
        g_.rootPushValue(&c1);
        var p1 = tlist1Z(&v, c1);
        g_.rootPushValue(&p1);
        var ch1 = tchainZ(&v, "seq", p1);
        g_.rootPushValue(&ch1);
        var c2 = tcmdZ(&v, &.{ "echo", "yes" });
        g_.rootPushValue(&c2);
        var p2 = tlist1Z(&v, c2);
        g_.rootPushValue(&p2);
        var ch2 = tchainZ(&v, "or", p2);
        g_.rootPushValue(&ch2);
        const plan = tlist2Z(&v, ch1, ch2);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        v.defunSet("*epC*", plan);
    }
    try epExpect(&g, &v, "(g[5:s]*epC*P[9:s]exec-plan)", 0, "yes\n", "");
}

test "M3 zinctest 49+50: exec-plan redirect out > file, then cat it back" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    {
        const g_ = v.gc;
        var op = tsymZ(&v, "out");
        g_.rootPushValue(&op);
        var fd = execplan.makeTaggedNumber(&v, 1);
        g_.rootPushValue(&fd);
        const tgt = execplan.makeTaggedString(&v, "/tmp/zig-m3-redir.txt");
        g_.rootPop();
        g_.rootPop();
        var redirs = tredirZ(&v, op, fd, tgt);
        g_.rootPushValue(&redirs);
        var cmd = tcmdRZ(&v, &.{ "echo", "hi" }, redirs);
        g_.rootPushValue(&cmd);
        var pipe = tlist1Z(&v, cmd);
        g_.rootPushValue(&pipe);
        var chain = tchainZ(&v, "seq", pipe);
        g_.rootPushValue(&chain);
        const plan = tlist1Z(&v, chain);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        v.defunSet("*epD*", plan);
    }
    // stdout goes to the file, not the capture
    try epExpect(&g, &v, "(g[5:s]*epD*P[9:s]exec-plan)", 0, "", "");

    // 50: cat reads back what 49 wrote — proves the redirect took effect.
    v.defunSet("*epE*", tplan1Z(&v, &.{ "cat", "/tmp/zig-m3-redir.txt" }));
    try epExpect(&g, &v, "(g[5:s]*epE*P[9:s]exec-plan)", 0, "hi\n", "");
}

test "M3 zinctest 51: exec-plan dup 1>&2 -> [0 duped\\n on stderr]" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    {
        const g_ = v.gc;
        var op = tsymZ(&v, "dup");
        g_.rootPushValue(&op);
        var fd = execplan.makeTaggedNumber(&v, 1);
        g_.rootPushValue(&fd);
        const tgt = execplan.makeTaggedNumber(&v, 2);
        g_.rootPop();
        g_.rootPop();
        var redirs = tredirZ(&v, op, fd, tgt);
        g_.rootPushValue(&redirs);
        var cmd = tcmdRZ(&v, &.{ "echo", "duped" }, redirs);
        g_.rootPushValue(&cmd);
        var pipe = tlist1Z(&v, cmd);
        g_.rootPushValue(&pipe);
        var chain = tchainZ(&v, "seq", pipe);
        g_.rootPushValue(&chain);
        const plan = tlist1Z(&v, chain);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        v.defunSet("*epF*", plan);
    }
    try epExpect(&g, &v, "(g[5:s]*epF*P[9:s]exec-plan)", 0, "", "duped\n");
}

test "M3 zinctest 52: exec-plan ENOENT -> 127 + shensh: not found" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    v.defunSet("*epG*", tplan1Z(&v, &.{"definitely-no-such-cmd-xyzzy"}));
    try epExpect(&g, &v, "(g[5:s]*epG*P[9:s]exec-plan)", 127, "", "shensh: definitely-no-such-cmd-xyzzy: not found\n");
}

test "M3 gate: redirect ordering 2>&1 >file leaves stderr on the capture" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    {
        const g_ = v.gc;
        // redirs [[dup 2 1] [out 1 file]] — dup FIRST so fd2 snapshots the
        // capture fd (the old stdout); then >file moves only fd1 (POSIX
        // ordering).  Each redir is a BARE 3-element vector [op fd target]
        // built with tlist3Z — tredirZ would wrap each in its own 1-element
        // REDIRS list and the decoder would reject the nested shape.
        // [dup F T] means dup2(T, F): fd F becomes a copy of fd T, so
        // [dup 2 1] IS `2>&1` (C zinctest 51 uses [dup 1 2] for `1>&2`).
        var opd = tsymZ(&v, "dup");
        g_.rootPushValue(&opd);
        var fd2v = execplan.makeTaggedNumber(&v, 2);
        g_.rootPushValue(&fd2v);
        const tgt1 = execplan.makeTaggedNumber(&v, 1);
        g_.rootPop();
        g_.rootPop();
        var r1 = tlist3Z(&v, opd, fd2v, tgt1); // [dup 2 1] — 2>&1
        g_.rootPushValue(&r1);
        var opo = tsymZ(&v, "out");
        g_.rootPushValue(&opo);
        var fd1b = execplan.makeTaggedNumber(&v, 1);
        g_.rootPushValue(&fd1b);
        const tgtf = execplan.makeTaggedString(&v, "/tmp/zig-m3-ord.txt");
        g_.rootPop();
        g_.rootPop();
        const r2 = tlist3Z(&v, opo, fd1b, tgtf); // [out 1 file]
        // r1 is still rooted (its slot is top again after the fd1b/opo
        // pops); pair it with r2 BEFORE dropping the root — tlist2Z copies
        // its args by value into its own rooted locals first.
        var redirs = tlist2Z(&v, r1, r2); // [[dup 2 1] [out 1 file]]
        g_.rootPop(); // r1
        g_.rootPushValue(&redirs);
        var cmd = tcmdRZ(&v, &.{ "ls", "/definitely-missing-zig-m3" }, redirs);
        g_.rootPushValue(&cmd);
        var pipe = tlist1Z(&v, cmd);
        g_.rootPushValue(&pipe);
        var chain = tchainZ(&v, "seq", pipe);
        g_.rootPushValue(&chain);
        const plan = tlist1Z(&v, chain);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        v.defunSet("*epOrd*", plan);
    }
    const got = try epRun(&g, &v, "(g[7:s]*epOrd*P[9:s]exec-plan)");
    try std.testing.expectEqual(@as(i64, 2), got.code); // GNU ls: 2 for a missing operand
    // POSIX ordering: the dup ran FIRST, so fd2 snapshots the OLD stdout (the
    // out capture) - ls's error message lands in OUT, not err; fd1 then moves
    // to the file (verified by the echo/cat check below, e2e plan F.5).
    try std.testing.expect(got.out.len > 0); // stderr followed the old stdout
    try std.testing.expect(std.mem.indexOf(u8, got.out, "definitely-missing-zig-m3") != null);
    try std.testing.expectEqualStrings("", got.err); // fd2 no longer points at the err capture (dup moved it to old stdout)

    // e2e parity (plan F.5): `echo x 2>&1 >file; cat file` - the dup
    // snapshots the capture stdout, stdout itself goes to the file, so the
    // echo contributes NOTHING to the capture and the cat reads x back
    // exactly once.
    {
        const g_ = v.gc;
        var opd = tsymZ(&v, "dup");
        g_.rootPushValue(&opd);
        var fd2v = execplan.makeTaggedNumber(&v, 2);
        g_.rootPushValue(&fd2v);
        const tgt1 = execplan.makeTaggedNumber(&v, 1);
        g_.rootPop();
        g_.rootPop();
        var r1 = tlist3Z(&v, opd, fd2v, tgt1); // [dup 2 1] - 2>&1
        g_.rootPushValue(&r1);
        var opo = tsymZ(&v, "out");
        g_.rootPushValue(&opo);
        var fd1b = execplan.makeTaggedNumber(&v, 1);
        g_.rootPushValue(&fd1b);
        const tgtf = execplan.makeTaggedString(&v, "/tmp/zig-m3-ord2.txt");
        g_.rootPop();
        g_.rootPop();
        const r2 = tlist3Z(&v, opo, fd1b, tgtf); // [out 1 file]
        var redirs = tlist2Z(&v, r1, r2);
        g_.rootPop(); // r1
        g_.rootPushValue(&redirs);
        var cmd = tcmdRZ(&v, &.{ "echo", "x" }, redirs);
        g_.rootPushValue(&cmd);
        var pipe = tlist1Z(&v, cmd);
        g_.rootPushValue(&pipe);
        var ch1 = tchainZ(&v, "seq", pipe);
        g_.rootPushValue(&ch1);
        var ccmd = tcmdZ(&v, &.{ "cat", "/tmp/zig-m3-ord2.txt" });
        g_.rootPushValue(&ccmd);
        var cpipe = tlist1Z(&v, ccmd);
        g_.rootPushValue(&cpipe);
        var ch2 = tchainZ(&v, "seq", cpipe);
        g_.rootPushValue(&ch2);
        const plan2 = tlist2Z(&v, ch1, ch2);
        g_.rootPop(); // ch2
        g_.rootPop(); // cpipe
        g_.rootPop(); // ccmd
        g_.rootPop(); // ch1
        g_.rootPop(); // pipe
        g_.rootPop(); // cmd
        g_.rootPop(); // redirs
        v.defunSet("*epOrd2*", plan2);
    }
    try epExpect(&g, &v, "(g[8:s]*epOrd2*P[9:s]exec-plan)", 0, "x\n", "");
}

test "M3 gate: subshell (cd /tmp; pwd) isolates the cd" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const before = try cwdAlloc();
    defer chdirZ(before);

    {
        const g_ = v.gc;
        // program: [seq [cd /tmp]] [seq [pwd]]  (two chains)
        var p1 = tlist1Z(&v, tcmdZ(&v, &.{ "cd", "/tmp" }));
        g_.rootPushValue(&p1);
        var ch1 = tchainZ(&v, "seq", p1);
        g_.rootPushValue(&ch1);
        var p2 = tlist1Z(&v, tcmdZ(&v, &.{"pwd"}));
        g_.rootPushValue(&p2);
        var ch2 = tchainZ(&v, "seq", p2);
        g_.rootPushValue(&ch2);
        var prog = tlist2Z(&v, ch1, ch2);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();

        // cmd = [[] [] prog]; plan = [[seq [cmd]]] — prog stays rooted until
        // tcmdSubZ has consumed it (it allocates before reading sub.*).
        g_.rootPushValue(&prog);
        var cmd = tcmdSubZ(&v, &prog);
        g_.rootPushValue(&cmd);
        var pipe = tlist1Z(&v, cmd);
        g_.rootPushValue(&pipe);
        var chain = tchainZ(&v, "seq", pipe);
        g_.rootPushValue(&chain);
        const plan = tlist1Z(&v, chain);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop(); // prog
        v.defunSet("*epSub*", plan);
    }
    try epExpect(&g, &v, "(g[7:s]*epSub*P[9:s]exec-plan)", 0, "/tmp\n", "");

    // The subshell's cd must NOT leak into the parent process.
    const after = try cwdAlloc();
    try std.testing.expectEqualStrings(before, after);
}

test "M3 gate: heredoc/herestring redir feeds stdin via unlinked tmpfile" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    {
        const g_ = v.gc;
        var op = tsymZ(&v, "hstr");
        g_.rootPushValue(&op);
        var fd = execplan.makeTaggedNumber(&v, 0);
        g_.rootPushValue(&fd);
        const tgt = execplan.makeTaggedString(&v, "hello hstr");
        g_.rootPop();
        g_.rootPop();
        var redirs = tredirZ(&v, op, fd, tgt);
        g_.rootPushValue(&redirs);
        var cmd = tcmdRZ(&v, &.{"cat"}, redirs);
        g_.rootPushValue(&cmd);
        var pipe = tlist1Z(&v, cmd);
        g_.rootPushValue(&pipe);
        var chain = tchainZ(&v, "seq", pipe);
        g_.rootPushValue(&chain);
        const plan = tlist1Z(&v, chain);
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        g_.rootPop();
        v.defunSet("*epHstr*", plan);
    }
    // decode_redir appends the trailing \n hstr semantics require
    try epExpect(&g, &v, "(g[8:s]*epHstr*P[9:s]exec-plan)", 0, "hello hstr\n", "");
}

test "M3 gate: wait returns the child's exit code; kill -> 128+sig" {
    var g = try testInit();
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // wait: fork -> child _exit(42) -> primWait reports 42.
    {
        const pid = execplan.testFork();
        try std.testing.expect(pid != -1);
        if (pid == 0) execplan.testExit(42);
        var acc: types.Value = values.valNil();
        try primExec(&g, &v, "wait", &.{values.valNumber(pid)}, &acc);
        try std.testing.expectEqual(types.ValTag.number, acc.tag);
        try std.testing.expectEqual(@as(i64, 42), acc.payload.number);
    }

    // kill: fork -> child sleeps 30s -> SIGKILL (9) -> wait -> 128+9 = 137.
    {
        const pid = execplan.testFork();
        try std.testing.expect(pid != -1);
        if (pid == 0) {
            // The child never touches the GC heap — it only sleeps (the
            // same discipline the runner's children follow).
            sleepSec(30);
            execplan.testExit(0);
        }
        sleepMs(100); // let the child reach nanosleep
        var kacc: types.Value = values.valNil();
        try primExec(&g, &v, "kill", &.{ values.valNumber(pid), values.valNumber(9) }, &kacc);
        try std.testing.expectEqual(types.ValTag.boolean, kacc.tag);
        var wacc: types.Value = values.valNil();
        try primExec(&g, &v, "wait", &.{values.valNumber(pid)}, &wacc);
        try std.testing.expectEqual(@as(i64, 137), wacc.payload.number);
    }
}

//! tests/bundle_test.zig — shen's BUNDLE-DEPENDENT test set (VM extraction P3).
//!
//! The package (../zinc-vm) owns the authoritative vm_test.zig/gc_test.zig
//! (101/37 tests).  These three tests are the shen-side behavioral proof that
//! the package's interp is behaviorally equivalent to shen's own: they load
//! the REAL reduced bundle (../globals.csexp, resolved relative to the build
//! root shen/zig — i.e. the repo-root bundle) and drive the eval-kl
//! compile+run chain through the package's marshal/hostcall/prims/interp.
//!
//!   M6b realBundleLoad — the 725KB bundle parses, registers >300 closures,
//!       and the shell-critical entrypoints (shen-parse-exprs, extract-kl,
//!       kl->zinc, toplevel-interp, interp-eval, tc-hm-init, shen-read-file)
//!       survive a forced scavenge + full collect as callable lambdas.
//!   M2 eval-kl zinctest parity — [+ 1 2]/[cons 1 2]/[+ [* 2 3] 4]/
//!       [cn "hello" "world"]/[hd 42]/[/ 1 0] produce exactly the C
//!       zinctest 5/11/12/13/14/14b results (numbers, dotted pairs, strings,
//!       and the two catchable error VALUES).
//!   M2 eval-kl set/value — the reduced-bundle self-hosting path: (set x "v")
//!       lands TAGGED and reads back, and the OP_PRIM eval-kl bytecode path
//!       runs under verify_collects (whole-stack precise-rooting proof).
//!
//! Each test skips cleanly (rather than failing) when ../globals.csexp is
//! absent, mirroring the pre-extraction shen vm_test.zig behaviour.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const heap = gc.heap;
const vm = @import("vm");
const values = vm.values;
const symbols = vm.symbols;
const state = vm.state;
const parser = vm.parser;
const interp = vm.interp;
const prims = vm.prims;

// =====================================================================
//  helpers (verbatim from the pre-extraction shen tests/vm_test.zig)
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

/// primExec's rooting-safe variant for the eval-kl chain: roots the ARG SLOT
/// itself (not a caller-copied slice) so a scavenge during vaInit/vaPush can
/// never push a stale interior pointer.  The arg value is re-read through the
/// root at push time (post-GC fresh).
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

// =====================================================================
//  M6b — real-bundle load canary (../globals.csexp)
// =====================================================================

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
//  M2 — eval-kl on the real bundle
// =====================================================================

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

//! src/wasm_main.zig — the wasm32-freestanding front-end (milestone M2).
//!
//! C origin: shell/wasm/wasm-main.c — the re-entrant line-eval entrypoint
//! for the Shen VM compiled to WebAssembly (wasm32-freestanding).  The
//! native shensh main() drives a BLOCKING REPL that loops on read(stdin);
//! blocking reads do not work in a browser.  This module instead exposes a
//! synchronous, re-entrant shen_eval_line() that runs the meta REPL's
//! per-line loop body ONCE, so a JS driver (xterm.js onData on Enter) can
//! push input and pull output without ever blocking.
//!
//! FREESTANDING: no std.process, no std.io buffered I/O, no libc, no
//! std.fmt (std.fmt → std.Io.Writer → std.Io.Threaded → getrandom on
//! freestanding).  The only std facilities used are:
//!   - std.mem.sliceTo / std.ascii.isWhitespace / std.mem.eql (pure)
//!   - std.heap.page_allocator (wasm WasmPageAllocator — memory.grow backed)
//! Number rendering uses a manual i64→decimal converter (formatI64).
//!
//! PANIC OVERRIDE: the deprecated 3-param form
//!   `pub const panic = struct { pub fn call(...) noreturn {...} }.call;`
//! makes `@TypeOf(root.panic) != type`, so std.builtin.zig:1223-1229 takes
//! the deprecated branch and wraps root.panic in FullPanic.  The wrapper
//! calls `root.panic(msg, @errorReturnTrace(), ra)` — 3rd param is `?usize`
//! (verified std/builtin.zig:1223 + std/debug.zig:97 FullPanic signature).
//! FullPanic's safety panics (outOfBounds etc.) go through panicExtra which
//! uses a fixed stack buffer (Writer.fixed) and then .call — no std.Io.File,
//! no getrandom.  The handler itself is `while (true) {}` (a trap would
//! crash the wasm instance unrecoverably; a hang lets the JS host detect
//! and report).
//!
//! ROOTING: mirrors shensh_main.zig's evalKlambdaLine — `parsed` is rooted
//! across the catching parse; `cur` (the exprs list cursor) is rooted across
//! the WHOLE per-form loop (the C wasm-main.c does NOT root `cur`, a latent
//! stale-pointer bug on a moving GC; the Zig port fixes it); `result` is
//! rooted per-form.  hostcall.callBundled0/1/3 (catching) and
//! prims.execPrimitive are reused verbatim from the VM module — on wasm32
//! the rooting discipline is identical (precise shadow stack, usize-generic).
//!
//! BUNDLE: @embedFile("../../globals.csexp") bakes the 725KB csexp bundle
//! into the data section at compile time.  No MEMFS, no WASI, no emscripten
//! --embed-file — the bytes feed directly to Vm.loadBundle at boot.  A
//! comptime sentinel (trailing 0) is appended so the bundle meets the
//! `[:0]const u8` contract of loadBundle's whitespace scan.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const heap = gc.heap;
const vm_mod = @import("vm");

const values = vm_mod.values;
const state = vm_mod.state;
const prims = vm_mod.prims;
const hostcall = vm_mod.hostcall;
const streams = vm_mod.streams;

const Value = types.Value;
const Vm = state.Vm;
const ValueArray = types.ValueArray;

// =====================================================================
//  Embedded bundle — globals.csexp at repo root
// =====================================================================

/// `@embedFile("globals.csexp")` — the bundle must be copied into zig/src/
/// before building (the repo-root globals.csexp is outside the package
/// path and cannot be @embedFile'd directly).  See build.zig addWasmExe.
/// No MEMFS, no WASI — the bytes feed directly to Vm.loadBundle at boot.
const BUNDLE_RAW = @embedFile("globals.csexp");

/// `[:0]const u8` with a comptime-appended sentinel so the bundle meets
/// loadBundle's `[:0]const u8` contract.  The comptime array lives in
/// rodata; no runtime allocation.
///
/// FIX (M2): a `[:0]` slice can NOT point into a comptime-LOCAL buffer
/// (`global variable contains reference to comptime var`).  Declare the
/// sentinel-terminated data as a global ARRAY (comptime-constructed via a
/// `blk:` block), then slice it — the slice then refers to global storage,
/// not a comptime stack variable.
const BUNDLE_STORAGE: [BUNDLE_RAW.len + 1:0]u8 = blk: {
    var b: [BUNDLE_RAW.len + 1:0]u8 = undefined;
    @memcpy(b[0..BUNDLE_RAW.len], BUNDLE_RAW);
    b[BUNDLE_RAW.len] = 0;
    break :blk b;
};
const BUNDLE: [:0]const u8 = BUNDLE_STORAGE[0..BUNDLE_RAW.len :0];

// =====================================================================
//  pub panic — freestanding override (no std.Io/getrandom)
// =====================================================================

/// Deprecated 3-param form: assigning `.call` (a function, not a namespace)
/// makes `@TypeOf(root.panic) != type` → std.builtin.zig:1223 takes the
/// deprecated branch → FullPanic wrapper calls
/// `root.panic(msg, @errorReturnTrace(), ra)`.  2nd param is
/// `?*std.builtin.StackTrace` (from @errorReturnTrace()), 3rd is `?usize`.
pub const panic = struct {
    pub fn call(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
        while (true) {}
    }
}.call;

// =====================================================================
//  Globals — the VM + boot state (module-singleton, idempotent boot)
// =====================================================================

var g: heap.Gc = undefined;
var vm_inst: Vm = undefined;
var booted: bool = false;
var boot_ok: bool = false;

// =====================================================================
//  shen_boot — idempotent VM boot (exported)
// =====================================================================

/// Boot the VM: Gc.init(256MB, no 4GB reserve on wasm) → Vm.init →
/// loadBundle(embedded globals.csexp) → callBundled0("tc-hm-init").
/// Idempotent: returns 1 if booted OK, 0 on failure.  NO shell/*.shen
/// loads (a browser has no filesystem).
export fn shen_boot() c_int {
    if (booted) return if (boot_ok) 1 else 0;
    booted = true;

    g = heap.Gc.init(.{
        .heap_bytes = 256 * 1024 * 1024,
        // reserve_bytes = null → on wasm the page_allocator backs the heap
        // at exactly heap_bytes (no 4GB over-reserve); on native the default
        // reserve math runs (but this code only runs on wasm in production).
    }) catch {
        boot_ok = false;
        return 0;
    };
    vm_inst.init(&g);

    const loaded = vm_inst.loadBundle(BUNDLE);
    if (loaded == 0) {
        boot_ok = false;
        return 0;
    }

    // tc-hm-init: build the HM sig table + prim table.  Missing/failed
    // init is non-fatal (the shensh front-end warns and continues).
    _ = hostcall.callBundled0(&vm_inst, "tc-hm-init");

    boot_ok = true;
    return 1;
}

// =====================================================================
//  shen_eval_line — evaluate one line of KLambda (exported)
// =====================================================================

/// Evaluate ONE line of KLambda text (the meta REPL loop body, once).
///   line    — NUL-terminated KLambda text (e.g. "(+ 1 2)")
///   out     — caller-provided output buffer (at least outcap bytes)
///   outcap  — size of out
/// Returns the number of chars written into out (excluding the NUL
/// terminator), or -1 on a fatal error (boot failure).  Parse failure is
/// NOT fatal — it is reported in-band via "parse error: ..." text.
///
/// Mirrors shell/wasm/wasm-main.c:222-308 (shen_eval_line), but with
/// CORRECT rooting of `cur` across the per-form loop (the C code's latent
/// stale-pointer bug on a moving GC is fixed here, following
/// shensh_main.zig:evalKlambdaLine's pattern).
export fn shen_eval_line(line: [*:0]const u8, out: [*]u8, outcap: c_int) c_int {
    // Ensure booted (idempotent — mirrors C's ensure_boot()).
    if (!booted) {
        if (shen_boot() == 0) {
            if (outcap > 0) out[0] = 0;
            return -1;
        }
    }
    if (!boot_ok) {
        if (outcap > 0) out[0] = 0;
        return -1;
    }
    if (outcap <= 0) return -1;
    out[0] = 0;

    const vm = &vm_inst;
    const g_ptr = vm.gc;
    const cap: usize = @intCast(outcap);

    // Get the line as a bounded slice (NUL-terminated pointer → slice).
    const line_slice = std.mem.sliceTo(line, 0);

    // Skip blank / whitespace-only lines (matches C wasm-main.c:232-235).
    var only_ws = true;
    for (line_slice) |c| {
        if (!std.ascii.isWhitespace(c)) {
            only_ws = false;
            break;
        }
    }
    if (only_ws) return 0;

    // ---- Parse: callBundled3("parse-exprs", Str, Zero, Len) ----
    // C:238-256 — CatchFrame around call_closure3; the M2 catching
    // callBundled3 returns vm.err_slot on a throw.
    const str_v = values.valString(g_ptr, line_slice);
    const zero = values.valNumber(0);
    const len_v = values.valNumber(@intCast(line_slice.len));

    var parsed = hostcall.callBundled3(vm, "parse-exprs", str_v, zero, len_v);
    g_ptr.rootPushValue(&parsed);

    var pos: usize = 0;

    // Parse error: parsed is not [[Expr|Rest] FinalPos] (not a cons, or
    // its car is not a cons).  Report in-band and return.
    if (parsed.tag != .cons or parsed.payload.cons.car.?.tag != .cons) {
        appendStr(out, outcap, &pos, "parse error: ");
        renderValue(out, outcap, &pos, parsed, 0);
        if (pos < cap) out[pos] = 0;
        g_ptr.rootPop(); // parsed
        return @intCast(pos);
    }

    // hd of [[Expr|Rest] FinalPos] — the list of parsed forms.
    const exprs = parsed.payload.cons.car.?.*;
    g_ptr.rootPop(); // parsed — cur gets its own root before any allocation

    // ---- Per-form loop (rooted) ----
    var cur = exprs;
    g_ptr.rootPushValue(&cur);

    while (cur.tag == .cons and pos < cap - 1) {
        const expr = cur.payload.cons.car.?.*;
        const is_defun = isDefunForm(expr);

        var result = values.valNil();
        g_ptr.rootPushValue(&result);

        if (is_defun) {
            // C:277-278 — interp-eval registers the defun into namespace 2.
            // callBundled1 is catching: a throw returns vm.err_slot (the
            // error value), caught as result.tag == .error_.
            result = hostcall.callBundled1(vm, "interp-eval", expr);
        } else {
            // C:279-286 — eval-kl via exec_primitive.  The form is rooted
            // across the 1-slot ValueArray alloc and the eval-kl chain.
            result = evalKl(vm, expr);
        }

        if (is_defun) {
            if (result.tag == .symbol) {
                appendStr(out, outcap, &pos, "; registered ");
                renderValue(out, outcap, &pos, result, 0);
            } else {
                appendStr(out, outcap, &pos, "; defun registration failed: ");
                renderValue(out, outcap, &pos, result, 0);
            }
        } else {
            renderValue(out, outcap, &pos, result, 0);
        }

        g_ptr.rootPop(); // result
        cur = cur.payload.cons.cdr.?.*;
    }

    g_ptr.rootPop(); // cur

    // NUL-terminate for the JS host (C does not, but JS reads C-strings).
    if (pos < cap) out[pos] = 0;
    return @intCast(pos);
}

// =====================================================================
//  shen_take_out — drain the wasm output buffer (exported)
// =====================================================================

/// Drain the M1 streams.zig wasm_out ring buffer to a caller-provided
/// buffer.  write-byte on fd 1 (*stoutput*) appends to wasm_out on wasm
/// (M1 streams gate); this pulls the accumulated output so JS can display
/// it after each eval_line.  Returns the number of bytes copied.
export fn shen_take_out(out: [*]u8, cap: c_int) c_int {
    return streams.drainWasmOut(out, cap);
}

// =====================================================================
//  shen_alloc / shen_free — JS memory allocation (exported, for M3)
// =====================================================================

/// Allocate `n` bytes in wasm linear memory and return a pointer.  This
/// lets the JS driver allocate line buffers and output buffers in wasm
/// memory (the emscripten _malloc replacement).  On wasm the
/// page_allocator is WasmPageAllocator (memory.grow backed); frees are
/// no-ops (wasm memory cannot shrink), which is fine for a REPL's small
/// infrequent allocations.  Returns 0 (null) on failure.
export fn shen_alloc(n: usize) ?[*]u8 {
    const buf = std.heap.page_allocator.alloc(u8, n) catch return null;
    return buf.ptr;
}

/// Free a previously shen_alloc'd buffer.  On wasm this is a no-op
/// (memory cannot shrink); the pages stay committed.  `n` must match the
/// original allocation size (page_allocator.free requires the exact slice).
export fn shen_free(ptr: [*]u8, n: usize) void {
    std.heap.page_allocator.free(ptr[0..n]);
}

// =====================================================================
//  Internal helpers
// =====================================================================

/// Is a parsed form a (defun ...) definition?
/// C: wasm-main.c:170-174 wasm_is_defun_form.
fn isDefunForm(f: Value) bool {
    if (f.tag != .cons) return false;
    const h = f.payload.cons.car.?.*;
    return h.tag == .symbol and std.mem.eql(u8, values.symSlice(h), "defun");
}

/// Evaluate a KLambda form via the eval-kl primitive (namespace 2
/// resolution).  The form is rooted across the 1-slot ValueArray alloc and
/// the eval-kl chain (which allocates: extract-kl → kl->zinc →
/// toplevel-interp).  Mirrors shensh_main.zig:evalKlForm.
/// C: wasm-main.c:279-286 (wasm_va_init + wasm_va_push + exec_primitive +
/// wasm_va_free).
fn evalKl(vm: *Vm, form: Value) Value {
    const g_ptr = vm.gc;
    var f = form;
    g_ptr.rootPushValue(&f);
    var s: ValueArray = .{ .data = g_ptr.allocArray(Value, 1), .len = 0, .cap = 1 };
    s.data.?[0] = f;
    s.len = 1;
    var acc: Value = values.valNil();
    prims.execPrimitive(vm, "eval-kl", &acc, &s) catch {};
    g_ptr.rootPop(); // f
    return acc;
}

/// Append a string literal to the out buffer, clamped to capacity.
/// Mirrors C wasm_sv_append's clamp: advances pos by the ACTUAL bytes
/// written (min(s.len, room)), not the would-be length.
fn appendStr(out: [*]u8, outcap: c_int, pos: *usize, s: []const u8) void {
    const cap: usize = @intCast(outcap);
    if (pos.* >= cap) return;
    const room = cap - pos.*;
    const n = @min(s.len, room);
    if (n > 0) @memcpy(out[pos.*..][0..n], s[0..n]);
    pos.* += n;
}

/// Render a Value (str_value form: [a b c] lists, depth-100 cap) into the
/// out buffer at the current position.  Self-contained — does NOT use
/// std.Io.Writer or std.fmt (both pull std.Io.Threaded → getrandom on
/// freestanding).  Mirrors C wasm-main.c:wasm_str_value and the Zig
/// values.strValue tag-by-tag, but writes directly into the out buffer via
/// appendStr + formatI64.
fn renderValue(out: [*]u8, outcap: c_int, pos: *usize, v: Value, depth: u32) void {
    if (depth > 100) {
        appendStr(out, outcap, pos, "...");
        return;
    }
    switch (v.tag) {
        .symbol => appendStr(out, outcap, pos, values.symSlice(v)),
        .string => {
            appendStr(out, outcap, pos, "\"");
            appendStr(out, outcap, pos, values.strSlice(v));
            appendStr(out, outcap, pos, "\"");
        },
        .number => {
            var nbuf: [32]u8 = undefined;
            appendStr(out, outcap, pos, formatI64(&nbuf, v.payload.number));
        },
        .boolean => appendStr(out, outcap, pos, if (v.payload.boolean != 0) "true" else "false"),
        .nil => appendStr(out, outcap, pos, "[]"),
        .cons => {
            appendStr(out, outcap, pos, "[");
            var cur: *const Value = &v;
            var first = true;
            while (cur.tag == .cons) : (cur = cur.payload.cons.cdr.?) {
                if (!first) appendStr(out, outcap, pos, " ");
                first = false;
                renderValue(out, outcap, pos, cur.payload.cons.car.?.*, depth + 1);
            }
            if (cur.tag != .nil) {
                appendStr(out, outcap, pos, " . ");
                renderValue(out, outcap, pos, cur.*, depth + 1);
            }
            appendStr(out, outcap, pos, "]");
        },
        .error_ => {
            appendStr(out, outcap, pos, "<error ");
            appendStr(out, outcap, pos, values.errSlice(v));
            appendStr(out, outcap, pos, ">");
        },
        .lambda => appendStr(out, outcap, pos, "<lambda>"),
        .prim => {
            appendStr(out, outcap, pos, "<prim ");
            appendStr(out, outcap, pos, values.primSlice(v));
            appendStr(out, outcap, pos, ">");
        },
        .vector => {
            appendStr(out, outcap, pos, "<vector ");
            var nbuf: [32]u8 = undefined;
            appendStr(out, outcap, pos, formatI64(&nbuf, @intCast(v.payload.vector.len)));
            appendStr(out, outcap, pos, ">");
        },
        .stream => appendStr(out, outcap, pos, "<stream>"),
        else => appendStr(out, outcap, pos, "<unknown>"),
    }
}

/// Manual i64 → decimal string (no std.fmt, which pulls std.Io on
/// freestanding).  Handles INT64_MIN via wrapping negation of the unsigned
/// representation.  Writes into `buf` (must be ≥ 21 bytes) and returns the
/// written slice.
fn formatI64(buf: []u8, n: i64) []const u8 {
    if (n == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var pos: usize = 0;
    var num: u64 = undefined;
    if (n < 0) {
        buf[pos] = '-';
        pos += 1;
        // |n| via wrapping negation of the unsigned representation —
        // handles INT64_MIN where -n would overflow.
        num = -% @as(u64, @bitCast(n));
    } else {
        num = @intCast(n);
    }
    var rev: [20]u8 = undefined;
    var rlen: usize = 0;
    while (num > 0) {
        rev[rlen] = '0' + @as(u8, @intCast(num % 10));
        rlen += 1;
        num /= 10;
    }
    while (rlen > 0 and pos < buf.len) {
        rlen -= 1;
        buf[pos] = rev[rlen];
        pos += 1;
    }
    return buf[0..pos];
}

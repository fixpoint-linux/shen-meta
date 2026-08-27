//! src/vm/streams.zig — string-stream registry + the stream I/O prims
//! (write-byte, read-byte, read-file-as-string, open, close) for milestone M1.
//!
//! C origin: zincvm.c stream storage + prim cases:
//!   - string_streams / n_string_streams / val_string_stream_in :358-381
//!   - close  :1926-1937   open :2346-2363   read-byte :2382-2395
//!   - read-file-as-string :2396-2412        write-byte :2685-2690
//!
//! VALUE MODEL (port of C's FILE* + is_string juggling):
//!   - A FILE stream carries its fd as an int-in-?*anyopaque: `stream.file =
//!     @ptrFromInt(fd)`.  fd 0 (stdin) therefore round-trips as a NULL
//!     optional pointer (C's real stdin FILE* is never null, but a null file
//!     pointer is exactly what valStreamIn(null) produced before M1, and the
//!     handler treats null == fd 0).
//!   - A STRING stream carries (idx+1) as an int-in-?*anyopaque so the value 0
//!     (= null) never appears, exactly like C's `+1 so 0 = no string stream`
//!     comment (:377).  The slot data is a page_allocator buffer (non-GC), so
//!     values built from it satisfy the valString CONTRACT.
//!
//! The registry is Vm-owned (a fixed array of 8 slots + a count), mirroring
//! C's file-scope statics without hidden globals.  None of these handlers
//! GC-allocate except valString/valError results copied from C-heap buffers
//! (safe by contract); string-stream data is page_allocator.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const state = @import("state.zig");
const values = @import("values.zig");
const interp = @import("interp.zig");

const Gc = gc.Gc;
const Value = types.Value;
const ValueArray = types.ValueArray;
const Vm = state.Vm;
const VmError = state.VmError;

/// Comptime wasm gate — true on wasm32-freestanding/wasi.  The file-stream
/// prim handlers below branch on this so the std.posix calls (read/openat/
/// system.write/close) are NOT analyzed on wasm (only the taken branch is).
/// The string-stream registry path is pure (no posix) and stays active on
/// every target — the wasm VM can still string-stream.
const is_wasm = @import("builtin").cpu.arch.isWasm();

/// Diagnostic print — gated to non-freestanding targets.  std.debug.print
/// pulls std.Io (lockStderr → std.Options.debug_io) which on freestanding
/// drags in getrandom/Threaded; the noop on freestanding keeps the stream
/// diagnostics compilable without changing native behavior.
const diag = if (@import("builtin").os.tag != .freestanding) std.debug.print else struct {
    fn call(comptime _: []const u8, _: anytype) void {}
}.call;

/// WASM output drain — write-byte on fd 1 (*stoutput*) appends here on wasm
/// (there is no real fd 1 to write to under freestanding).  M2's wasm
/// front-end exports a `shen_take_out` that drains this buffer to JS.  On
/// native targets this is dead (the std.posix.system.write path runs); the
/// buffer costs only BSS.  Further writes past the cap are dropped (overflow
/// flag set so M2 can detect truncation if it cares).
const WASM_OUT_CAP: usize = 1 << 20; // 1 MiB
var wasm_out: struct {
    buf: [WASM_OUT_CAP]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
} = .{};

/// Drain the wasm output buffer to a caller-provided buffer (M2 front-end).
/// Copies up to `cap` bytes from `wasm_out` into `out`, then shifts the
/// remaining contents down.  Returns the number of bytes copied.  On wasm
/// this is the ONLY path JS pulls VM output through (write-byte on fd 1
/// appends to `wasm_out`; `shen_take_out` drains it).  On native this is dead
/// code (the std.posix.system.write path runs) but costs only BSS + a few
/// instructions.
pub fn drainWasmOut(out: [*]u8, cap: c_int) c_int {
    const c: usize = if (cap > 0) @intCast(cap) else 0;
    const n: usize = @min(wasm_out.len, c);
    if (n > 0) {
        @memcpy(out[0..n], wasm_out.buf[0..n]);
        const remaining = wasm_out.len - n;
        if (remaining > 0) {
            @memmove(wasm_out.buf[0..remaining], wasm_out.buf[n .. n + remaining]);
        }
        wasm_out.len = remaining;
    }
    return @intCast(n);
}

/// C: zincvm.c:360 MAX_STRING_STREAMS.
pub const MAX_STRING_STREAMS = 8;

/// C: zincvm.c:361-362 string_streams[] + n_string_streams.  One slot per
/// live string stream; a closed slot stays consumed (C parity: close frees
/// and NULLs data but never decrements n_string_streams).
const StringStream = struct {
    data: ?[*]u8 = null,
    len: i32 = 0,
    pos: i32 = 0,
};

/// The Vm-owned registry: fixed array of MAX_STRING_STREAMS slots + count.
/// Zero-initialized (`.{ }` = all-null slots, count 0), so a fresh Vm needs
/// no setup.
pub const StreamRegistry = struct {
    slots: [MAX_STRING_STREAMS]StringStream = [_]StringStream{StringStream{}} ** MAX_STRING_STREAMS,
    n_string_streams: i32 = 0,

    /// C: zincvm.c:364-381 val_string_stream_in.  Copies `src` into a fresh
    /// page_allocator buffer and returns a VAL_STREAM whose `file` holds
    /// (idx+1) int-in-pointer with is_string=1.  Overflow returns a
    /// VAL_ERROR (C val_error) with a stderr note.
    pub fn valStringStreamIn(self: *StreamRegistry, g: *Gc, src: []const u8) Value {
        if (self.n_string_streams >= MAX_STRING_STREAMS) {
            diag("runtime: too many string streams\n", .{});
            return values.valError(g, "too many string streams");
        }
        const idx: usize = @intCast(self.n_string_streams);
        const a = std.heap.page_allocator;
        const data = a.alloc(u8, src.len + 1) catch {
            diag("runtime: string stream alloc failed\n", .{});
            return values.valError(g, "out of memory");
        };
        @memcpy(data[0..src.len], src);
        data[src.len] = 0;
        self.slots[idx] = .{ .data = data.ptr, .len = @intCast(src.len), .pos = 0 };
        self.n_string_streams += 1;
        return .{ .tag = .stream, .payload = .{ .stream = .{
            .file = @ptrFromInt(idx + 1), // +1 so null never appears
            .is_input = 1,
            .is_string = 1,
        } } };
    }

    /// C: close's string-stream arm (:1928-1933): free the data buffer and
    /// NULL the slot (the slot index stays consumed).  Idempotent-safe: a
    /// slot whose data is already null is a no-op.
    pub fn freeStringStream(self: *StreamRegistry, idx: usize) void {
        const ss = &self.slots[idx];
        if (ss.data) |d| {
            const len: usize = @intCast(ss.len);
            std.heap.page_allocator.free(d[0 .. len + 1]);
        }
        ss.* = .{};
    }
};

/// Read the fd back from a FILE stream's int-in-?*anyopaque payload.
/// A null optional == fd 0 (stdin); otherwise @intFromPtr.
fn streamFd(s: Value) i32 {
    const f = s.payload.stream.file;
    if (f == null) return 0;
    return @intCast(@intFromPtr(f.?));
}

/// Build a FILE stream value with the fd stored int-in-?*anyopaque.
fn fileStreamIn(fd: i32) Value {
    return values.valStreamIn(@ptrFromInt(@as(usize, @intCast(fd))));
}

/// Build a FILE stream value with the fd stored int-in-?*anyopaque.
fn fileStreamOut(fd: i32) Value {
    return values.valStreamOut(@ptrFromInt(@as(usize, @intCast(fd))));
}

/// Public helpers for the host (loadBundle wires *stinput*/*stoutput*/
/// /*sterror* to the real std fds 0/1/2).
pub fn valStreamInFd(fd: i32) Value {
    return fileStreamIn(fd);
}

pub fn valStreamOutFd(fd: i32) Value {
    return fileStreamOut(fd);
}

// =====================================================================
//  write-byte — C: zincvm.c:2685-2690
// =====================================================================

/// C: write-byte (2 args, RTL: pop byte THEN stream).  Write one byte to the
/// stream's fd; NO buffering (raw write), so no flush is needed.  Returns the
/// byte written.  C's stdout-fflush special-case is dead here: raw fd writes
/// are unbuffered by construction.
pub fn primWriteByte(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const byte = interp.vaPop(stack);
    const s = interp.vaPop(stack);
    const fd = streamFd(s);
    const b: [1]u8 = .{@truncate(@as(u64, @bitCast(byte.payload.number)))};
    if (is_wasm) {
        // WASM: no real fds.  fd 1 (*stoutput*) drains to the wasm_out buffer
        // (M2 exports shen_take_out to pull it).  fd 2 (*sterror*) is silently
        // dropped; any other fd is a host-op we cannot satisfy.
        if (fd == 1) {
            if (wasm_out.len < WASM_OUT_CAP) {
                wasm_out.buf[wasm_out.len] = b[0];
                wasm_out.len += 1;
            } else {
                wasm_out.overflow = true;
            }
        } else if (fd != 2) {
            return vm.throwShen("write-byte: stream op not supported on wasm");
        }
    } else {
        _ = std.posix.system.write(fd, &b, 1);
    }
    acc.* = byte;
}

// =====================================================================
//  read-byte — C: zincvm.c:2382-2395
// =====================================================================

/// C: read-byte (1 arg).  String stream: decode (idx+1), pos<len else -1,
/// else the byte at pos (post-increment).  File stream: one-byte read with
/// EINTR retry (std.posix.read retries EINTR internally), EOF -> -1.  A hard
/// bad string-stream idx is error.Halt (the C `return -1`).
pub fn primReadByte(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const s = interp.vaPop(stack);
    if (s.payload.stream.is_string != 0) {
        const idx: i64 = @as(i64, @intCast(@intFromPtr(s.payload.stream.file.?))) - 1;
        if (idx < 0 or idx >= vm.streams.n_string_streams) return error.Halt;
        const ss = &vm.streams.slots[@intCast(idx)];
        if (ss.pos >= ss.len) {
            acc.* = values.valNumber(-1);
        } else {
            const b = ss.data.?[@intCast(ss.pos)];
            ss.pos += 1;
            acc.* = values.valNumber(b);
        }
        return;
    }
    if (is_wasm) {
        // WASM: file-stream reads are unsupported (no real fds); stdin (fd 0)
        // is meaningless in a browser line-eval.  Return EOF (C parity for a
        // read failure on a dead fd) rather than throw so a polling reader
        // terminates cleanly.
        acc.* = values.valNumber(-1);
        return;
    }
    const fd = streamFd(s);
    var buf: [1]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch {
        acc.* = values.valNumber(-1);
        return;
    };
    if (n == 0) {
        acc.* = values.valNumber(-1); // EOF
        return;
    }
    acc.* = values.valNumber(buf[0]);
}

// =====================================================================
//  read-file-as-string — C: zincvm.c:2396-2412
// =====================================================================

/// C: read-file-as-string (1 arg): read the whole file into a C-heap buffer
/// and val_string it.  The port reads into a page_allocator ArrayList (non-GC)
/// and valString copies from it (the valString CONTRACT holds).  On open
/// failure: stderr note + empty string (C parity).  valString is the only GC
/// allocation; buf.items is page_allocator so it never goes stale.
pub fn primReadFileAsString(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const g = vm.gc;
    const path = interp.vaPop(stack);
    const p = values.strSlice(path);
    if (is_wasm) {
        // WASM: no host filesystem under freestanding; return "" (C parity for
        // an open failure) rather than throw so a bundle that probes for an
        // absent file via read-file-as-string degrades cleanly.
        acc.* = values.valString(g, "");
        return;
    }
    const fd = std.posix.openat(std.posix.AT.FDCWD, p, .{}, 0) catch {
        diag("runtime: cannot open file for read-file-as-string\n", .{});
        acc.* = values.valString(g, "");
        return;
    };
    defer _ = std.posix.system.close(fd);
    const a = std.heap.page_allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(a);
    var tmp: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &tmp) catch break;
        if (n == 0) break;
        buf.appendSlice(a, tmp[0..n]) catch break;
    }
    acc.* = values.valString(g, buf.items);
}

// =====================================================================
//  open — C: zincvm.c:2346-2363
// =====================================================================

/// C: open (2 args, RTL: pop path THEN dir).  'in': O_RDONLY; ENOENT
/// (error.FileNotFound) -> a STRING stream of the PATH bytes (the C quirk,
/// ported verbatim), any other open error -> false.  'out': O_WRONLY|O_CREAT|
/// O_TRUNC 0666, fail -> false.  A dir that is neither 'in' nor 'out' leaves
/// acc unchanged (C falls through to `break`).  Deviation: C truncates the
/// path to 255 bytes into a fixed buffer before fopen; the port passes the
/// full path to openat (strictly more correct; no observable difference for
/// paths < 255, which is the only regime the C supports).
pub fn primOpen(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const path = interp.vaPop(stack);
    const dir = interp.vaPop(stack);
    const p = values.strSlice(path);
    const d = values.symSlice(dir);
    if (is_wasm) {
        // WASM: no host filesystem.  Preserve the C 'in' quirk (ENOENT → a
        // STRING stream of the PATH bytes) since that path is pure and lets
        // the wasm VM string-stream; 'out' and any actual file open are
        // unsatisfiable → false (C parity for an open failure).
        if (std.mem.eql(u8, d, "in")) {
            acc.* = vm.streams.valStringStreamIn(vm.gc, p);
            return;
        }
        acc.* = values.valBoolean(false);
        return;
    }
    if (std.mem.eql(u8, d, "in")) {
        const fd = std.posix.openat(std.posix.AT.FDCWD, p, .{}, 0) catch |e| {
            if (e == error.FileNotFound) {
                acc.* = vm.streams.valStringStreamIn(vm.gc, p);
                return;
            }
            acc.* = values.valBoolean(false);
            return;
        };
        acc.* = fileStreamIn(fd);
        return;
    }
    if (std.mem.eql(u8, d, "out")) {
        const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const fd = std.posix.openat(std.posix.AT.FDCWD, p, flags, 0o666) catch {
            acc.* = values.valBoolean(false);
            return;
        };
        acc.* = fileStreamOut(fd);
        return;
    }
    // neither 'in' nor 'out': fall through (C: acc unchanged).
}

// =====================================================================
//  close — C: zincvm.c:1926-1937
// =====================================================================

/// C: close (1 arg).  String stream: free data + NULL the slot (slot stays
/// consumed); a bad idx is a hard stop (error.Halt).  File stream: close the
/// fd only when the file pointer is non-null (C's `if (s.stream.file)`, which
/// skips null=fd0/stdin) — matching C's guard against closing an absent file.
pub fn primClose(vm: *Vm, acc: *Value, stack: *ValueArray) VmError!void {
    const s = interp.vaPop(stack);
    if (s.payload.stream.is_string != 0) {
        const idx: i64 = @as(i64, @intCast(@intFromPtr(s.payload.stream.file.?))) - 1;
        if (idx < 0 or idx >= vm.streams.n_string_streams) {
            diag("runtime: bad string stream idx\n", .{});
            return error.Halt;
        }
        vm.streams.freeStringStream(@intCast(idx));
        acc.* = values.valNil();
        return;
    }
    if (s.payload.stream.file != null) {
        if (is_wasm) {
            // WASM: no real fd to close; the file pointer is a logical handle
            // we never actually opened.  No-op (matches C's "close succeeds"
            // semantics for a stream we own).
        } else {
            _ = std.posix.system.close(streamFd(s));
        }
    }
    acc.* = values.valNil();
}

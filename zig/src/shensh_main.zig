//! src/shensh_main.zig — the shensh front-end executable (milestone M4).
//!
//! C origin: vm/shensh.c — the WHOLE translation unit, function-by-function:
//!   print_raw_string_ex   C:161-167   (raw write fd 1, ensure_nl)
//!   read_stdin_line       C:171-193   (raw read(0) byte loop, EOF -> null)
//!   eval_form1            C:199-211   ([fn arg] + execPrimitive("eval-kl"))
//!   call_bundled_0/1/3    C:220-313   (M2 hostcall.zig catching variants)
//!   is_defun_form         C:316-320
//!   eval_kl_form          C:329-338   (rooted — the documented SEGV history)
//!   boot_set_kl_string    C:355-364
//!   boot_set_kl_posargs   C:366-387   (right-to-left, s+tail rooted)
//!   sh_exit_code_num      C:392-406   (raw VAL_NUMBER OR tagged [number N])
//!   shen_load_source_ex   C:431-522   (read once -> tc-hm-forms ->
//!                                      shen->kl-forms -> interp-eval loop;
//!                                      rooting VERBATIM forms/tcs/fail_res/
//!                                      kls/cur/last — the "missing define"
//!                                      GC corruption history)
//!   line_is_klambda       C:539-553   (quoted-aware ; | & scan)
//!   eval_klambda_line     C:565-645   (shen-parse-exprs + per-form shen->kl
//!                                      -> interp-eval / eval-kl; parsed +
//!                                      cur + compiled + result rooted)
//!   main                  C:648-881   (boot order is load-bearing)
//!
//! PRINTING (plan M4): print_shen REUSES values.strValue — the C TU carries
//! its own str_value copy (shensh.c:72-126) only because zincvm.c's statics
//! are unreachable from a second translation unit; the Zig module boundary
//! does not have that problem, so no duplicate exists here.
//!
//! STDIO COEXISTENCE (plan M1 note): ALL front-end output goes through raw
//! libc write(1/2, ...) and line input through raw read(0, ...) — never
//! buffered stdio — so the read-byte prim (fd 0 raw, M1) and the REPL line
//! reads share one unbuffered path and never double-buffer.  C shensh uses
//! getchar()/printf() (stdio) for the front-end but that only coexists with
//! its read-byte because no REPL path reads *stinput*; the port keeps raw
//! fds throughout, which is strictly more consistent.  Bytes on fd 1/2 are
//! identical (C fflushes at every print; raw writes are already unbuffered).
//!
//! ROOTING: every site below mirrors its C function's shadow-stack pushes
//! exactly (C line refs in each comment) — this file is one of the two
//! GC-rooting cruxes of the port (the other being the eval loop), and the C
//! comments document real corruption histories (SEGV-after-failed-compile,
//! "missing define") that the rooting discipline below exists to prevent.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const heap = gc.heap;
const vm_mod = @import("vm");
const build_options = @import("build_options");

const values = vm_mod.values;
const symbols = vm_mod.symbols;
const state = vm_mod.state;
const prims = vm_mod.prims;
const hostcall = vm_mod.hostcall;

const Value = types.Value;
const Vm = state.Vm;

// ---- raw libc I/O (the process layer externs live in vm/execplan.zig but
//      are module-private; extern declarations are per-TU symbol references,
//      so redeclaring read/write here is a no-op at link time) ----
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

/// Write the exact bytes to fd (C fwrite/fprintf equivalents; writes are
/// already unbuffered, so the C fflush at each print site has no analogue).
/// Partial writes are continued; a hard error drops the remainder (C's
/// fwrite failure mode for stdout/stderr is equally silent).
fn rawWrite(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

// =====================================================================
//  print_shen — C: shensh.c:130-151 (str_value via zincvm.c:901-955)
// =====================================================================

/// Print a Shen-style representation of a value (values.strValue — the
/// [a b c] list form, depth-100 cap), then a newline, on fd 1.
/// Grow-until-fits exactly like C: start at 4096 and double while the
/// render truncated (C's `pos < cap - 1` check becomes Writer.fixed's
/// error.WriteFailed / exact-fit test).  Shell output can be arbitrarily
/// large (file dumps), so no fixed cap.
fn printShen(vm: *Vm, v: Value) void {
    _ = vm;
    const a = std.heap.page_allocator;
    var cap: usize = 4096;
    var pbuf = a.alloc(u8, cap) catch {
        rawWrite(1, "<oom>\n");
        return;
    };
    while (true) {
        var w: std.Io.Writer = .fixed(pbuf);
        var fits = true;
        values.strValue(&w, v, 0) catch {
            fits = false;
        };
        if (fits and w.buffered().len < pbuf.len) {
            rawWrite(1, w.buffered());
            rawWrite(1, "\n");
            a.free(pbuf);
            return;
        }
        cap *= 2;
        pbuf = a.realloc(pbuf, cap) catch {
            a.free(pbuf);
            rawWrite(1, "<oom>\n");
            return;
        };
    }
}

// =====================================================================
//  print_raw_string_ex — C: shensh.c:161-167
// =====================================================================

/// Print a VAL_STRING result RAW — the exact bytes, no quotes or escaping:
/// shell command output must appear exactly as the child wrote it.  When
/// ensure_nl is set and the output is non-empty without a trailing newline,
/// one is added (the REPL is line-oriented).  The prompt path passes
/// ensure_nl=false so the prompt and the user's typed input share a line.
fn printRawStringEx(vm: *Vm, v: Value, ensure_nl: bool) void {
    if (v.tag != .string) {
        printShen(vm, v);
        return;
    }
    const s = values.strSlice(v);
    if (s.len > 0) rawWrite(1, s);
    if (ensure_nl and s.len > 0 and s[s.len - 1] != '\n')
        rawWrite(1, "\n");
}

// =====================================================================
//  read_stdin_line — C: shensh.c:171-193
// =====================================================================

/// Read one line from stdin (page_allocator buffer, caller frees).  EOF on
/// an empty line -> null (C's `if (c == EOF) { if (len == 0) ... return
/// NULL; }`); EOF mid-line returns the partial line; '\n' terminates it and
/// is NOT included.  C uses getchar() (stdio); the port reads fd 0 raw one
/// byte at a time — see the STDIO COEXISTENCE note in the module doc.
fn readStdinLine() ?[]u8 {
    const a = std.heap.page_allocator;
    var cap: usize = 128;
    var buf = a.alloc(u8, cap) catch return null;
    var len: usize = 0;
    while (true) {
        var ch: [1]u8 = undefined;
        const n = read(0, &ch, 1);
        if (n == 0) { // EOF (read error n<0 collapses to the same path)
            if (len == 0) {
                a.free(buf);
                return null;
            }
            break;
        }
        if (n < 0) {
            a.free(buf);
            return null;
        }
        if (ch[0] == '\n') break;
        if (len + 1 >= cap) { // C:183-188 grow path
            cap *= 2;
            buf = a.realloc(buf, cap) catch {
                a.free(buf);
                return null;
            };
        }
        buf[len] = ch[0];
        len += 1;
    }
    return buf[0..len];
}

// =====================================================================
//  eval_form1 — C: shensh.c:199-211
// =====================================================================

/// Build [fn arg] and run exec_primitive("eval-kl") — the form resolves
/// through the metacircular interp (namespace 2: shen_load_source'd shell
/// defuns are NOT in the C defun_table).  The form is rooted across the
/// eval-kl chain (which allocates); the 1-slot ValueArray is read only
/// before eval-kl's first internal allocation (primEvalKl pops the form
/// before marshalToTagged), exactly as in C.  eval-kl never throws — it
/// RETURNS error VALUES — so the catch is the never-taken Halt arm.
fn evalForm1(vm: *Vm, fname: []const u8, arg: Value) Value {
    const g = vm.gc;
    var form = values.valCons(
        g,
        symbols.valSymbol(&vm.symbols, fname),
        values.valCons(g, arg, values.valNil()),
    );
    g.rootPushValue(&form);
    var s: types.ValueArray = .{ .data = g.allocArray(Value, 1), .len = 0, .cap = 1 };
    s.data.?[0] = form;
    s.len = 1;
    var acc: Value = values.valNil();
    prims.execPrimitive(vm, "eval-kl", &acc, &s) catch {};
    g.rootPop();
    return acc;
}

// =====================================================================
//  is_defun_form — C: shensh.c:316-320
// =====================================================================

/// Is a parsed form a (defun ...) definition?
fn isDefunForm(f: Value) bool {
    if (f.tag != .cons) return false;
    const h = f.payload.cons.car.?.*;
    return h.tag == .symbol and std.mem.eql(u8, values.symSlice(h), "defun");
}

// =====================================================================
//  eval_kl_form — C: shensh.c:329-338
// =====================================================================

/// Evaluate a KLambda form via the eval-kl primitive (namespace 2
/// resolution).  The form MUST stay rooted: the 1-slot stack array and the
/// whole eval-kl chain (extract-kl -> kl->zinc -> toplevel-interp) allocate,
/// and an unrooted form goes stale after any collection.  That was the C
/// REPL fragility (the shensh.c:322-328 comment: nested prim-call forms
/// compiled from garbage and could SEGV afterwards) — the port roots the
/// form in a local slot, mirroring the C volatile+root dance.
fn evalKlForm(vm: *Vm, form: Value) Value {
    const g = vm.gc;
    var f = form;
    g.rootPushValue(&f);
    var s: types.ValueArray = .{ .data = g.allocArray(Value, 1), .len = 0, .cap = 1 };
    s.data.?[0] = f;
    s.len = 1;
    var acc: Value = values.valNil();
    prims.execPrimitive(vm, "eval-kl", &acc, &s) catch {};
    g.rootPop();
    return acc;
}

// =====================================================================
//  boot globals for the shell positional parameters — C: shensh.c:340-387
// =====================================================================

/// These MUST be stored through the interpreter's own (set X V) path —
/// evalKlForm on a (set ...) KLambda form — and NOT via the raw C-side
/// value_set(): the interp's [prim set] rule stores the interpreter's
/// TAGGED representation ([string S] / [number N] cons cells) into the
/// values table, which is what the shell sources' tagged pattern-match
/// readers expect.  A raw VAL_STRING write reads back untagged and every
/// tagged rule misclassifies it (the documented failure: $0/$-/$1.. always
/// fell to their defaults).  Storing through eval-kl lands exactly what a
/// REPL (set ...) lands.
///
/// C: shensh.c:355-364 — (set <name> "<sval>").
fn bootSetKlString(vm: *Vm, name: []const u8, sval: []const u8) void {
    const g = vm.gc;
    var form = values.valCons(
        g,
        symbols.valSymbol(&vm.symbols, "set"),
        values.valCons(
            g,
            symbols.valSymbol(&vm.symbols, name),
            values.valCons(g, values.valString(g, sval), values.valNil()),
        ),
    );
    g.rootPushValue(&form);
    _ = evalKlForm(vm, form);
    g.rootPop();
}

/// C: shensh.c:366-387 — (set *sh-posargs* (cons "a1" (cons "a2" ... ()))),
/// built RIGHT-TO-LEFT so the form is ordinary KLambda the eval-kl compiler
/// handles (cons is a primitive; () compiles to emptylist).  `tail` stays
/// rooted across the whole build; each `s` is rooted across its cons allocs
/// (C:371/374).
fn bootSetKlPosargs(vm: *Vm, args: []const []const u8) void {
    const g = vm.gc;
    var tail = values.valNil();
    g.rootPushValue(&tail);
    var i = args.len;
    while (i > 0) {
        i -= 1;
        var s = values.valString(g, args[i]);
        g.rootPushValue(&s); // s live across the cons allocs below — C:374
        const cell = values.valCons(
            g,
            symbols.valSymbol(&vm.symbols, "cons"),
            values.valCons(g, s, values.valCons(g, tail, values.valNil())),
        );
        g.rootPop(); // s
        tail = cell;
    }
    var form = values.valCons(
        g,
        symbols.valSymbol(&vm.symbols, "set"),
        values.valCons(
            g,
            symbols.valSymbol(&vm.symbols, "*sh-posargs*"),
            values.valCons(g, tail, values.valNil()),
        ),
    );
    g.rootPushValue(&form);
    _ = evalKlForm(vm, form);
    g.rootPop(); // form
    g.rootPop(); // tail
}

// =====================================================================
//  sh_exit_code_num — C: shensh.c:392-406
// =====================================================================

/// *sh-exit-code* is stored by shell.shen (sh-run-plan) through the interp's
/// (set ...), so the values-table entry is the interpreter's TAGGED
/// [number N] cons, not a raw VAL_NUMBER.  Unwrap either form.
fn shExitCodeNum(vm: *Vm) i64 {
    const code = vm.valueGet("*sh-exit-code*");
    if (code.tag == .number) return code.payload.number;
    if (code.tag == .cons) {
        const h = code.payload.cons.car.?.*;
        if (h.tag == .symbol and std.mem.eql(u8, values.symSlice(h), "number")) {
            const rest = code.payload.cons.cdr.?.*; // the (N) tail of [number N]
            if (rest.tag == .cons) {
                const num = rest.payload.cons.car.?.*;
                if (num.tag == .number) return num.payload.number;
            }
        }
    }
    return 0;
}

// =====================================================================
//  shen_load_source_ex — C: shensh.c:431-522
// =====================================================================

/// Run a REAL Shen source file through the bundled subset-Shen compiler:
///   shen-load Path = (shen-eval-forms (shen->kl-forms (shen-read-file Path)))
/// All stages are BUNDLED closures in namespace 1, reached via callBundled1
/// (NOT eval-kl, which resolves namespace 2).  TYPE-CHECK FIRST (tc-hm-forms
/// on the SAME forms list — read the file ONCE, C:432-441 documents the
/// heap-state-dependent truncation observed on a second shen-read-file);
/// any [fail Reason] aborts the load with that reason.
///
/// ROOTING — VERBATIM from C:443-521 (the comments there document the
/// "missing define" corruption): forms/tcs/fail_res/kls/cur/last each stay
/// rooted across every allocating stage; `cur` in the interp-eval loop MUST
/// be a rooted slot because interp-eval allocates (compiles the defun,
/// updates the namespace-2 global-table) and a collection there would move
/// the cons cell cur points at, silently dropping subsequent defuns.
fn shenLoadSourceEx(vm: *Vm, path: []const u8, verbose: bool) Value {
    const g = vm.gc;

    // stage 0: read the file into forms ONCE (C:442-448).
    var p = values.valString(g, path);
    g.rootPushValue(&p);
    var forms = hostcall.callBundled1(vm, "shen-read-file", p);
    g.rootPop(); // p
    if (forms.tag != .cons)
        return symbols.valSymbol(&vm.symbols, "shen-load: read failed");
    g.rootPushValue(&forms);

    // stage 1: HM type-check the same forms (C:450-481).  The [fail Reason]
    // scan itself performs NO GC allocation (printShen renders into a
    // C-heap buffer), so the un-rooted spine walker `r` never goes stale.
    var tcs = hostcall.callBundled1(vm, "tc-hm-forms", forms);
    g.rootPushValue(&tcs);
    var fail_res = values.valNil();
    g.rootPushValue(&fail_res);
    if (tcs.tag == .cons) {
        var r = tcs;
        var any_fail = false;
        while (r.tag == .cons) {
            const res = r.payload.cons.car.?.*;
            // res is [ok Name] or [fail Reason]
            var is_fail = false;
            if (res.tag == .cons) {
                const h = res.payload.cons.car.?.*;
                if (h.tag == .symbol and std.mem.eql(u8, values.symSlice(h), "fail")) {
                    is_fail = true;
                    fail_res = res.payload.cons.cdr.?.payload.cons.car.?.*;
                }
            }
            if (verbose) printShen(vm, res);
            if (is_fail) any_fail = true;
            r = r.payload.cons.cdr.?.*;
        }
        if (any_fail) {
            g.rootPop(); // fail_res
            g.rootPop(); // tcs
            g.rootPop(); // forms
            return fail_res;
        }
    }
    g.rootPop(); // fail_res
    g.rootPop(); // tcs

    // stage 2: compile Shen source forms -> KLambda defuns (C:486-491).
    var kls = hostcall.callBundled1(vm, "shen->kl-forms", forms);
    g.rootPushValue(&kls);
    if (kls.tag != .cons and kls.tag != .nil) {
        g.rootPop(); // kls
        g.rootPop(); // forms
        return symbols.valSymbol(&vm.symbols, "shen-load: compile failed");
    }

    // stage 3: register each defun into namespace 2 via interp-eval
    // (C:493-521).  interp-eval returns the defun's Name on success, the
    // form unchanged for non-defun forms, or throws (caught by
    // callBundled1 -> VAL_ERROR) when a defun fails to compile — individual
    // failures are tolerated; the result distinguishes a clean load.
    var cur = kls;
    var last = symbols.valSymbol(&vm.symbols, "loaded");
    g.rootPushValue(&last);
    // cur must stay rooted across interp-eval — the "missing define"
    // corruption fix (C:504-508).
    g.rootPushValue(&cur);
    while (cur.tag == .cons) {
        var defun = cur.payload.cons.car.?.*;
        g.rootPushValue(&defun);
        last = hostcall.callBundled1(vm, "interp-eval", defun);
        g.rootPop(); // defun
        cur = cur.payload.cons.cdr.?.*;
    }
    g.rootPop(); // cur
    g.rootPop(); // last
    const ret: Value = if (last.tag == .error_) last else symbols.valSymbol(&vm.symbols, "loaded");
    g.rootPop(); // kls
    g.rootPop(); // forms
    return ret;
}

/// Default verbose wrapper for the `shen-load` shell command (C:526-528):
/// prints each define's type-check result.  Boot uses quiet mode.
fn shenLoadSource(vm: *Vm, path: []const u8) Value {
    return shenLoadSourceEx(vm, path, true);
}

// =====================================================================
//  line_is_klambda — C: shensh.c:539-553
// =====================================================================

/// Does the line (after leading whitespace) start with '(' ?  If so it is
/// EITHER a Shen/KLambda expression (routed through the bundled flat-Shen
/// reader/compiler) or a SHELL SUBSHELL — the grammar treats '(' at command
/// position as a subshell ((cd /; pwd), ...).  Shen/KLambda has no ; | &
/// operators, so a '(' line containing any of those OUTSIDE quotes is a
/// subshell, not Shen.  A bare (cd /) with no chain/pipeline still parses
/// as Shen (KLambda probe) — documented v1 divergence, kept verbatim.
fn lineIsKlambda(line_in: []const u8) bool {
    var line = line_in;
    while (line.len > 0 and std.ascii.isWhitespace(line[0])) line = line[1..];
    if (line.len == 0 or line[0] != '(') return false;
    var q: u8 = 0; // 0 = unquoted, '\'' or '"' inside quotes
    for (line) |ch| {
        if (q == '\'') {
            if (ch == '\'') q = 0;
        } else if (q == '"') {
            if (ch == '"') q = 0;
        } else {
            if (ch == '\'') q = '\''
            else if (ch == '"') q = '"'
            else if (ch == ';' or ch == '|' or ch == '&') return false;
        }
    }
    return true;
}

// =====================================================================
//  eval_klambda_line — C: shensh.c:565-645
// =====================================================================

/// Evaluate a whole '(' line (possibly several forms) through the bundled
/// FLAT-SHEN reader + compiler: shen-parse-exprs (Str Pos Len) parses,
/// returning [[Expr|Rest] FinalPos]; each form is compiled by shen->kl; a
/// compiled (defun ...) registers into namespace 2 via interp-eval
/// ("; registered N"), everything else evaluates via eval-kl ("=> V").
///
/// ROOTING (C:573-644, the documented SEGV-after-failed-compile history):
/// `parsed` is rooted across the (catching) parse; the root is popped only
/// once hd has been copied into `cur`, which is then rooted across the
/// whole per-form loop (shen->kl, interp-eval and evalKlForm all allocate);
/// `compiled` and `result` are rooted across each form's compile+eval.
/// The C per-form CatchFrame collapses into the M2 catching callBundled1
/// (a throw returns the error VALUE vm.err_slot), so err is recovered as
/// `result.tag == .error_` — in the is_defun arm interp-eval only ever
/// produces an error VALUE by throwing, which is exactly C's setjmp err=1.
fn evalKlambdaLine(vm: *Vm, line: []const u8) void {
    const g = vm.gc;
    const str_v = values.valString(g, line);
    const zero = values.valNumber(0);
    const len_v = values.valNumber(@intCast(line.len));

    // C:570-584 — CatchFrame around call_closure3; the M2 catching
    // callBundled3 returns vm.err_slot on a throw (== C's cf_parse.error_val).
    var parsed = hostcall.callBundled3(vm, "shen-parse-exprs", str_v, zero, len_v);
    g.rootPushValue(&parsed);

    if (parsed.tag != .cons or parsed.payload.cons.car.?.tag != .cons) {
        rawWrite(1, "parse error: ");
        printShen(vm, parsed);
        rawWrite(1, "\n");
        g.rootPop(); // parsed
        return;
    }
    const exprs = parsed.payload.cons.car.?.*; // hd of [[Expr|Rest] FinalPos]
    // Copy hd into cur BEFORE popping parsed's root — no allocation happens
    // between the read and cur's own root push (C:584-600).
    g.rootPop(); // parsed

    var cur = exprs;
    g.rootPushValue(&cur);
    while (cur.tag == .cons) {
        const expr = cur.payload.cons.car.?.*;
        // expr is rooted by the callee: callBundled1's applyBundledN roots
        // its arg array before the first allocation (C:604-611 comment).

        var compiled = values.valNil();
        g.rootPushValue(&compiled);
        var result = values.valNil();
        g.rootPushValue(&result);

        compiled = hostcall.callBundled1(vm, "shen->kl", expr);
        const is_defun = isDefunForm(compiled);
        if (is_defun) {
            result = hostcall.callBundled1(vm, "interp-eval", compiled);
        } else {
            result = evalKlForm(vm, compiled);
        }
        const err = (result.tag == .error_);

        if (is_defun) {
            if (!err and result.tag == .symbol) {
                rawWrite(1, "; registered ");
                printShen(vm, result);
            } else {
                rawWrite(1, "; defun registration failed: ");
                printShen(vm, result);
            }
        } else {
            rawWrite(1, "=> ");
            printShen(vm, result);
        }
        g.rootPop(); // result
        g.rootPop(); // compiled
        cur = cur.payload.cons.cdr.?.*;
    }
    g.rootPop(); // cur
}

// =====================================================================
//  read_file_or_stdin — C: zincvm.c:3733-3746 (shensh always passes a path)
// =====================================================================

/// Read a whole file into a sentinel-terminated page_allocator buffer (the
/// loadBundle input type).  On open failure prints C's message and returns
/// null.  Zig 0.16 has no std.fs; raw POSIX per the M0 idiom.
fn readWholeFile(path: []const u8) ?[:0]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch {
        rawWrite(2, "error: cannot open '");
        rawWrite(2, path);
        rawWrite(2, "'\n");
        return null;
    };
    defer _ = std.posix.system.close(fd);
    const a = std.heap.page_allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    var tmp: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &tmp) catch break; // read error == C's fgetc EOF
        if (n == 0) break;
        buf.appendSlice(a, tmp[0..n]) catch return null;
    }
    return buf.toOwnedSliceSentinel(a, 0) catch null;
}

// =====================================================================
//  main — C: shensh.c:648-881 (boot order is load-bearing)
// =====================================================================

pub fn main(m: std.process.Init.Minimal) u8 {
    // ---- argv (C main's argc/argv) ----
    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;
    var it = std.process.Args.Iterator.init(m.args);
    while (it.next()) |arg| {
        if (argc == argv_buf.len) break;
        argv_buf[argc] = arg;
        argc += 1;
    }
    const argv = argv_buf[0..argc];

    // ---- boot: GC 256MB heap (C:652 gc_init(256MB); the 1GB reservation
    //      is the port's M0 convention to avoid the C default's 4GB VAS) →
    //      Vm.init (initGlobals + table registration — the port folds C's
    //      init_globals/gc_register_* calls into one unit; initGlobals only
    //      stores scalar VAL_PRIMs, so the C order difference is inert) →
    //      loadBundle.  The heap is deliberately NOT deinit'd — C never
    //      frees it either; the OS reclaims at exit. ----
    var g = heap.Gc.init(.{
        .heap_bytes = 256 * 1024 * 1024,
        .reserve_bytes = 1024 * 1024 * 1024,
        // M5: whole-stack precise-rooting proof — every collection after
        // boot re-verifies the heap (Debug/ReleaseSafe only; the verify
        // hook is compiled out in ReleaseFast).  Enabled via the
        // `zig build shensh -Dverify-collects=true` build option.
        .verify_collects = build_options.verify_collects,
    }) catch {
        rawWrite(2, "shensh: cannot allocate GC heap\n");
        return 1;
    };
    var vm_inst: Vm = undefined;
    vm_inst.init(&g);
    const vm = &vm_inst;

    const bundle: []const u8 = if (argc > 1) argv[1] else "globals.csexp";
    const maybe_src = readWholeFile(bundle);
    var loaded: i32 = 0;
    if (maybe_src) |src| {
        loaded = vm.loadBundle(src);
        std.heap.page_allocator.free(src);
    }
    if (loaded == 0) {
        rawWrite(2, "shensh: cannot load bundle ");
        rawWrite(2, bundle);
        rawWrite(2, "\n");
        return 1;
    }

    // ---- tc-hm-init BEFORE the shell sources load (C:665-681): the sig
    //      table must accumulate across the 4 boot loads (dependency order)
    //      and the prim table must be built or body/arg type errors
    //      silently pass.  Missing/failed init is non-fatal — warn and
    //      continue. ----
    const tcinit = hostcall.callBundled0(vm, "tc-hm-init");
    if (tcinit.tag != .symbol or !std.mem.eql(u8, values.symSlice(tcinit), "done")) {
        rawWrite(2, "shensh: warning: tc-hm-init did not complete (got ");
        printShen(vm, tcinit);
        rawWrite(2, ") — type-checker may be uninitialised; continuing\n");
    }

    // ---- boot the shell sources via shenLoadSourceEx(quiet) in dependency
    //      order (C:683-705): shparse uses shlex's sp-prepend-list; shexpand
    //      uses the sp-* string helpers; shell.shen (the driver) calls
    //      sp-lex/sp-parse/shx-plan.  Each load is warn-and-continue.
    //      RELATIVE paths — the exe must run from the repo root. ----
    const boot_files = [_][]const u8{
        "shell/shlex.shen",
        "shell/shparse.shen",
        "shell/shexpand.shen",
        "shell/shell.shen",
    };
    for (boot_files) |bf| {
        const bootv = shenLoadSourceEx(vm, bf, false);
        if (bootv.tag != .symbol or !std.mem.eql(u8, values.symSlice(bootv), "loaded")) {
            rawWrite(2, "shensh: warning: failed to load ");
            rawWrite(2, bf);
            rawWrite(2, " (got ");
            printShen(vm, bootv);
            rawWrite(2, ") — continuing without it\n");
        }
    }

    // ---- positional-parameter globals (C:707-735): *sh-argv0* / *sh-posargs*
    //      / *sh-flags*, ALWAYS through evalKlForm so the values land TAGGED
    //      (see bootSetKlString's doc — never a raw value_set from C-side).
    //      -c MODE: argv[2]=="-c" → cmd=argv[3], argv0=argv[4] if present
    //      (bash convention), posargs = argv[5..]. ----
    var cmd_string: ?[]const u8 = null;
    var pos_args: []const []const u8 = &.{};
    var argv0: []const u8 = if (argc > 0) argv[0] else "shensh";
    if (argc > 3 and std.mem.eql(u8, argv[2], "-c")) {
        cmd_string = argv[3];
        var first_pos: usize = 4;
        if (argc > 4) {
            argv0 = argv[4];
            first_pos = 5;
        }
        pos_args = argv[first_pos..];
    } else if (argc > 2 and std.mem.eql(u8, argv[2], "-c")) {
        rawWrite(2, "shensh: -c requires a command string\n");
        return 2;
    }
    bootSetKlString(vm, "*sh-argv0*", argv0);
    bootSetKlString(vm, "*sh-flags*", if (cmd_string != null) "c" else "i");
    bootSetKlPosargs(vm, pos_args);

    if (cmd_string) |cmd| {
        // -c MODE (C:737-762): run the ONE command string through the same
        // shell-eval-line path the REPL uses (no prompt), print its output
        // raw, exit with the last command's exit status.  The result stays
        // rooted while printed.
        var cresult: Value = values.valNil();
        g.rootPushValue(&cresult);
        cresult = evalForm1(vm, "shell-eval-line", values.valString(vm.gc, cmd));
        if (cresult.tag == .error_) {
            rawWrite(2, "shensh: ");
            printShen(vm, cresult);
            g.rootPop();
            std.process.exit(126);
        }
        if (cresult.tag == .symbol and std.mem.eql(u8, values.symSlice(cresult), "sh-continue")) {
            rawWrite(2, "shensh: heredoc: unexpected EOF\n");
            g.rootPop();
            std.process.exit(1);
        }
        printRawStringEx(vm, cresult, true);
        g.rootPop();
        // C `return (int)sh_exit_code_num();` — the kernel masks to 0-255.
        const code: u8 = @intCast(@as(u64, @bitCast(shExitCodeNum(vm))) & 0xff);
        std.process.exit(code);
    }

    // ---- REPL loop (C:772-878): prompt via evalForm1("sh-prompt", "") →
    //      raw print NO newline; readStdinLine; EOF → break; skip
    //      whitespace-only lines; '(' lines → evalKlambdaLine; `shen-load `
    //      prefix → shenLoadSource(verbose); else evalForm1("shell-eval-line")
    //      with the result rooted across the heredoc re-evaluations. ----
    const a = std.heap.page_allocator;
    while (true) {
        const prompt = evalForm1(vm, "sh-prompt", values.valString(vm.gc, ""));
        if (prompt.tag == .error_) {
            rawWrite(2, "shensh: prompt error: ");
            printShen(vm, prompt);
            break;
        }
        printRawStringEx(vm, prompt, false); // raw prompt, no newline

        const maybe_line = readStdinLine();
        if (maybe_line == null) break; // EOF
        var line: []u8 = maybe_line.?;
        defer a.free(line); // frees whichever buffer `line` holds at scope end

        // skip blank / whitespace-only lines
        var only_ws = true;
        for (line) |ch| {
            if (!std.ascii.isWhitespace(ch)) {
                only_ws = false;
                break;
            }
        }
        if (only_ws) continue;

        // '(' lines go through the bundled flat-Shen reader/compiler —
        // shen-parse-exprs is a namespace-1 bundled closure, unreachable
        // from interpreted code.
        if (lineIsKlambda(line)) {
            evalKlambdaLine(vm, line);
            continue;
        }

        // `shen-load <path>` builtin (C:804-814): handled in the front-end
        // so it can reach the namespace-1 bundled Shen compiler.
        if (line.len >= 10 and std.mem.startsWith(u8, line, "shen-load") and
            (line[9] == ' ' or line[9] == '\t'))
        {
            var p: usize = 9;
            while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
            const r = shenLoadSource(vm, line[p..]);
            printShen(vm, r);
            continue;
        }

        // Otherwise: a shell command line, handled by shell/shell.shen.
        // The result stays rooted across the heredoc re-evaluations below —
        // each evalForm1 allocates (C:816-822).
        var result: Value = values.valNil();
        g.rootPushValue(&result);
        result = evalForm1(vm, "shell-eval-line", values.valString(vm.gc, line));

        // Heredoc continuation (C:824-854): shell-eval-line returned the
        // symbol sh-continue — the line ends inside an unterminated heredoc.
        // Read further lines, buffer = buffer + "\n" + line, re-eval the
        // whole buffer until the delimiter closes (the lexer/parser stay on
        // the Shen side; this loop never parses).  Blank lines are
        // legitimate heredoc body, so nothing is skipped.  EOF while still
        // pending is an error and resets the buffer.
        while (result.tag == .symbol and std.mem.eql(u8, values.symSlice(result), "sh-continue")) {
            rawWrite(1, "> ");
            const maybe_more = readStdinLine();
            if (maybe_more == null) {
                rawWrite(2, "shensh: heredoc: unexpected EOF\n");
                result = values.valString(vm.gc, "");
                break;
            }
            const more = maybe_more.?;
            const joined_len = line.len + 1 + more.len;
            const nb = a.alloc(u8, joined_len) catch {
                a.free(more);
                rawWrite(2, "shensh: out of memory\n");
                result = values.valString(vm.gc, "");
                break;
            };
            @memcpy(nb[0..line.len], line);
            nb[line.len] = '\n';
            @memcpy(nb[line.len + 1 ..][0..more.len], more);
            a.free(line);
            line = nb;
            a.free(more);
            result = evalForm1(vm, "shell-eval-line", values.valString(vm.gc, line));
        }

        var is_exit = false;
        if (result.tag == .error_) {
            rawWrite(2, "shensh: eval error: ");
            printShen(vm, result);
        } else if (result.tag == .string) {
            // Command output prints RAW — the display string built by
            // shell.shen is exactly what the program wrote (plus a
            // synthesized "exit N"/"error: ..." when there is no output).
            printRawStringEx(vm, result, true);
        } else {
            printShen(vm, result);
            // the exit builtin also signals via the symbol `exit` after
            // setting *sh-exit*
            is_exit = (result.tag == .symbol and
                std.mem.eql(u8, values.symSlice(result), "exit"));
        }
        g.rootPop(); // result
        if (is_exit) break;
    }

    // C main VERBATIM (C:880): returns 0 after the loop even though the
    // `exit` builtin may have set *sh-exit* — the REPL exit code is always 0.
    return 0;
}

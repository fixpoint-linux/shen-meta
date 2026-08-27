//! src/vm/interp.zig — the ZINC eval loop (milestone M4).
//!
//! C origin: zincvm.c:406-437 (ValueArray va_init/va_push/va_pop/va_peek/
//! va_free), zincvm.c:3107-3137 (lookup_env / env_push / env_pop), and
//! zincvm.c:3154-3474 (vm_exec_env, vm_exec).
//!
//! M4 SCOPE: the eval loop with full per-opcode rooting discipline, LAMBDA
//! paths only.  exec_primitive is NOT yet linked (plan M5 ports the pure
//! subset into vm/prims.zig): the OP_PRIM / apply-prim / appterm-prim call
//! sites go through a stub that always hard-stops, already shaped as the
//! final DECISION-A discipline (error.Halt caught HERE = C's
//! `exec_primitive() < 0 → goto done` with acc preserved; error.ShenError
//! propagates to the enclosing CatchSite chain).
//!
//! ERROR MODEL (plan DECISION A): C's setjmp/longjmp + CatchFrame chain
//! becomes VmError = error{ShenError, Halt} (state.zig) plus a linked chain
//! of stack-allocated CatchSites on Vm.  vm_throw → vm.throwShen(msg)
//! (builds valError into the permanently-rooted vm.err_slot, returns
//! error.ShenError).  Because Zig error returns unwind frames WITH defers
//! running (longjmp skips them), ONE `defer gc.rootPopTo(entry_wm)` per
//! vmExecEnv frame replaces C's 9 manual pops at done (C:3464-3466) and
//! every pop_to a longjmp landing site would have needed.
//!
//! ROOTING CONTRACT (the crux — ported verbatim from the C, C line refs on
//! each site):
//!   [PROLOGUE] code(1)/init_env(2)/env(3)/stack.data(4)/acc(5) are pushed
//!   BEFORE any allocation, while env/stack.data/acc are still NULL/nil —
//!   NULL slots pin nothing, but the SLOTS must be stable addresses because
//!   scanRoots reads their CURRENT value at collect time; then va_init, the
//!   init_env copy + barrier, the old-gen CallFrame array (65536 entries,
//!   ~3 MB), callframe_array(6)/cur_code(7)/frame_stack(8) roots.
//!   frames_sp is a plain native local (C needed a GC-heap int only because
//!   longjmp dangles stack locals; ROOT_CALLFRAME_ARRAY's np is never
//!   dereferenced at scan time — collect.zig scanRoots is a deliberate
//!   no-op for that kind).
//!   [PER-OPCODE] transient roots (the 64-slot argbuf in apply/appterm) are
//!   pushed before the first alloc in the opcode and popped right after the
//!   env fill; va_push / env_push root their argument internally across the
//!   grow alloc.  `Instr *in` is re-derived from the rooted cur_code at the
//!   top of EVERY iteration and never cached across an allocating call.
//!   [EPILOGUE] the defer rootPopTo(entry_wm) above covers every exit,
//!   including error returns.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const state = @import("state.zig");
const values = @import("values.zig");
const prims = @import("prims.zig");

/// Diagnostic print — gated to non-freestanding targets (M1 wasm gate).
/// The true branch references `std.debug.print` directly (NOT `diag` — a
/// self-referential `if (...) diag else ...` is a circular-declaration error).
const diag = if (@import("builtin").os.tag != .freestanding) std.debug.print else struct {
    fn call(comptime _: []const u8, _: anytype) void {}
}.call;

const Gc = gc.Gc;
const Value = types.Value;
const Vm = state.Vm;
const VmError = state.VmError;

// =====================================================================
//  Value stack — C: zincvm.c:406-437
// =====================================================================

/// C: zincvm.c:407 STACK_INIT_CAP.
pub const STACK_INIT_CAP: i32 = 64;

/// C: zincvm.c:410-413 va_init.  Must only be called once the caller's
/// stable slots for a->data (and anything read during the alloc) are rooted
/// — vmExecEnv's prologue does this before its va_init.
pub fn vaInit(g: *Gc, a: *types.ValueArray) void {
    a.data = g.allocArray(Value, @intCast(STACK_INIT_CAP));
    a.len = 0;
    a.cap = STACK_INIT_CAP;
}

/// C: zincvm.c:414-432 va_push.  On grow, v is rooted across the
/// GC_VALUE_ARRAY (v may carry interior pointers — lambda.code/env,
/// cons.car/cdr, str.data — that a collection fired during the grow would
/// otherwise leave stale in this local, C:416-421); after the store, the
/// write barrier records the element array in the remembered set iff it is
/// old-gen AND the stored Value references the nursery (C:429-431).
pub fn vaPush(g: *Gc, a: *types.ValueArray, v: Value) void {
    var vv = v;
    if (a.len >= a.cap) {
        const new_cap: i32 = a.cap * 2;
        var guard = g.rootValue(&vv); // root v across GC_VALUE_ARRAY — C:422
        defer guard.end();
        const new_data = g.allocArray(Value, @intCast(new_cap));
        const ln: usize = @intCast(a.len);
        @memcpy(new_data[0..ln], a.data.?[0..ln]);
        // M5 fix: the grow copies the OLD elements into a possibly-oldgen
        // array; barrier them (a copied nursery reference would otherwise go
        // stale at the next scavenge).  Mirrors applyBundledN / interp apply.
        if (g.inOldgen(@intFromPtr(new_data))) {
            var j: usize = 0;
            while (j < ln) : (j += 1) {
                if (gc.scan.valueReferencesNursery(g, &a.data.?[j])) {
                    g.dirtyVectorsAdd(new_data);
                    break;
                }
            }
        }
        a.data = new_data;
        a.cap = new_cap;
    }
    const idx: usize = @intCast(a.len);
    a.data.?[idx] = vv;
    a.len += 1;
    // C checks &v (the stored copy); &a->data[a->len-1] is now that copy and
    // valueReferencesNursery is read-only — identical behaviour.
    if (g.inOldgen(@intFromPtr(a.data.?)) and
        gc.scan.valueReferencesNursery(g, &a.data.?[idx]))
        g.dirtyVectorsAdd(a.data.?);
}

/// C: zincvm.c:433-436 va_pop — pop from an empty stack is fatal
/// (C fprintf + exit(1) → std.debug.panic).
pub fn vaPop(a: *types.ValueArray) Value {
    if (a.len <= 0) std.debug.panic("fatal: pop from empty stack", .{});
    a.len -= 1;
    // Clear the vacated slot: the GC scans value_arrays by full capacity,
    // so a stale ref here would retain popped Values (closure envs).
    const v = a.data.?[@intCast(a.len)];
    a.data.?[@intCast(a.len)] = values.valNil();
    return v;
}

/// C: zincvm.c:437 va_peek.
pub fn vaPeek(a: *types.ValueArray) Value {
    return a.data.?[@intCast(a.len - 1)];
}

/// C: zincvm.c:438 va_free — release the slots only (the array itself is
/// GC-managed); the rooted &stack.data slot now pins nothing.
pub fn vaFree(a: *types.ValueArray) void {
    a.data = null;
    a.len = 0;
    a.cap = 0;
}

// =====================================================================
//  Environment access — C: zincvm.c:3107-3137
// =====================================================================

/// C: zincvm.c:3107-3116 lookup_env.  Out-of-bounds access returns 0
/// silently — this occurs in nested closures with empty captured
/// environments during interp execution; downstream guards (cons?, =, ...)
/// reject the sentinel.
pub fn lookupEnv(n: i32, env: ?[*]Value, env_len: i32) Value {
    if (n < 0 or n >= env_len) return values.valNumber(0);
    return env.?[@intCast(env_len - 1 - n)];
}

/// C: zincvm.c:3117-3132 env_push.  env/env_len/env_cap are the caller's
/// frame locals — in vmExecEnv `&env` is a ROOT_PTR pushed in the prologue,
/// so writes through these pointers update the rooted slot.  The grow roots
/// v across the GC_VALUE_ARRAY (C:3120); the store takes the old-gen write
/// barrier (C:3128-3129).
pub fn envPush(g: *Gc, env: *?[*]Value, env_len: *i32, env_cap: *i32, v: Value) void {
    var vv = v;
    if (env_len.* >= env_cap.*) {
        const new_cap: i32 = if (env_cap.* != 0) env_cap.* * 2 else 4;
        var guard = g.rootValue(&vv); // root v across GC_VALUE_ARRAY — C:3120
        defer guard.end();
        const new_env = g.allocArray(Value, @intCast(new_cap));
        const ln: usize = @intCast(env_len.*);
        if (ln > 0) {
            @memcpy(new_env[0..ln], env.*.?[0..ln]);
            // M5 fix: barrier copied env elements on grow (same rationale as
            // the vaPush grow barrier).
            if (g.inOldgen(@intFromPtr(new_env))) {
                var j: usize = 0;
                while (j < ln) : (j += 1) {
                    if (gc.scan.valueReferencesNursery(g, &env.*.?[j])) {
                        g.dirtyVectorsAdd(new_env);
                        break;
                    }
                }
            }
        }
        env.* = new_env;
        env_cap.* = new_cap;
    }
    const idx: usize = @intCast(env_len.*);
    env.*.?[idx] = vv;
    env_len.* += 1;
    if (g.inOldgen(@intFromPtr(env.*.?)) and
        gc.scan.valueReferencesNursery(g, &env.*.?[idx]))
        g.dirtyVectorsAdd(env.*.?);
}

/// C: zincvm.c:3130-3137 env_pop.  Inside a trap-error catch site
/// (in_trap_error) a pop of an empty environment throws — catchable;
/// anywhere else it is fatal.
pub fn envPop(vm: *Vm, env: *?[*]Value, env_len: *i32) VmError!Value {
    if (env_len.* <= 0) {
        if (vm.catch_chain != null and vm.catch_chain.?.in_trap_error)
            return vm.throwShen("runtime: pop empty environment");
        std.debug.panic("runtime: pop empty environment", .{});
    }
    env_len.* -= 1;
    // Same capacity-scan concern as vaPop: clear the vacated env slot.
    const v = env.*.?[@intCast(env_len.*)];
    env.*.?[@intCast(env_len.*)] = values.valNil();
    return v;
}

// =====================================================================
//  exec_primitive — C: zincvm.c:1780-2794 (ported in prims.zig, M5)
// =====================================================================

/// C: zincvm.c:1780-2794 exec_primitive, pure subset — the implementation
/// lives in prims.zig (M5).  DECISION A contract:
///   error.Halt       → caught at the call site → break to done, acc
///                      preserved (C: `exec_primitive(...) < 0 → goto done`);
///   error.ShenError  → propagates up to the enclosing CatchSite chain.
fn execPrimitive(vm: *Vm, name: []const u8, acc: *Value, stack: *types.ValueArray) VmError!void {
    return prims.execPrimitive(vm, name, acc, stack);
}

// =====================================================================
//  The eval loop — C: zincvm.c:3154-3466 vm_exec_env
// =====================================================================

/// C: zincvm.c:3154-3466 vm_exec_env.  THE ROOTING CRUX — see the module
/// doc for the full contract.  Every root push is annotated with its C line;
/// the single defer rootPopTo(entry_wm) covers ALL exits (break-to-done,
/// error.ShenError), replacing C's manual pops and its longjmp discipline.
pub fn vmExecEnv(
    vm: *Vm,
    code_in: ?*types.Instr,
    code_len: i32,
    init_env_in: ?[*]Value,
    init_env_len: i32,
) VmError!Value {
    const g = vm.gc;
    const entry_wm = g.rootWatermark();
    // ONE pop-to for every exit path (plan DECISION A; C: 9 pops at
    // C:3464-3466 + every longjmp site's pop_to).
    defer g.rootPopTo(entry_wm);

    // ---- PROLOGUE: push all root slots BEFORE any allocation (C:3159-3166).
    // &env / &stack.data / &acc are pushed early (while still NULL/nil) so
    // gc_scan_roots reads the CURRENT slot value at collect time — they are
    // reassigned across gc_alloc calls below.  NULL slots pin nothing, so
    // pushing early is safe.
    var code = code_in;
    var init_env = init_env_in;
    g.rootPushPtr(@ptrCast(&code)); // (1) root code across allocs — C:3159
    g.rootPushPtr(@ptrCast(&init_env)); // (2) root init_env across allocs — C:3160
    var stack: types.ValueArray = .{ .data = null, .len = 0, .cap = 0 };
    var env: ?[*]Value = null;
    var env_len: i32 = 0;
    var env_cap: i32 = 0;
    var acc: Value = values.valNil();
    g.rootPushPtr(@ptrCast(&env)); // (3) ROOT_PTR — stable slot for env — C:3167
    g.rootPushPtr(@ptrCast(&stack.data)); // (4) ROOT_PTR — stable slot for stack.data — C:3168
    g.rootPushValue(&acc); // (5) ROOT_VALUE — stable slot for acc — C:3169
    vaInit(g, &stack); // now safe: all slots above are rooted — C:3171

    // ---- initial environment copy (C:3172-3181).  init_env is rooted (2),
    // so post-alloc reads of its elements are fresh.
    if (init_env_len > 0 and init_env != null) {
        env_cap = init_env_len;
        const cap: usize = @intCast(env_cap);
        env = g.allocArray(Value, cap);
        @memcpy(env.?[0..cap], init_env.?[0..cap]);
        env_len = init_env_len;
        if (g.inOldgen(@intFromPtr(env.?))) {
            var j: usize = 0;
            while (j < cap) : (j += 1) {
                if (gc.scan.valueReferencesNursery(g, &init_env.?[j])) {
                    g.dirtyVectorsAdd(env.?);
                    break;
                }
            }
        }
    }

    // ---- call-frame stack (C:3182-3191): one old-gen CALLFRAME_ARRAY per
    // vmExecEnv call (65536 x 48 B ≈ 3 MB, zeroed by the allocator; the
    // explicit C memset is retained for parity).  allocatepage's LASTRESORT
    // may run a full collect HERE with only roots (1)-(5) live — same as C.
    var frame_stack: [*]types.CallFrame =
        g.allocArrayOldgen(types.CallFrame, types.CALL_STACK_DEPTH);
    @memset(frame_stack[0..types.CALL_STACK_DEPTH], std.mem.zeroes(types.CallFrame));
    // C allocates a GC-heap int for frames_sp so it survives longjmp
    // (C:3186-3188).  Zig error unwinding runs defers before this frame
    // dies, so a plain native local is safe (plan DECISION A); the
    // ROOT_CALLFRAME_ARRAY np below is never dereferenced at scan time.
    var frames_sp: i32 = 0;
    g.rootPushCallframeArray(frame_stack, &frames_sp); // (6) — C:3195

    var pc: i32 = 0;
    var cur_code = code; // current body's Instr array head (?*Instr)
    var cur_len: i32 = code_len;
    var instr_count: u64 = 0;
    const instr_limit = vm.instr_limit; // cached once — C:3146-3153 get_instr_limit
    g.rootPushPtr(@ptrCast(&cur_code)); // (7) ROOT_PTR — Instr** — C:3201
    g.rootPushPtr(@ptrCast(&frame_stack)); // (8) ROOT_PTR — CallFrame** — C:3202

    run: while (true) {
        // C:3204-3208 — hard instruction limit.
        instr_count += 1;
        if (instr_count >= instr_limit) {
            diag(
                "[HARD LIMIT] {d} instructions, aborting at pc={d} frames={d}\n",
                .{ instr_limit, pc, frames_sp },
            );
            break :run; // goto done
        }

        // C:3209-3228 — pc out of range: pop a CallFrame and resume in the
        // caller, or finish when the frame stack is exhausted.
        if (pc < 0 or pc >= cur_len) {
            if (frames_sp > 0) {
                frames_sp -= 1;
                const cf = &frame_stack[@intCast(frames_sp)];
                cur_code = cf.code;
                cur_len = cf.code_len;
                pc = cf.pc;
                env = cf.env;
                env_len = cf.env_len;
                env_cap = cf.env_cap;
                vaFree(&stack);
                stack = cf.stack;
                // Release stale GC pointers in the popped slot so the full
                // CALLFRAME_ARRAY drain scan does not keep dead frame envs /
                // stacks reachable until the slot is reused (C:3217-3221).
                cf.env = null;
                cf.stack.data = null;
                cf.stack.len = 0;
                cf.code = null;
                cf.code_len = 0;
                cf.pc = 0;
                continue :run;
            }
            break :run; // frames exhausted — C:3227
        }

        // Re-derived EVERY iteration from the rooted cur_code — never cached
        // across an allocating call (an alloc may evacuate the code array).
        const cur_many: [*]types.Instr = @ptrCast(cur_code.?);
        const in: *types.Instr = &cur_many[@intCast(pc)];

        switch (in.op) {
            // C:3230-3232 — literal loads.
            .number, .string, .symbol, .boolean => {
                acc = in.operand;
                vaPush(g, &stack, acc);
                pc += 1;
            },

            // C:3233-3244 — [prim X]: args already on stack (auto-pushed by
            // loads); execute the primitive, push the result.
            .prim => {
                const pn = if (in.operand.tag == .symbol) values.symSlice(in.operand) else "";
                execPrimitive(vm, pn, &acc, &stack) catch |e| switch (e) {
                    // C: exec_primitive() < 0 → goto done (acc preserved).
                    error.Halt => break :run,
                    // A prim-thrown Shen error unwinds to the catch site.
                    error.ShenError => return error.ShenError,
                };
                vaPush(g, &stack, acc);
                pc += 1;
            },

            // C:3245 — pushmark.
            .pushmark => {
                vaPush(g, &stack, values.valMark());
                pc += 1;
            },

            // C:3246-3263 — grab: env push, or (mark on top) partial
            // application return.
            .grab => {
                if (stack.len > 0 and vaPeek(&stack).tag == .mark) {
                    _ = vaPop(&stack);
                    if (frames_sp > 0) {
                        frames_sp -= 1;
                        const cf = &frame_stack[@intCast(frames_sp)];
                        cur_code = cf.code;
                        cur_len = cf.code_len;
                        pc = cf.pc;
                        env = cf.env;
                        env_len = cf.env_len;
                        env_cap = cf.env_cap;
                        // C:3257 — no va_free here; the current stack array
                        // is simply GC'd later.
                        stack = cf.stack;
                        cf.env = null;
                        cf.stack.data = null;
                        cf.stack.len = 0;
                        cf.code = null;
                        cf.code_len = 0;
                        cf.pc = 0;
                        vaPush(g, &stack, acc); // push return value to caller stack
                    } else break :run;
                } else if (stack.len > 0) {
                    const v = vaPop(&stack);
                    envPush(g, &env, &env_len, &env_cap, v);
                    pc += 1;
                } else pc += 1;
            },

            // C:3264-3346 — apply.
            .apply => {
                if (stack.len > 0) acc = vaPop(&stack); // pop function
                if (acc.tag == .lambda) {
                    // Collect all non-mark args (stop at the mark) —
                    // alloc-free (va_pop/va_peek never allocate).
                    var nargs: i32 = 0;
                    var argbuf: [64]Value = undefined;
                    while (stack.len > 0 and vaPeek(&stack).tag != .mark) {
                        if (nargs < 64) {
                            argbuf[@intCast(nargs)] = vaPop(&stack);
                            nargs += 1;
                        } else {
                            return vm.throwShen("runtime: too many args (>64)");
                        }
                    }
                    // Pop the required mark (zinc-c always emits pushmark).
                    if (stack.len == 0 or vaPeek(&stack).tag != .mark) {
                        diag("runtime: apply missing pushmark\n", .{});
                        break :run;
                    }
                    _ = vaPop(&stack);
                    g.rootPushValueArray(&argbuf, &nargs); // root argbuf BEFORE any alloc below — C:3294

                    if (frames_sp >= types.CALL_STACK_DEPTH) break :run; // C:3296
                    const cf = &frame_stack[@intCast(frames_sp)];
                    frames_sp += 1;
                    cf.code = cur_code;
                    cf.code_len = cur_len;
                    cf.pc = pc + 1;
                    cf.env = env;
                    cf.env_len = env_len;
                    cf.env_cap = env_cap;
                    cf.stack = stack;
                    vaInit(g, &stack); // ALLOC — cf must not be touched after this

                    env = null;
                    env_len = 0;
                    env_cap = 0;

                    const lambda_env_len = acc.payload.lambda.env_len;
                    const new_env_len = lambda_env_len + nargs;
                    const ne = g.allocArray(Value, @intCast(new_env_len));
                    // acc is rooted (5), so acc.lambda.code/env are read
                    // AFTER the alloc and are post-GC fresh (C:3303-3305);
                    // acc.lambda.env stays reachable via the shadow stack.
                    cur_code = acc.payload.lambda.code;
                    cur_len = acc.payload.lambda.code_len;
                    const lambda_env = acc.payload.lambda.env;
                    const ne_is_oldgen = g.inOldgen(@intFromPtr(ne));
                    if (lambda_env_len > 0 and lambda_env != null) {
                        const lel: usize = @intCast(lambda_env_len);
                        @memcpy(ne[0..lel], lambda_env.?[0..lel]);
                        if (ne_is_oldgen) {
                            var j: usize = 0;
                            while (j < lel) : (j += 1) {
                                if (gc.scan.valueReferencesNursery(g, &lambda_env.?[j])) {
                                    g.dirtyVectorsAdd(ne);
                                    break;
                                }
                            }
                        }
                    }
                    var i: usize = 0;
                    while (i < @as(usize, @intCast(nargs))) : (i += 1) {
                        const idx = @as(usize, @intCast(lambda_env_len)) + i;
                        ne[idx] = argbuf[i];
                        if (ne_is_oldgen and gc.scan.valueReferencesNursery(g, &argbuf[i]))
                            g.dirtyVectorsAdd(ne);
                    }
                    env = ne;
                    env_len = new_env_len;
                    env_cap = new_env_len;
                    g.rootPop(); // argbuf — C:3340
                    pc = 0;
                } else if (acc.tag == .prim) {
                    // Function already popped; pop mark before args if present.
                    if (stack.len > 0 and vaPeek(&stack).tag == .mark) _ = vaPop(&stack);
                    const pn = values.primSlice(acc);
                    execPrimitive(vm, pn, &acc, &stack) catch |e| switch (e) {
                        error.Halt => break :run,
                        error.ShenError => return error.ShenError,
                    };
                    vaPush(g, &stack, acc);
                    pc += 1;
                } else {
                    // C:3332-3345 — non-callable: catchable inside
                    // trap-error, hard stop otherwise.
                    if (vm.catch_chain != null and vm.catch_chain.?.in_trap_error)
                        return vm.throwShen("apply non-callable");
                    diag("runtime: apply non-callable tag={d}", .{@intFromEnum(acc.tag)});
                    if (acc.tag == .symbol)
                        diag(" sym='{s}'", .{values.symSlice(acc)});
                    diag(" at pc={d} depth={d}\n", .{ pc, frames_sp });
                    break :run;
                }
            },

            // C:3347-3360 — return: pop the frame, push acc to the caller.
            .ret => {
                if (frames_sp > 0) {
                    frames_sp -= 1;
                    const cf = &frame_stack[@intCast(frames_sp)];
                    cur_code = cf.code;
                    cur_len = cf.code_len;
                    pc = cf.pc;
                    env = cf.env;
                    env_len = cf.env_len;
                    env_cap = cf.env_cap;
                    vaFree(&stack);
                    stack = cf.stack;
                    cf.env = null;
                    cf.stack.data = null;
                    cf.stack.len = 0;
                    cf.code = null;
                    cf.code_len = 0;
                    cf.pc = 0;
                    vaPush(g, &stack, acc); // push return value to caller stack
                } else break :run;
            },

            // C:3361-3364 — access.
            .access => {
                const n: i32 = if (in.operand.tag == .number)
                    @intCast(in.operand.payload.number)
                else
                    in.jmp_target;
                acc = lookupEnv(n, env, env_len);
                vaPush(g, &stack, acc);
                pc += 1;
            },

            // C:3365-3378 — global lookup (defun table; the fallback
            // val_symbol interns on the C heap only — no GC alloc).
            .global => {
                const nm = if (in.operand.tag == .symbol) values.symSlice(in.operand) else "";
                if (nm.len > 0 and !vm.defunHas(nm)) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "global not found: {s}", .{nm})
                        catch "global not found";
                    return vm.throwShen(msg);
                }
                acc = vm.defunGet(nm);
                vaPush(g, &stack, acc);
                pc += 1;
            },

            // C:3379-3383 — let: bind the stack top (or acc).
            .let => {
                const v: Value = if (stack.len > 0) vaPop(&stack) else acc;
                envPush(g, &env, &env_len, &env_cap, v);
                pc += 1;
            },

            // C:3384 — endlet.
            .endlet => {
                if (env_len > 0) _ = try envPop(vm, &env, &env_len);
                pc += 1;
            },

            // C:3385 — jmp.
            .jmp => pc = in.jmp_target,

            // C:3386-3391 — jmpf: pop cond, jump only on boolean false.
            .jmpf => {
                const cond: Value = if (stack.len > 0) vaPop(&stack) else acc;
                if (!(cond.tag == .boolean and cond.payload.boolean == 0)) pc += 1 else pc = in.jmp_target;
            },

            // C:3392-3396 — cur: build the closure.  valLambda roots the
            // code/env ptr slots across its env-copy alloc internally
            // (values.zig, C:299-321).  in->closure_code is read BEFORE that
            // call and `in` is never touched after; the operand stays fresh
            // because cur_code is rooted and `in` is re-derived next
            // iteration.
            .cur => {
                acc = values.valLambda(g, in.closure_code, in.closure_len, env, env_len);
                vaPush(g, &stack, acc);
                pc += 1;
            },

            // C:3397-3461 — appterm: tail-call in the current frame
            // (pc = 0, no new CallFrame — frame reuse).
            .appterm => {
                if (stack.len > 0) acc = vaPop(&stack); // pop function
                if (acc.tag == .lambda) {
                    if (stack.len <= 0) {
                        diag("runtime: appterm empty stack\n", .{});
                        break :run;
                    }
                    var nargs: i32 = 0;
                    var argbuf: [64]Value = undefined;
                    while (stack.len > 0 and vaPeek(&stack).tag != .mark) {
                        if (nargs < 64) {
                            argbuf[@intCast(nargs)] = vaPop(&stack);
                            nargs += 1;
                        } else {
                            return vm.throwShen("runtime: appterm too many args (>64)");
                        }
                    }
                    // zinc-t always emits pushmark — required.
                    if (stack.len == 0 or vaPeek(&stack).tag != .mark) {
                        diag("runtime: appterm missing pushmark\n", .{});
                        break :run;
                    }
                    _ = vaPop(&stack); // pop mark
                    if (nargs == 0) {
                        diag("runtime: appterm zero args\n", .{});
                        break :run;
                    }

                    const lambda_env_len = acc.payload.lambda.env_len;
                    const new_env_len = lambda_env_len + nargs;
                    g.rootPushValueArray(&argbuf, &nargs); // root argbuf before the alloc — C:3421
                    const ne = g.allocArray(Value, @intCast(new_env_len));
                    // cur_code set AFTER the alloc from the rooted acc — the
                    // rooted cur_code slot (7) makes any interim value safe,
                    // and reading acc fresh after the alloc matches C:3423-3425.
                    cur_code = acc.payload.lambda.code;
                    cur_len = acc.payload.lambda.code_len;
                    const lambda_env = acc.payload.lambda.env;
                    const ne_is_oldgen = g.inOldgen(@intFromPtr(ne));
                    if (lambda_env_len > 0 and lambda_env != null) {
                        const lel: usize = @intCast(lambda_env_len);
                        @memcpy(ne[0..lel], lambda_env.?[0..lel]);
                        if (ne_is_oldgen) {
                            var j: usize = 0;
                            while (j < lel) : (j += 1) {
                                if (gc.scan.valueReferencesNursery(g, &lambda_env.?[j])) {
                                    g.dirtyVectorsAdd(ne);
                                    break;
                                }
                            }
                        }
                    }
                    var i: usize = 0;
                    while (i < @as(usize, @intCast(nargs))) : (i += 1) {
                        const idx = @as(usize, @intCast(lambda_env_len)) + i;
                        ne[idx] = argbuf[i];
                        if (ne_is_oldgen and gc.scan.valueReferencesNursery(g, &argbuf[i]))
                            g.dirtyVectorsAdd(ne);
                    }
                    env = ne;
                    env_len = new_env_len;
                    env_cap = new_env_len;
                    g.rootPop(); // argbuf — C:3451
                    pc = 0;
                } else if (acc.tag == .prim) {
                    // Function already popped; pop mark before args if present.
                    if (stack.len > 0 and vaPeek(&stack).tag == .mark) _ = vaPop(&stack);
                    const pn = values.primSlice(acc);
                    execPrimitive(vm, pn, &acc, &stack) catch |e| switch (e) {
                        error.Halt => break :run,
                        error.ShenError => return error.ShenError,
                    };
                    vaPush(g, &stack, acc);
                    pc += 1;
                } else {
                    if (vm.catch_chain != null and vm.catch_chain.?.in_trap_error)
                        return vm.throwShen("appterm non-lambda");
                    diag("runtime: appterm non-lambda\n", .{});
                    break :run;
                }
            },

            // C:3462 — unknown op (OP_COUNT never appears as a real opcode;
            // char_to_opcode maps unknown chars to it at parse time).
            .count => {
                diag("runtime: unknown op {d} at pc={d}\n", .{ @intFromEnum(in.op), pc });
                break :run;
            },
        }
    }

    // done: (C:3463-3468) — the 8 root pops are the defer rootPopTo above;
    // frame_stack is GC-allocated (no free needed); acc is returned.
    vaFree(&stack);
    return acc;
}

/// C: zincvm.c:3470-3472 vm_exec — top-level entry with an empty env.
pub fn vmExec(vm: *Vm, code: ?*types.Instr, code_len: i32) VmError!Value {
    return vmExecEnv(vm, code, code_len, null, 0);
}

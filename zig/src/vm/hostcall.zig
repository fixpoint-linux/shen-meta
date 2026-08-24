//! src/vm/hostcall.zig — host-side calls into BUNDLED closures (milestone M2).
//!
//! C origin: the env-extend call pattern shared by
//!   - zincvm.c:3483-3500 call_closure1 (name + 1 arg),
//!   - zincvm.c:3504-3528 call_closure3 (name + 3 args, per-arg barriers),
//!   - the eval-kl inline stages zincvm.c:2018-2025 / :2034-2041 / :2050-2057
//!     (defun_get → VAL_LAMBDA check → GC_VALUE_ARRAY(env_len+1) → memcpy
//!     env → append arg → barrier → vm_exec_env),
//!   - shensh.c:262-287 call_bundled_0 (nullary + CatchFrame) and
//!     shensh.c:220-252 call_bundled_1 (catching variant).
//!
//! CONVENTION (why the arg rides AFTER the captured env): a bundled closure
//! reads its parameter via `access N`, which indexes the environment from
//! the END (reverse-index lookup) — appending the arg after env_len makes it
//! access 0 exactly like a normal call would have pushed it.
//!
//! TWO FLAVORS (plan M2):
//!   - applyBundledN — NON-catching: resolves, roots fn + args, extends the
//!     env, runs.  error.ShenError propagates to the CALLER's CatchSite —
//!     this is what eval-kl needs (its own site wraps the whole chain).
//!     Returns null when `name` does not resolve to a bundled lambda; the
//!     caller decides the fallback (eval-kl: warn + the input form; the M4
//!     front-end: warn + nil) — the C per-site `tag != VAL_LAMBDA` arms.
//!   - callBundled0/1/3 — CATCHING: pushes a CatchSite, runs the same call,
//!     and on a throw returns the error VALUE (vm.err_slot, rooted once at
//!     Vm.init — the DECISION-A replacement for the C per-frame cf.error_val
//!     + its S3 root).  The caller distinguishes an error via the .error_
//!     tag.  Missing closure → valNil() (C doc shensh.c:259-261: "callers
//!     can distinguish 'missing' from 'returned done'" — nil is neither a
//!     lambda nor a symbol).

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const state = @import("state.zig");
const values = @import("values.zig");
const interp = @import("interp.zig");

const Gc = gc.Gc;
const Value = types.Value;
const Vm = state.Vm;
const VmError = state.VmError;

/// Host-call arg budget: the call sites are 0 (dummy), 1, or 3 args today
/// (call_bundled_0/1/3); 8 leaves headroom without unbounded stack use.
const MAX_HOSTCALL_ARGS = 8;

/// C: zincvm.c:3483-3528 call_closure1/call_closure3 + the eval-kl stages —
/// the shared env-extend pattern, generalized to N args.  ROOTING (C parity):
/// fn + the arg array are rooted across the env allocArray (call_closure1
/// roots g/arg at :3489-3490, call_closure3 roots all four at :3510-3513);
/// ROOT_VALUE_ARRAY is the array form of that discipline (the eval loop's
/// apply/appterm argbuf uses it, C:3294/3421).  Reads of fn.lambda.env/code
/// after the alloc go through the rooted fnv (fresh even if it collected);
/// the two rootPops before the vmExecEnv call never allocate, so reading
/// fnv afterwards is safe (exact C:3497-3499 shape).  The write barrier
/// fires per stored arg that references the nursery into an oldgen env
/// (call_closure3's :3518-3522 per-arg checks, subsuming call_closure1's
/// single-arg check).
pub fn applyBundledN(vm: *Vm, name: []const u8, args: []const Value) VmError!?Value {
    const g = vm.gc;
    std.debug.assert(args.len <= MAX_HOSTCALL_ARGS);
    var fnv = vm.defunGet(name);
    if (fnv.tag != .lambda) return null;

    g.rootPushValue(&fnv);
    var argbuf: [MAX_HOSTCALL_ARGS]Value = undefined;
    var nargs: i32 = 0;
    for (args) |av| {
        argbuf[@intCast(nargs)] = av;
        nargs += 1;
    }
    g.rootPushValueArray(&argbuf, &nargs);

    const env_len = fnv.payload.lambda.env_len;
    const total: i32 = env_len + nargs;
    const env = g.allocArray(Value, @intCast(total));
    const env_is_oldgen = g.inOldgen(@intFromPtr(env));
    if (env_len > 0) {
        const lel: usize = @intCast(env_len);
        const lambda_env = fnv.payload.lambda.env.?;
        @memcpy(env[0..lel], lambda_env[0..lel]);
        // M5 fix: barrier the COPIED env elements too, not just the appended
        // args.  When env lands in old-gen (nursery full) and a captured env
        // element references the nursery, the element is unbarriered and a
        // later scavenge leaves a stale nursery pointer in old-gen — the
        // verify_collects whole-stack rooting proof caught this as type-2
        // violations at first shell-source load.  Mirrors interp.zig apply's
        // copied-env barrier (interp.zig:423-431).
        if (env_is_oldgen) {
            var j: usize = 0;
            while (j < lel) : (j += 1) {
                if (gc.scan.valueReferencesNursery(g, &lambda_env[j])) {
                    g.dirtyVectorsAdd(env);
                    break;
                }
            }
        }
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(nargs))) : (i += 1) {
        const idx = @as(usize, @intCast(env_len)) + i;
        env[idx] = argbuf[i];
        if (env_is_oldgen and gc.scan.valueReferencesNursery(g, &argbuf[i]))
            g.dirtyVectorsAdd(env);
    }
    g.rootPop(); // argbuf
    g.rootPop(); // fnv (pops never allocate — the fnv read below is safe)
    return try interp.vmExecEnv(
        vm,
        fnv.payload.lambda.code,
        fnv.payload.lambda.code_len,
        env,
        total,
    );
}

// =====================================================================
//  Catching flavors — C: shensh.c:220-287 call_bundled_0/1/3
// =====================================================================

/// C: shensh.c:262-287 call_bundled_0 — nullary bundled call (e.g.
/// tc-hm-init).  The env gets a valNumber(0) DUMMY operand slot (the removed
/// --tc-hm driver convention; a grab on an empty stack is a no-op, so the
/// dummy is never read).  Catching: error.ShenError → vm.err_slot; missing
/// closure → nil.  (In practice only ShenError can escape applyBundledN —
/// vmExecEnv contains error.Halt at its own call sites — so the bare `catch`
/// never swallows a hard stop.)
pub fn callBundled0(vm: *Vm, name: []const u8) Value {
    var site = state.CatchSite{ .in_trap_error = false, .parent = vm.catch_chain };
    vm.catch_chain = &site;
    const r = applyBundledN(vm, name, &.{values.valNumber(0)}) catch {
        vm.catch_chain = site.parent;
        return vm.err_slot;
    };
    vm.catch_chain = site.parent;
    return r orelse values.valNil();
}

/// C: shensh.c:220-252 call_bundled_1 — single-argument bundled call, with
/// the CatchFrame (CatchSite here) around the vmExecEnv only.  On a throw
/// the error value is caught and returned (caller decides warn/abort).
pub fn callBundled1(vm: *Vm, name: []const u8, arg: Value) Value {
    var site = state.CatchSite{ .in_trap_error = false, .parent = vm.catch_chain };
    vm.catch_chain = &site;
    const r = applyBundledN(vm, name, &.{arg}) catch {
        vm.catch_chain = site.parent;
        return vm.err_slot;
    };
    vm.catch_chain = site.parent;
    return r orelse values.valNil();
}

/// C: shensh.c:292-313 call_closure3 — three-argument bundled call (the
/// reader convention: shen-parse-exprs takes Str Pos Len).
pub fn callBundled3(vm: *Vm, name: []const u8, a: Value, b: Value, c: Value) Value {
    var site = state.CatchSite{ .in_trap_error = false, .parent = vm.catch_chain };
    vm.catch_chain = &site;
    const r = applyBundledN(vm, name, &.{ a, b, c }) catch {
        vm.catch_chain = site.parent;
        return vm.err_slot;
    };
    vm.catch_chain = site.parent;
    return r orelse values.valNil();
}

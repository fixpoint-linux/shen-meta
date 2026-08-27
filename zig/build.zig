const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // The Shen VM + GC are compiled per-optimize-mode inside addGcTestSet /
    // addVmTestSet below (b.createModule, so each mode gets an independent
    // module carrying its own .optimize).  The fx-ui demo executable (root.zig
    // / main.zig) is dropped from this tree; the GC/VM test sets, the `gate`
    // step and the `shensh` front-end exe step (plan M4) remain.

    // A top level step for running all tests (gc + vm in the current mode).
    const test_step = b.step("test", "Run tests (gc + vm, honours -Doptimize)");

    // M1: -Dno-exec compiles the test binaries for the chosen target but
    // skips running them.  Zig 0.16 has no `zig build --test-no-exec` flag
    // (that's a `zig test` flag, not a `zig build` flag), so the wasm compile
    // gate uses this option: `zig build test -Dtarget=wasm32-freestanding
    // -Dno-exec=true`.  The test binaries are compiled+linked (the gate — a
    // posix/freestanding reference surfaces at compile or link), but the Run
    // steps are replaced by their underlying Compile steps so nothing execs.
    const no_exec = b.option(bool, "no-exec", "Compile test binaries but skip running them (cross-compile-only gate)") orelse false;

    // ---- Shen GC test step + permanent multi-mode gate (units A-C) ----
    // addGcTestSet creates a fully self-contained gc module + gc_test module +
    // addTest + run + T9 expected-panic exe for ONE hardcoded optimize mode,
    // and returns the run step.  std.debug.assert inside the gc module is gated
    // by THAT module's own optimize, so the same source is exercised under
    // every mode the gate cares about — that is what makes ReleaseSafe a real
    // safety gate rather than a Debug-only check.
    const gc_test_step = b.step("gc-test", "Run Shen GC tests (honours -Doptimize)");
    gc_test_step.dependOn(addGcTestSet(b, target, optimize, no_exec));
    test_step.dependOn(gc_test_step);

    // ---- Shen VM test step (plan M0): same shape as gc-test. ----
    const vm_test_step = b.step("vm-test", "Run Shen VM tests (honours -Doptimize)");
    vm_test_step.dependOn(addVmTestSet(b, target, optimize, no_exec));
    test_step.dependOn(vm_test_step);

    // ---- `gate`: the permanent ReleaseSafe build gate (unit C) ----
    // Runs the full Shen GC + VM suites in Debug + ReleaseSafe + ReleaseFast in
    // one command.  ReleaseSafe keeps std.debug.assert live, so every
    // safety-enforcement added in the GC units B/E is proven under the gate,
    // not just in Debug.
    const gate_step = b.step("gate", "Run Shen GC + VM tests in Debug + ReleaseSafe + ReleaseFast");
    gate_step.dependOn(addGcTestSet(b, target, .Debug, false));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseSafe, false));
    gate_step.dependOn(addGcTestSet(b, target, .ReleaseFast, false));
    gate_step.dependOn(addVmTestSet(b, target, .Debug, false));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseSafe, false));
    gate_step.dependOn(addVmTestSet(b, target, .ReleaseFast, false));

    // ---- `shensh`: the front-end executable (plan M4) ----
    // NAMED STEP ONLY — NEVER part of the default install step (the default
    // install hits PermissionDenied on zig-out in this sandbox; gate/test
    // are the top-level entry points).  `zig build shensh -p <prefix>` puts
    // the exe at <prefix>/bin/shensh.  Honours -Doptimize like everything
    // else.  The exe links libc (the M3 process-layer externs in
    // vm/execplan.zig + the front-end's raw read/write on fds 0/1/2).
    // M5: optional verify_collects flag for the shensh exe (GC stress
    // build).  Passed through addShenshExe as an options module the
    // front-end reads at boot (shensh_main.zig sets Gc Options
    // .verify_collects from it).  Off by default; the exe step is a named
    // step only (never the default install).
    const verify_collects = b.option(bool, "verify-collects", "Enable Gc.Options.verify_collects in the shensh front-end exe (whole-stack precise-rooting proof)") orelse false;

    const shensh_step = b.step("shensh", "Build the shensh front-end executable (named step only; use -p <prefix>)");
    shensh_step.dependOn(addShenshExe(b, target, optimize, verify_collects));

    // ---- `zincdec`: the bytecode decompiler (plan M0) ----
    // NAMED STEP ONLY — NEVER part of the default install step.  GC-free
    // standalone tool: a self-contained port of vm/zincdec.c that parses a
    // globals.csexp bundle and decompiles individual closures.  It does NOT
    // import the VM/GC modules (which require a booted Gc) and needs NO libc
    // (pure std.heap.ArenaAllocator + std.fs).  `zig build zincdec -p <prefix>`
    // puts the exe at <prefix>/bin/zincdec.
    const zincdec_step = b.step("zincdec", "Build the zincdec bytecode decompiler executable (named step only; use -p <prefix>)");
    zincdec_step.dependOn(addZincdecExe(b, target, optimize));

    // ---- `wasm`: the wasm32-freestanding front-end (plan M2) ----
    // NAMED STEP ONLY — NEVER part of the default install step.  Builds
    // shen-wasm.wasm (wasm32-freestanding, no libc, no WASI) — the browser
    // front-end with embedded globals.csexp bundle.  `zig build wasm -p
    // <prefix>` puts the .wasm at <prefix>/bin/shen-wasm.wasm.
    const wasm_step = b.step("wasm", "Build the wasm32-freestanding front-end (named step only; use -p <prefix>)");
    wasm_step.dependOn(addWasmExe(b, optimize));

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// SAFETY-ENFORCEMENT (unit C): build one self-contained Shen GC test set
/// compiled at `opt` and return its run step.  Because each mode needs its own
/// gc module (std.debug.assert inside the collector is gated by that module's
/// optimize), every call builds an independent gc_mod + gc_test_mod + addTest +
/// run + T9 expected-panic exe.  Named top-level modules (b.addModule) are NOT
/// used here to avoid duplicate "gc" module names across the 3 gate instances;
/// the unnamed modules (b.createModule) carry their own .optimize.
fn addGcTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    no_exec: bool,
) *std.Build.Step {
    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = opt,
    });

    if (no_exec) {
        // Compile-only gate (M1 wasm): build the GC module as a static
        // library for the target.  This compiles every GC source file
        // (types/heap/collect/roots/scan) for the chosen target WITHOUT
        // pulling the std test runner (which needs std.Io on freestanding —
        // an M2 concern) or the native-only test helpers.  A missed comptime
        // gate in the GC surfaces here at compile time.
        const gc_lib = b.addLibrary(.{
            .name = b.fmt("gc-compile-{s}", .{@tagName(opt)}),
            .root_module = gc_mod,
        });
        return &gc_lib.step;
    }

    const gc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc_test.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });
    const gc_tests = b.addTest(.{ .root_module = gc_test_mod });

    // ---- T9: expected-panic executable (plan DECISION 7) ----
    // Zig 0.16 has no in-process panic assertion, so the ROOT_PTR
    // interior-pointer defense (gc.c:1527-1539) is proven by a tiny exe that
    // overrides its root panic handler, matches the defense message, and
    // exits 42; the Run step expects exactly that.  Panic exit paths through
    // abort() are signal-based (nondeterministic for expect_term), hence the
    // handler-normalized exit code.
    const t9_mod = b.createModule(.{
        .root_source_file = b.path("tests/root_ptr_panic.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });
    const t9_exe = b.addExecutable(.{
        .name = "gc_root_ptr_panic",
        .root_module = t9_mod,
    });

    const run_gc_tests = b.addRunArtifact(gc_tests);

    const run_t9 = b.addRunArtifact(t9_exe);
    run_t9.expectExitCode(42);

    // The T9 exe runs as part of this mode's gc-test set (before the tests).
    run_gc_tests.step.dependOn(&run_t9.step);

    return &run_gc_tests.step;
}

/// Build one self-contained Shen VM test set compiled at `opt` and return its
/// run step (plan M0, mirroring addGcTestSet).  Each mode gets its OWN unnamed
/// gc module + vm module + vm_test module (b.createModule, so no top-level
/// "gc"/"vm" module-name clashes across the gate's three instances); the vm
/// module imports the mode's gc module and the vm_test module imports both.
fn addVmTestSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    no_exec: bool,
) *std.Build.Step {
    // M1 wasm gate: freestanding has no libc, and the process-layer externs
    // in vm/execplan.zig are comptime-gated out on wasm (is_wasm), so the
    // test binary needs no libc link on wasm32-freestanding.  wasi keeps
    // libc.  Native keeps the prior `link_libc = true`.
    const is_wasm = target.result.cpu.arch.isWasm();

    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = opt,
    });

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = opt,
        // M3: vm/execplan.zig declares the process-layer libc externs
        // (fork/execvp/pipe/dup2/mkstemp/waitpid/fnmatch/...); the test
        // binaries must link libc on native/wasi.  On wasm32-freestanding
        // those handlers are comptime-gated to throwShen stubs (M1), so no
        // libc link is needed.
        .link_libc = !is_wasm,
        .imports = &.{ .{ .name = "gc", .module = gc_mod } },
    });

    const vm_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/vm_test.zig"),
        .target = target,
        .optimize = opt,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    const vm_tests = b.addTest(.{ .root_module = vm_test_mod });

    if (no_exec) {
        // Compile-only gate (M1 wasm): build the VM module as a static
        // library for the target.  This compiles every VM source file
        // (state/streams/execplan/parser/prims/...) + transitively the GC
        // module, for the chosen target, WITHOUT the std test runner (which
        // needs std.Io on freestanding) or the native-only test helpers
        // (tests/vm_test.zig has extern "c" getcwd/nanosleep/mkdir +
        // std.posix.system.unlink for the M3 process tests — native-only).
        // A missed comptime gate in the VM surfaces here at compile time.
        const vm_lib = b.addLibrary(.{
            .name = b.fmt("vm-compile-{s}", .{@tagName(opt)}),
            .root_module = vm_mod,
        });
        return &vm_lib.step;
    }

    const run_vm_tests = b.addRunArtifact(vm_tests);

    return &run_vm_tests.step;
}

/// Build the shensh front-end executable at `opt` and return its INSTALL
/// step (plan M4).  The install step is returned (not added to the default
/// install) so the exe is only built/installed through the named `shensh`
/// step — `zig build` alone never writes to zig-out.  Owns an independent
/// unnamed gc + vm module pair per invocation (no top-level module-name
/// clashes with the gate's three test-set instances).
fn addShenshExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    verify_collects: bool,
) *std.Build.Step {
    // M1 wasm gate: same as addVmTestSet — freestanding has no libc; the
    // process-layer externs + the front-end's raw fd read/write are comptime-
    // gated on wasm.  (M2's wasm front-end is a separate exe root that does
    // NOT use this shensh module path; this keeps the native shensh build
    // link_libc=true and the wasm test build link_libc=false.)
    const is_wasm = target.result.cpu.arch.isWasm();

    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = opt,
    });

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = opt,
        // vm/execplan.zig declares the process-layer libc externs; the exe
        // links libc on native/wasi.  On wasm32-freestanding the handlers are
        // comptime-gated (M1), so no libc link is needed.
        .link_libc = !is_wasm,
        .imports = &.{.{ .name = "gc", .module = gc_mod }},
    });

    // M5: build-options module carrying the verify-collects flag (off by
    // default) so the front-end can enable the whole-stack precise-rooting
    // proof on demand.
    const opts = b.addOptions();
    opts.addOption(bool, "verify_collects", verify_collects);
    const opts_mod = opts.createModule();

    const shensh_mod = b.createModule(.{
        .root_source_file = b.path("src/shensh_main.zig"),
        .target = target,
        .optimize = opt,
        // The front-end uses raw libc read/write on fds 0/1/2 (stdio
        // coexistence with the read-byte prim — see shensh_main.zig's
        // module doc) and std.process.exit goes through libc.  On wasm32
        // freestanding those paths are comptime-gated; no libc link.
        .link_libc = !is_wasm,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
            .{ .name = "build_options", .module = opts_mod },
        },
    });
    const shensh_exe = b.addExecutable(.{
        .name = "shensh",
        .root_module = shensh_mod,
    });
    // addInstallArtifact creates the InstallArtifact step WITHOUT hooking
    // it into the default install (only b.installArtifact does that).
    const install_shensh = b.addInstallArtifact(shensh_exe, .{});
    return &install_shensh.step;
}

/// Build the zincdec bytecode-decompiler executable at `opt` and return its
/// INSTALL step (plan M0).  A GC-free standalone tool (mirror of the C
/// vm/zincdec.c) that parses a globals.csexp bundle and decompiles closures.
/// It is deliberately self-contained: it does NOT import the VM/GC modules
/// (which require a booted Gc + interner) and needs no libc.  Named step only
/// (never part of the default install) so `zig build` alone never writes to
/// zig-out.
fn addZincdecExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    const zincdec_mod = b.createModule(.{
        .root_source_file = b.path("src/zincdec_main.zig"),
        .target = target,
        .optimize = opt,
    });
    const zincdec_exe = b.addExecutable(.{
        .name = "zincdec",
        .root_module = zincdec_mod,
    });
    // addInstallArtifact creates the InstallArtifact step WITHOUT hooking it
    // into the default install (only b.installArtifact does that).
    const install_zincdec = b.addInstallArtifact(zincdec_exe, .{});
    return &install_zincdec.step;
}

/// Build the wasm32-freestanding front-end executable and return its INSTALL
/// step (plan M2).  The wasm module targets wasm32-freestanding (no libc, no
/// WASI): the browser front-end with an embedded globals.csexp bundle
/// (@embedFile in wasm_main.zig).  Named step only (never part of the
/// default install) so `zig build` alone never writes to zig-out.  Owns an
/// independent unnamed gc + vm module pair.  The vm module is link_libc=false
/// (freestanding has no libc; the process-layer externs in execplan.zig are
/// comptime-gated to throwShen stubs on wasm — M1).
fn addWasmExe(
    b: *std.Build,
    opt: std.builtin.OptimizeMode,
) *std.Build.Step {
    // Fixed wasm32-freestanding target (NOT the standard target options —
    // this step always builds for the browser, regardless of -Dtarget).
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = wasm_target,
        .optimize = opt,
        .pic = true, // shared-lib wasm needs PIC data relocations (R_WASM_MEMORY_ADDR)
    });

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = wasm_target,
        .optimize = opt,
        // freestanding: no libc.  The process-layer externs in
        // execplan.zig are comptime-gated (M1), so no libc link.
        .link_libc = false,
        .pic = true,
        .imports = &.{.{ .name = "gc", .module = gc_mod }},
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_main.zig"),
        .target = wasm_target,
        .optimize = opt,
        .link_libc = false,
        .pic = true,
        .imports = &.{
            .{ .name = "gc", .module = gc_mod },
            .{ .name = "vm", .module = vm_mod },
        },
    });
    // Force the shen_* entrypoints into the export table.  A wasm
    // executable with -fno-entry strips ALL function exports (dead-code
    // elided — only `memory` is exported), so without these the JS
    // driver cannot see shen_boot/shen_eval_line/...  `--export=<name>`
    // retains + exports each one (replaces the earlier -dynamic shared-
    // lib hack, which tripped a wasm-ld "-shared not yet stable" warning
    // that Zig treats as a fatal link error).
    wasm_mod.export_symbol_names = &.{
        "shen_boot",
        "shen_eval_line",
        "shen_take_out",
        "shen_alloc",
        "shen_free",
    };

    // @embedFile("globals.csexp") in wasm_main.zig needs the bundle in
    // zig/src/ (the module's package path).  The repo-root globals.csexp
    // is outside the package path and cannot be @embedFile'd directly.
    // CI's build-wasm-zig.sh (M3) copies it; M4 teardown can symlink it.
    _ = b.path("../globals.csexp"); // documents the source path

    const wasm_exe = b.addExecutable(.{
        .name = "shen-wasm",
        .root_module = wasm_mod,
    });
    // No entry point (no `main`): the module is driven purely from JS via the
    // exported shen_* entrypoints, so drop _start entirely (-fno-entry).
    wasm_exe.entry = .disabled;
    // Freestanding wasm modules loaded from JS (WebAssembly.instantiate) need
    // an export TABLE of the @export fns (shen_boot/shen_eval_line/...);
    // export_symbol_names makes each one reachable.  (The earlier -dynamic
    // shared-lib build worked but tripped a wasm-ld "-shared not yet stable"
    // warning that Zig escalates to a fatal link error.)
    // addInstallArtifact creates the InstallArtifact step WITHOUT hooking it
    // into the default install (only b.installArtifact does that).
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    return &install_wasm.step;
}

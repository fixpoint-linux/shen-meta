.PHONY: all vm test bundle pipeline interp setup clean gate gcdebug gc-verify qbe-gc-verify tc-hm tc-hm-self tc-hm-tests gen-prims gen-qbe-subset qbe-tool qberun qberepl qbe-smoke qbe-gen qbe-gen-prims qbe-test diff-test gen-symbol-static

SHEN   = vendor/shen-scheme/bin/shen-scheme
CFLAGS = -Wall -Wextra -O2 -I vm

all: zincvm zincdec zinctest

# cosmocc produces a fat APE plus cross-build intermediates (.com.dbg,
# .aarch64.elf) alongside the output.  Stage those in a temp dir so they never
# land in the repo; only the native x86_64 ELF (.com.dbg) is copied out as the
# final binary.  Leaves the working dir unpolluted by build products.

# $1 = final binary path (zincvm / zincdec / zinctest ...), $2 = extra CFLAGS
define compile-vm
	@T=$$(mktemp -d /tmp/$(notdir $(1)).build.XXXXXX) && \
	cosmocc $(2) -o $$T/out.ape $(3) && \
	cp $$T/out.ape.com.dbg $(1) && chmod 755 $(1); \
	st=$$?; rm -rf $$T; exit $$st
endef

# gen-symbol-static: generate the static symbol intern table (vm/symbol_static.{h,c})
# from the reduced bundle's symbol literals, using a minimal perfect hash.  The
# output is COMMITTED so `make zincvm` builds standalone; it is regenerated only
# when globals.csexp is present and newer (mirrors gen-qbe-subset).
gen-symbol-static: tools/gen-symbol-static.py globals.csexp
	@if [ globals.csexp -nt vm/symbol_static.c ]; then \
		python3 tools/gen-symbol-static.py; \
	else \
		echo "symbol_static.c up to date"; \
	fi

zincvm: vm/zincvm.c vm/gc.c vm/gc.h vm/zinctypes.h vm/zincvm.h vm/symbol_static.c vm/symbol_static.h
	$(call compile-vm,$@,$(CFLAGS),vm/zincvm.c vm/gc.c vm/symbol_static.c)

zincvm-asan: vm/zincvm.c vm/gc.c vm/gc.h vm/zinctypes.h vm/zincvm.h vm/symbol_static.c vm/symbol_static.h
	$(call compile-vm,$@,$(CFLAGS) -O0 -g -fsanitize=undefined,vm/zincvm.c vm/gc.c vm/symbol_static.c)

zincdec: vm/zincdec.c
	$(call compile-vm,$@,$(CFLAGS),vm/zincdec.c)

zinctest: vm/zinctest.c vm/zincvm.c vm/gc.c vm/gc.h vm/zinctypes.h vm/zincvm.h vm/symbol_static.c vm/symbol_static.h
	$(call compile-vm,$@,$(CFLAGS) -DZINCTEST,vm/zinctest.c vm/zincvm.c vm/gc.c vm/symbol_static.c)

# GC-observable test binary: -O0 -g with no optimization so GC diag flags
# (--gc-verbose etc.) show addresses/backtraces usefully.  The guard-enabled
# debug build was removed, so this is a plain -O0 -g build of the same code.
zinctest-gc: vm/zinctest.c vm/zincvm.c vm/gc.c vm/gc.h vm/zinctypes.h vm/zincvm.h vm/symbol_static.c vm/symbol_static.h
	$(call compile-vm,$@,-Wall -Wextra -O0 -g -DZINCTEST -I vm,vm/zinctest.c vm/zincvm.c vm/gc.c vm/symbol_static.c)

zinctest-asan: vm/zinctest.c vm/zincvm.c vm/gc.c vm/gc.h vm/zinctypes.h vm/zincvm.h vm/symbol_static.c vm/symbol_static.h
	$(call compile-vm,$@,$(CFLAGS) -O0 -g -fsanitize=undefined -DZINCTEST,vm/zinctest.c vm/zincvm.c vm/gc.c vm/symbol_static.c)

clean:
	rm -f zincvm zincdec zincvm-asan zinctest zinctest-gc zinctest-asan *.csexp globals.csexp

test: zinctest
	./zinctest

# GC debugging tooling helper.  Builds the zinctest-gc target (-O0 -g, no
# ZINCVM_DEBUG — the guard-enabled debug build was removed) and lists the
# opt-in observability flags that zinctest/zincvm accept at runtime.
# No semantics change — this is pure per-run diagnostics.
gcdebug: zinctest-gc
	@echo ""
	@echo "GC debug tooling (opt-in argv flags; all write to stderr):"
	@echo "  --gc-verbose         per-collection stats: [GC NURSERY/FULL #N] trigger/shadow_depth/live/free"
	@echo "  --gc-check-closures  validate code/env headers on each closure entry (APPLY/APPTERM)"
	@echo "  --gc-dump-roots      dump the precise-root shadow stack at each collection"
	@echo "  --gc-stale-scan      scan the C stack for pointers into dead old-gen/nursery space"
	@echo "  --gc-page-transition        log every space[] reclassification (page old->new space + backtrace)"
	@echo "  --gc-page-transition-watch <page>  only log transitions of a specific page"
	@echo "  --gc-watch-alloc <addr>     log every allocation/move of the object at <addr> (with backtrace)"
	@echo "  --gc-verify                 run heap invariant check after each collection"
	@echo "  --gc-verify-codechains   walk closure code chains from roots; flag ptrs into dead space"
	@echo "  --gc-log <path>      write opt-in GC diagnostics to <path> instead of stderr"
	@echo "  --trace <name>       (existing) trace a closure's bytecode execution"
	@echo ""
	@echo "Example: ./zinctest globals.csexp --gc-verbose --gc-check-closures --gc-dump-roots"
	@echo "         ./zinctest-gc globals.csexp --gc-verbose"

test-asan: zinctest-asan
	./zinctest-asan

gate: test test-asan

asan: zinctest-asan
	./zinctest-asan globals.csexp

# gen-prims: generate the Shen primitive?-names list from the single source
# vm/prims.def (X-macro).  Emits shen/prims-generated.shen:
#   (set primitive?-names [ name1 name2 ... ])
# Loaded at bundle-build time (serialize-reduced.shen) and
# mirrored into the C VM's value table by vm_load_bundle, so the C primitive
# set (prim_names[], built from the same prims.def) and Shen's primitive?
# predicate stay in sync automatically.
gen-prims: vm/prims.def
	@printf '(set primitive?-names [' > shen/prims-generated.shen
	@awk '/^[ \t]*PRIM\(/ { match($$0, /PRIM\("[^"]*"/); printf " %s", substr($$0, RSTART+6, RLENGTH-7) }' vm/prims.def >> shen/prims-generated.shen
	@printf '])\n' >> shen/prims-generated.shen

# gen-qbe-subset: generate the Shen closure list for the QBE lowerer from the
# authoritative first-order partition tools/bundle-verify/out/first_order.csv
# (the sound QBE-compilable set, = top_first_order over the reduced bundle).
# Mirrors gen-prims: emits shen/qbe-first-order.shen as plain data:
#   (set qbe-first-order-closures [ name1 name2 ... ])
# Loaded by serialize-qbe.shen so the QBE consumer selects closures from the
# partition (single source of truth) instead of a manual hand-picked list.
#
# first_order.csv is itself a generated souffle output (make bundle-verify),
# so it may be absent on a fresh checkout.  In that case the committed
# shen/qbe-first-order.shen is used unchanged (it is regenerated whenever the
# csv is present and newer).
gen-qbe-subset:
	@if [ -f tools/bundle-verify/out/first_order.csv ] && \
	   [ tools/bundle-verify/out/first_order.csv -nt shen/qbe-first-order.shen ]; then \
		printf '(set qbe-first-order-closures [' > shen/qbe-first-order.shen; \
		awk -F, 'NR>1 { printf " %s", $$1 }' tools/bundle-verify/out/first_order.csv >> shen/qbe-first-order.shen; \
		printf '])\n' >> shen/qbe-first-order.shen; \
	fi

bundle: gen-prims shen/serialize-reduced.shen
	$(SHEN) script shen/serialize-reduced.shen 2>/dev/null
	@echo "Bundle written to globals.csexp ($$(wc -c < globals.csexp) bytes)"

run-bundle: zinctest globals.csexp
	./zinctest globals.csexp

# HM type checker targets.  tc-hm runs the checker on the 6 Group A source
# files (existing 58-OK baseline).  tc-hm-self rebuilds the bundle (so the
# run-tc-hm-self driver lands in globals.csexp) and runs the checker on its
# own 7 tc-hm*.shen source files.  tc-hm-tests rebuilds the bundle and runs
# the ~68 synthetic unit tests (opt-in, not gating).
tc-hm: zincvm globals.csexp
	./zincvm globals.csexp --tc-hm

tc-hm-self: zincvm bundle
	./zincvm globals.csexp --tc-hm-self

tc-hm-tests: zincvm bundle
	./zincvm globals.csexp --tc-hm-tests

pipeline: zincvm
	@$(SHEN) eval -e '(tc -)' \
	  -l shen/normalize.shen -l shen/zinc.shen -l shen/compile.shen \
	  -e '(define compile-expr X -> (zinc->native (zinc-c (debruijn [] (normalize-term (kmacros X))))))' \
	  -e '(compile-expr [+ 1 2])' 2>/dev/null | tail -1 > /tmp/test1.csexp
	./zincvm /tmp/test1.csexp

interp:
	$(SHEN) script shen/interp.shen

# GC-safety verifier — opt-in, not gating.  See docs/gc-verify.md.
gc-verify:
	@if ! command -v clang >/dev/null 2>&1; then \
		echo "gc-verify: skipping (clang not found — install clang >= 14)"; \
	elif ! command -v souffle >/dev/null 2>&1; then \
		echo "gc-verify: skipping (souffle not found)"; \
	else \
		$(MAKE) -C tools/gc-verify run; \
	fi

# qbe-gc-verify: GC-root-safety verifier for the QBE native closures
# (globals.qbe).  Opt-in, not gating.  Requires souffle (Python stdlib only;
# no clang — parses the QBE IR text, unlike gc-verify's C AST).  Mirrors
# tools/gc-verify.  Flags root_miss: live GC-managed Values held in unrooted
# native-stack slots across a collecting call.  Currently reports ~306K sites
# across 815/913 closures — the QBE backend emits no shadow-stack roots.
qbe-gc-verify: globals.qbe
	@if ! command -v souffle >/dev/null 2>&1; then \
		echo "qbe-gc-verify: skipping (souffle not found)"; \
	else \
		$(MAKE) -C tools/qbe-gc-verify run; \
	fi

# Bundle safe-subset verifier — opt-in, not gating.  Requires souffle.
# See docs/bundle-verify.md and tools/bundle-verify/.
bundle-verify:
	@if ! command -v souffle >/dev/null 2>&1; then \
		echo "bundle-verify: skipping (souffle not found)"; \
	else \
		$(MAKE) -C tools/bundle-verify run; \
	fi

# Build the vendored QBE backend (pinned in vendor/qbe). QBE has its own
# Makefile/CFLAGS (not -Werror-clean) — do not use the project CFLAGS here.
# Produces vendor/qbe/obj/qbe, the .qbe -> asm assembler. Used by qberun.
qbe-tool:
	$(MAKE) -C vendor/qbe

# Cosmo cross-assemblers + linker driver (used by the qberun / qbe-smoke
# targets).  cosmocc may be on PATH or under ~/.local/cosmo or /usr/local/cosmo
# (sandbox vs host layouts differ); resolve its dir dynamically so the
# x86_64-/aarch64-linux-cosmo-as companions are found wherever it lives.
COSMOCC  := $(shell command -v cosmocc || echo /usr/local/cosmo/bin/cosmocc)
# The cosmo cross-assemblers (x86_64-/aarch64-linux-cosmo-as) live in the
# toolchain's own bin dir (/usr/local/cosmo/bin).  cosmocc itself may be a
# thin wrapper in /usr/local/bin (or on PATH), so resolve the assembler dir
# from the real toolchain location, falling back to cosmocc's dir.
COSMOAS  := $(shell if [ -x /usr/local/cosmo/bin/x86_64-linux-cosmo-as ]; then echo /usr/local/cosmo/bin/; else echo $(dir $(COSMOCC)); fi)
# Single-arch (amd64-only) cosmopolitan compiler, used by the qberun target.
# Lives in the toolchain's own bin dir, which may not be on PATH.
COSMO_CC := $(shell command -v x86_64-unknown-cosmo-cc || echo /usr/local/cosmo/bin/x86_64-unknown-cosmo-cc)

# qbe-gen-prims: generate the C prim_<F> shims (vm/qbe_prims_gen.{h,c}) and the
# Shen prim-name table (shen/qbe-prim-info.shen) from the single source of
# truth vm/qbe-prims.list.  Keeps the lowerer and the C shims in agreement.
qbe-gen-prims: tools/qbe-gen-prims.awk vm/qbe-prims.list
	awk -f tools/qbe-gen-prims.awk vm/qbe-prims.list

# qbe-gen: run the Slice-3 lowerer over the reduced bundle's global-table,
# emitting QBE IR for the first-order static closures (from the authoritative
# first_order.csv partition) into globals.qbe.
qbe-gen: gen-prims gen-qbe-subset qbe-gen-prims shen/serialize-qbe.shen shen/qbe.shen shen/qbe-subset.shen shen/qbe-first-order.shen shen/os-helpers.shen tools/qbe-gen-traps.awk
	$(SHEN) script shen/serialize-qbe.shen
	awk -f tools/qbe-gen-traps.awk globals_trap.list > globals_trap.c
	@echo "QBE IR written to globals.qbe ($$(wc -c < globals.qbe) bytes)"
	@echo "Trap shims written to globals_trap.c ($$(wc -l < globals_trap.c) lines)"

# qberun: assemble+link the generated globals.qbe (the linkable-closed subset
# of the first-order partition) against the C runtime (qberun.c + qbe_shims.c
# + qbe_prims_gen.c + zincvm.c + gc.c) into the native x86_64 cosmo ELF that
# runs the 5 differential tests (see vm/qberun.c).
#
# NOTE: this builds the amd64 target ONLY, via x86_64-unknown-cosmo-cc (the
# single-arch variant of cosmocc) — NOT the dual-arch fat APE.  Lowering the
# full first-order partition exposes closures with stack frames larger than
# the 12-bit / 32KB immediates QBE's arm64 backend emits (prologue
# `sub sp,sp,#N`, Oaddr, callee-saved str/ldr), so the aarch64 cross-slice of a
# fat APE no longer assembles.  The differential tests run on this x86_64 host,
# so the native amd64 cosmo ELF is sufficient; a cross-arch fat APE of the full
# QBE output is deferred (needs QBE arm64 large-frame support or lowerer
# frame-size reduction).  qbe-smoke still builds the dual-arch fat APE (its
# small add12.qbe has no large frames).
qberun: qbe-tool qbe-gen vm/qberun.c vm/qbe_shims.c vm/qbe_shims.h vm/qbe_prims_gen.c vm/qbe_prims_gen.h vm/zincvm.c vm/gc.c vm/symbol_static.c vm/symbol_static.h globals.qbe globals_trap.c
	@T=$$(mktemp -d /tmp/qberun.build.XXXXXX) && \
	vendor/qbe/obj/qbe -t amd64_sysv -o $$T/globals.s globals.qbe && \
	$(COSMOAS)/x86_64-linux-cosmo-as  -o $$T/globals.o $$T/globals.s && \
	$(COSMO_CC) -Wall -Wextra -O2 -I vm -DZINCTEST -o $$T/qberun \
		vm/qberun.c vm/qbe_shims.c vm/qbe_prims_gen.c vm/zincvm.c vm/gc.c vm/symbol_static.c globals_trap.c $$T/globals.o -lm && \
	cp $$T/qberun qberun && chmod 755 qberun; \
	st=$$?; rm -rf $$T; exit $$st

# qbe-test: build + run the 4 differential tests (Tests 1-4 vs zincvm).
qbe-test: qberun
	./qberun

# diff-test: Slice-4 differential harness — builds qberun (QBE native closures
# linked against the C runtime), ensures globals.csexp is present (the bundled
# closures the reference runs), then runs the driver: each of the 5 tests is
# evaluated BOTH natively (clo_*) and as the C VM interpreter reference
# (interp_ref -> defun_get + vm_exec_env with the same args), asserting MATCH.
diff-test: qberun globals.csexp
	./qberun

# qberepl: build the Shen REPL on the QBE-NATIVE meta-interpreter.  Same link
# shape as qberun (QBE objects from globals.qbe against the C runtime), but the
# driver vm/qberepl.c loads the Shen OS .kl into the meta-interpreter via the
# native clo_interp_load_raw, then runs (shen.initialise)/(shen.repl) through
# the native extract-kl/kl->zinc/toplevel-interp closures.  Run: ./qberepl
# (feed it Shen forms on stdin; EOF exits).
qberepl: qbe-tool qbe-gen vm/qberepl.c vm/qbe_shims.c vm/qbe_shims.h vm/qbe_prims_gen.c vm/qbe_prims_gen.h vm/zincvm.c vm/gc.c vm/symbol_static.c vm/symbol_static.h globals.qbe globals_trap.c
	@T=$$(mktemp -d /tmp/qberepl.build.XXXXXX) && \
	vendor/qbe/obj/qbe -t amd64_sysv -o $$T/globals.s globals.qbe && \
	$(COSMOAS)/x86_64-linux-cosmo-as  -o $$T/globals.o $$T/globals.s && \
	$(COSMO_CC) -Wall -Wextra -O2 -I vm -DZINCTEST -o $$T/qberepl \
		vm/qberepl.c vm/qbe_shims.c vm/qbe_prims_gen.c vm/zincvm.c vm/gc.c vm/symbol_static.c globals_trap.c $$T/globals.o -lm && \
	cp $$T/qberepl qberepl && chmod 755 qberepl; \
	st=$$?; rm -rf $$T; exit $$st

# qbe-smoke: Slice-2 (+ 1 2) -> 3 gate (hand-written vm/add12.qbe).
qbe-smoke: qbe-tool qbe-gen-prims vm/qbesmoke.c vm/qbe_shims.c vm/qbe_shims.h vm/qbe_prims_gen.c vm/qbe_prims_gen.h vm/zincvm.c vm/gc.c vm/symbol_static.c vm/symbol_static.h vm/add12.qbe
	@T=$$(mktemp -d /tmp/qbesmoke.build.XXXXXX) && \
	mkdir -p $$T/.aarch64 && \
	vendor/qbe/obj/qbe -t amd64_sysv -o $$T/add12.s vm/add12.qbe && \
	vendor/qbe/obj/qbe -t arm64     -o $$T/.aarch64/add12.s vm/add12.qbe && \
	$(COSMOAS)/x86_64-linux-cosmo-as  -o $$T/add12.o $$T/add12.s && \
	$(COSMOAS)/aarch64-linux-cosmo-as -o $$T/.aarch64/add12.o $$T/.aarch64/add12.s && \
	$(COSMOCC) -Wall -Wextra -O2 -I vm -DZINCTEST \
		-o $$T/out.ape \
		vm/qbesmoke.c vm/qbe_shims.c vm/qbe_prims_gen.c vm/zincvm.c vm/gc.c vm/symbol_static.c $$T/add12.o && \
	cp $$T/out.ape.com.dbg qbesmoke && chmod 755 qbesmoke; \
	st=$$?; rm -rf $$T; exit $$st
	@echo "=== QBE slice 2 smoke: (+ 1 2) -> 3 ==="
	./qbesmoke
	@echo "OK: (+ 1 2) => 3"

setup:
	@if [ ! -d ../shen-scheme ]; then \
		git clone https://github.com/tizoc/shen-scheme ../shen-scheme; \
	else \
		echo "shen-scheme already present"; \
	fi
	@$(MAKE) -C ../shen-scheme

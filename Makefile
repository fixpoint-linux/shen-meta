.PHONY: all vm test bundle pipeline interp setup clean gate gcdebug gc-verify tc-hm tc-hm-self tc-hm-tests gen-prims gen-symbol-static shensh shensh-test shpar-verify

SHEN   = vendor/shen-scheme/bin/shen-scheme
CFLAGS = -Wall -Wextra -O2 -I vm

all: zincvm zincdec zinctest shensh

# cosmocc produces a fat APE plus cross-build intermediates (.com.dbg,
# .aarch64.elf) alongside the output.  Stage those in a temp dir so they never
# land in the repo; only the native x86_64 ELF (.com.dbg) is copied out as the
# final binary.  Leaves the working dir unpolluted by build products.

# cosmocc builds a fat APE (we copy out the native .com.dbg ELF); a stock
# system C compiler (used on CI runners without the cosmocc toolchain) builds
# a single native ELF directly.  Either produces an equivalent native binary.
define compile-vm
	@T=$$(mktemp -d /tmp/$(notdir $(1)).build.XXXXXX) && \
	if command -v cosmocc >/dev/null 2>&1; then \
		cosmocc $(2) -o $$T/out.ape $(3) && \
		cp $$T/out.ape.com.dbg $(1) && chmod 755 $(1); \
	else \
		$(CC) $(2) -o $(1) $(3) && chmod 755 $(1); \
	fi; \
	st=$$?; rm -rf $$T; exit $$st
endef

# gen-symbol-static: generate the static symbol intern table (vm/symbol_static.{h,c})
# from the reduced bundle's symbol literals, using a minimal perfect hash.  The
# output is COMMITTED so `make zincvm` builds standalone; it is regenerated only
# when globals.csexp is present and newer.
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

shensh: vm/shensh.c vm/zincvm.c vm/gc.c vm/gc.h vm/zinctypes.h vm/zincvm.h vm/symbol_static.c vm/symbol_static.h
	$(call compile-vm,$@,$(CFLAGS) -DSHELL,vm/shensh.c vm/zincvm.c vm/gc.c vm/symbol_static.c)

clean:
	rm -f zincvm zincdec zincvm-asan zinctest zinctest-gc zinctest-asan shensh *.csexp globals.csexp

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

# shensh-test: end-to-end tests for the shensh shell — feeds shell command
# lines through the real REPL (stdin pipe) and checks quoting, field
# splitting, redirections (incl. the 2>&1 >file ordering), pipelines,
# chains, subshell cd isolation, the heredoc sh-continue protocol, the
# v1 rejects, fd-dup edges (2>& / 2>&x -> bad fd-dup), positional
# parameters ($0 $1..$9 $# $@ $* $$ $! $-; interactive + shensh -c),
# and the '(' escape running Shen SURFACE syntax through the bundled
# flat-Shen reader/compiler (shen-parse-exprs + shen->kl).
# See tools/shensh-e2e.sh.  Needs globals.csexp (built on
# demand via bundle).
shensh-test: shensh
	@if [ ! -f globals.csexp ]; then $(MAKE) bundle; fi
	bash tools/shensh-e2e.sh

# shpar-verify: prove /bin/sh is fully removed from the VM sources.  The
# grep matches the execl call form specifically; zero matches passes, any
# match fails the gate with the offending sites listed.
shpar-verify:
	@rc=0; for f in vm/zincvm.c vm/shensh.c; do \
		n=$$(grep -c 'execl.*bin/sh' $$f 2>/dev/null || true); \
		if [ "$$n" != "0" ]; then \
			echo "shpar-verify: FAIL: $$n execl(/bin/sh) site(s) in $$f:"; \
			grep -n 'execl.*bin/sh' $$f || true; \
			rc=1; \
		fi; \
	done; \
	if [ $$rc -eq 0 ]; then \
		echo "shpar-verify: OK — zero execl(/bin/sh) sites in vm/zincvm.c vm/shensh.c"; \
	fi; \
	exit $$rc


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


bundle: gen-prims shen/serialize-reduced.shen
	$(SHEN) script shen/serialize-reduced.shen 2>/dev/null
	@echo "Bundle written to globals.csexp ($$(wc -c < globals.csexp) bytes)"

run-bundle: zinctest globals.csexp
	./zinctest globals.csexp

# HM type checker targets.  tc-hm runs the checker on the 6 Group A source
# files (existing 58-OK baseline).  tc-hm-self rebuilds the bundle (so the
# run-tc-hm-self driver lands in globals.csexp) and runs the checker on its
# own 7 tc-hm*.shen source files.  tc-hm-tests rebuilds the bundle and runs
# the ~77 synthetic unit tests (opt-in, not gating).
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


# Bundle safe-subset verifier — opt-in, not gating.  Requires souffle.
# See docs/bundle-verify.md and tools/bundle-verify/.
bundle-verify:
	@if ! command -v souffle >/dev/null 2>&1; then \
		echo "bundle-verify: skipping (souffle not found)"; \
	else \
		$(MAKE) -C tools/bundle-verify run; \
	fi

setup:
	@if [ ! -d ../shen-scheme ]; then \
		git clone https://github.com/tizoc/shen-scheme ../shen-scheme; \
	else \
		echo "shen-scheme already present"; \
	fi
	@$(MAKE) -C ../shen-scheme

# The runtime is the Zig port (zig/).  `make` targets delegate to zig build;
# the only local build step left is 'bundle', which compiles the Shen
# sources through the vendored shen-scheme host and serialises the reduced
# bundle to globals.csexp (read by zig tests and the shensh front-end).
#
# Targets:
#   make            = all   -> build shensh + zincdec into zig/zig-out/bin/
#   make test       -> zig build test -Doptimize=Debug (gc + vm suites)
#   make gate       -> zig build gate (Debug + ReleaseSafe + ReleaseFast)
#   make bundle     -> globals.csexp via vendored shen-scheme (no C)
#   make shensh-test-> tools/shensh-e2e-zig.sh (needs bundle + zig shensh)
#   make bundle-verify -> Souffle safe-subset check on globals.csexp
#   make clean / setup

.PHONY: all test gate bundle shensh zincdec shensh-test bundle-verify clean setup

SHEN   = vendor/shen-scheme/bin/shen-scheme
ZIG    = cd zig && zig build
# PREFIX is relative to zig/ (the zig build runs from there).
PREFIX ?= zig-out

all: shensh zincdec

shensh zincdec:
	$(ZIG) --prefix $(PREFIX) $@

test:
	$(ZIG) test -Doptimize=Debug

gate:
	$(ZIG) gate

# Bundle: compile the reduced self-contained interpreter through the vendored
# shen-scheme host and serialize its global-table to globals.csexp.
# shen/prims-generated.shen (the primitive?-names list) is committed, so no
# generation step is needed.
bundle: shen/serialize-reduced.shen
	$(SHEN) script shen/serialize-reduced.shen 2>/dev/null
	@echo "Bundle written to globals.csexp ($$(wc -c < globals.csexp) bytes)"

# End-to-end tests for the Zig shensh shell — feeds shell command lines
# through the real REPL (stdin pipe).  Needs globals.csexp (built on demand
# via bundle) and the Zig exe installed at zig/$(PREFIX)/bin/shensh.
# Override with SHENSH_ZIG_BIN=<path> to point at another build.
shensh-test: shensh
	@if [ ! -f globals.csexp ]; then $(MAKE) bundle; fi
	SHENSH_ZIG_BIN=$${SHENSH_ZIG_BIN:-zig/$(PREFIX)/bin/shensh} bash tools/shensh-e2e-zig.sh

# Bundle safe-subset verifier — opt-in, not gating.  Requires souffle.
# See docs/bundle-verify.md and tools/bundle-verify/.
bundle-verify:
	@if ! command -v souffle >/dev/null 2>&1; then \
		echo "bundle-verify: skipping (souffle not found)"; \
	else \
		$(MAKE) -C tools/bundle-verify run; \
	fi

clean:
	rm -rf zig/zig-out globals.csexp

setup:
	@if [ ! -d ../shen-scheme ]; then \
		git clone https://github.com/tizoc/shen-scheme ../shen-scheme; \
	else \
		echo "shen-scheme already present"; \
	fi
	@$(MAKE) -C ../shen-scheme

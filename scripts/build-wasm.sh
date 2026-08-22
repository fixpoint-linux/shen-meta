#!/bin/sh
# scripts/build-wasm.sh — compile the zincvm C VM to WebAssembly (emscripten).
#
# Produces docs/shen-wasm.js + docs/shen-wasm.wasm (committed; the dhake site
# build copies them into dist/ without needing emscripten).
#
# Requires: emscripten (emcc). On Arch:  pacman -S emscripten clang lld llvm nodejs
#
# Strategy (see handoff-shen-mfe-site-artifact-wasm-* for the full rationale):
#   * A NEW TU wasm-main.c exposes a re-entrant shen_boot() + shen_eval_line()
#     that replaces zincvm's blocking fgetc(stdin) meta-REPL loop with a
#     synchronous per-line eval — no blocking stdin, no web worker, no Asyncify.
#   * vm/gc.c + vm/zinctypes.h are copied to a temp build dir and patched with
#     #ifdef __wasm__ shims (mmap 4GB reservation -> aligned_alloc heap; the
#     LP64 size asserts are skipped on wasm32). The native sources are untouched.
#   * The 687KB globals.csexp reduced bundle is embedded via --embed-file so the
#     VM reads it from MEMFS at boot.
#
# Run from the repo root:  scripts/build-wasm.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EMCC="${EMCC:-/usr/lib/emscripten/emcc}"
BUILD="$(mktemp -d /tmp/shen-wasm.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

# Stage the sources + apply wasm shims.
cp vm/zincvm.c vm/gc.c vm/symbol_static.c vm/zincvm.h vm/gc.h vm/zinctypes.h \
   vm/symbol_static.h vm/prims.def "$BUILD/"
cp globals.csexp "$BUILD/"
cp shell/wasm/wasm-main.c "$BUILD/"

# Shims must be applied to the COPY, not the repo sources (see artifacts).
python3 - "$BUILD" <<'PY'
import re, sys
b = sys.argv[1]
gc = open(f"{b}/gc.c").read()
old = re.search(
    r"    /\* Reserve a larger mmap than the initial heap.*?exit\(1\);\n    \}\n",
    gc, re.S)
assert old, "mmap reservation block not found in gc.c"
replacement = """#ifdef __wasm__
    /* wasm32: no mmap and no 4GB virtual-address reservation.  Reserve exactly
     * the requested heap via aligned_alloc (PAGEBYTES-aligned). */
    heap_mmap_size = heap_size;
    raw_heap_start = aligned_alloc(PAGEBYTES, heap_mmap_size);
    if (!raw_heap_start) {
        fprintf(stderr, "gc_init: aligned_alloc failed for %zu bytes\\n",
                (unsigned long)heap_mmap_size);
        exit(1);
    }
#else
""" + old.group(0) + """#endif
"""
gc = gc[:old.start()] + replacement + gc[old.end():]
open(f"{b}/gc.c", "w").write(gc)

zh = open(f"{b}/zinctypes.h").read()
assert "_Static_assert(sizeof(Value) == 40" in zh, "LP64 asserts not found"
zh = zh.replace(
    '_Static_assert(sizeof(Value) == 40',
    '#ifndef __wasm__\n_Static_assert(sizeof(Value) == 40')
zh = zh.replace(
    '_Static_assert(sizeof(uintptr_t) == 8, "Phase 3/4 assumes LP64");',
    '_Static_assert(sizeof(uintptr_t) == 8, "Phase 3/4 assumes LP64");\n#endif')
open(f"{b}/zinctypes.h", "w").write(zh)
print(f"patched gc.c + zinctypes.h in {b}")
PY

# Build via a response file (the [..] in EXPORTED_FUNCTIONS confuses some shells).
cat > "$BUILD/build.rsp" <<EOF
-O2
-I $BUILD
-s ALLOW_MEMORY_GROWTH=1
-s MAXIMUM_MEMORY=2147483648
-s EXIT_RUNTIME=1
-s INVOKE_RUN=0
-s MODULARIZE=1
-s EXPORT_NAME=createShenModule
-s EXPORTED_FUNCTIONS=[_shen_boot,_shen_eval_line,_malloc,_free]
-s EXPORTED_RUNTIME_METHODS=[UTF8ToString,stringToUTF8,ccall,cwrap]
--embed-file globals.csexp
$BUILD/zincvm.c
$BUILD/gc.c
$BUILD/symbol_static.c
$BUILD/wasm-main.c
-o $BUILD/shen-wasm.js
EOF

"$EMCC" @"$BUILD/build.rsp"

mkdir -p docs
cp "$BUILD/shen-wasm.js" docs/shen-wasm.js
cp "$BUILD/shen-wasm.wasm" docs/shen-wasm.wasm
ls -la docs/shen-wasm.js docs/shen-wasm.wasm
echo "built docs/shen-wasm.js + docs/shen-wasm.wasm"

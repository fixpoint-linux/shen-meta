# Loading, serialization, and the module system

Source: `AGENTS.md`. How code is loaded into the bundle, package prefixing, the
raw s-expression parser, the bytecode decompiler, and the REPL.

## Eval/load & serialization

- `interp-eval` in `toplevel.shen` compiles `defun` forms and stores closures in
  `global-table` via `defun->lambda → kl->zinc → toplevel-interp`.
- `serialize-reduced.shen` walks the deduped `global-table` and serializes all
  closures to `globals.csexp` (the reduced self-contained bundle).
- Output goes to file via `open`/`pr`/`close` — `print` wraps long lines and
  `grep '^"'` truncates multi-line bundles.
- `pr` writes raw string to a stream; `(stoutput)` is stdout.
- The canonical **reduced** self-contained bundle (`make bundle` →
  `globals.csexp`). The full Shen OS is not bundled (the runtime `.kl` OS-load
  path was removed).

### Module system & package prefixing

- The Shen package system prefixes ALL symbols (definitions AND references) with
  the module name (e.g. `shen.`) during Shen→KLambda compilation, in the Shen
  reader's `packageh` / `shen.package-symbols` functions.
- Our `.shen` tools (interp.shen, zinc.shen, etc.) are loaded via Shen's `load`,
  which adds the `shen.` prefix → bytecode references `shen.<e>`.
- **Fix**: `serialize-reduced.shen` runs `shen.add-prefix-aliases`, creating
  `shen.<name>` entries for unprefixed closure names. Both `<e>` and `shen.<e>`
  resolve to the same closure.
- **Do NOT add module prefix aliasing in the VM** — it belongs at the Shen
  pipeline level, during bundle creation. The Zig VM should only consume
  correctly-named bundles. This applies especially to `=` and `deep_equal`: never
  make them `shen.`-prefix-aware; prefix consistency is enforced by the pipeline.
- The serializer (`serialize-reduced.shen`) is the correct place to reconcile any
  name-prefix mismatch.

### Close-the-loop (runtime `.kl` loading) — REMOVED

The runtime `.kl` OS-load machinery (`interp-load-raw` / `read-file-raw` /
`parse-exprs`, and the `ZINC_TEST_OS_LOAD` probe) was removed; the full Shen OS
kernel is no longer loaded at runtime. The reduced self-contained bundle and the
flat-shen compiler (which drives `interp-eval` directly via `shen->kl-forms`)
remain.

## Flat-shen reader helpers (`load.shen`)

- The bare helpers that the flat-shen compiler's `shen-parse-*` family (in
  shen-kl-helpers.shen) reuses live in `load.shen`: `parse-string`,
  `find-string-end`, `skip-comment`, `skip-ws`, `parse-num-str`, `strlen`,
  `chars->str`, the `ws-*?`/`digit-*?` char predicates, and `str->num`.
- Uses `(n->string N)` for all special chars (avoids Shen's `\` escape issues).
- Shen 41.2 does NOT interpret `\n`/`\t`/`\r` in string literals — use
  `(n->string 10)` etc.
- `\` in KLambda strings is literal (not escape) — `parse-string-chars` reads
  until `"`.
- `strlen` cached once per parse; all parsers thread `Len` parameter.
- `let` destructuring `[A B]` does NOT work with `tc -`; use `hd`/`tl` on
  returned pairs.

### KLambda primitives (added to `primitive?` + `interp` handlers)

- `@p` — tuple constructor, stored as cons cell `[cons A B]`.
- `fst`/`snd` — tuple accessors, aliases for `hd`/`tl`.
- `gensym` — fresh symbol generation.
- `variable?` — predicate for KLambda variable symbols.

## Bytecode decompiler (`zincdec`)

Standalone binary for decompiling bundled closures. Four output formats:

```sh
./zincdec globals.csexp <function-name> [--raw|--asm|--shen|--csexp]
```

| Flag | Format | Example |
|---|---|---|
| `--raw` (default) | Human-readable opcodes | `access 0`, `global +`, `apply` |
| `--asm` | Disassembly w/ addresses | `0000: access 0`, `0003: jmpf 7  ; -> 0007` |
| `--shen` | Shen list for `interp.shen` | `[access 0]`, `[global +]`, `apply` |
| `--csexp` | Raw wire format (round-trippable) | `(ra[1:n]1P[7:s]number?f[1:n]7...)` |

Examples: `zig/zig-out/bin/zincdec globals.csexp +`, `zig/zig-out/bin/zincdec globals.csexp reverse --csexp`,
`zig/zig-out/bin/zincdec globals.csexp shen.repl --shen`.

Inspect bundled bytecode with the zincdec decompiler (`zig/zig-out/bin/zincdec`,
formats in docs/README.md). `read-file-as-string` is a native VM primitive for
file I/O (used by the flat-shen compiler's `shen-read-file`).

## REPL

- `stinput`/`stoutput` primitives added — return stdin/stdout VAL_STREAM.
  Registered in init_globals so bundled closures find them via `global_get`.
- `fflush(stdout)` in `write-byte` for piped output.
- `shen.initialise` (15-char name) must be called before `shen.repl`. Wraps
  `shen.initialise-environment` → `shen.initialise-lambda-forms` →
  `shen.initialise-signedfuncs`.
- REPL is functional. `shen.initialise` + `shen.repl` both execute and return.
  shen.initialise is non-idempotent: first call errors "set: first arg must be a
  symbol" (caught by trap-error), second call returns false. In test mode (stdin
  at EOF), shen.repl returns false immediately.
- **Key fixes enabling REPL:**
  - `*stinput*`/`*stoutput*`/`*sterror*` initialized as VAL_STREAM globals after
    parse_bundle.
  - `write-byte` arg order fixed (ZINC RTL: byte first, stream last).
  - CALL_STACK_DEPTH bumped from 8192 to 65536 (shen.initialise needs ~65K frames).
  - GC heap at 256MB (64MB exhausted on non-ASan builds).
  - Stack isolation per CallFrame.
  - read-byte/write-byte bypass stack for stream args.
  - trap-error jmp_buf save/restore to prevent use-after-return.
  - Tail-call mark cleanup in OP_RETURN/OP_APPTERM.
- `shen.initialise` REPL bytecode: `(mn[1:n]0ug[15:s]shen.initialisep)`.
- `shen.repl` with input: `(mn[1:n]0P[9:s]emptylistus[7:s]successP[4:s]consug[9:s]shen.replp)`.
- Name confusion: `shen.initialise_environment` (underscore, 27 chars) is a
  DIFFERENT function — only resets `shen.*call*/shen.*infs*` counters. Called by
  `shen.loop` each iteration. Not the setup function.

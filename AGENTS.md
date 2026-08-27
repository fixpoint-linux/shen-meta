# AGENTS.md — Project conventions for AI agents

## Build & test

The runtime is the **Zig port** (`zig/`). The only non-Zig build step is
`make bundle`, which compiles the Shen sources through the vendored
shen-scheme host and serialises the reduced bundle to `globals.csexp`.

```sh
make            # build shensh + zincdec into zig/zig-out/bin/
make test       # zig build test -Doptimize=Debug (gc + vm suites)
make gate       # zig build gate (Debug + ReleaseSafe + ReleaseFast)
make bundle     # serialize all safe wrappers → globals.csexp (vendored shen-scheme)
make shensh-test# run the shensh end-to-end shell tests (tools/shensh-e2e-zig.sh, 67 cases)
make bundle-verify # Soufflé safe-subset gate on globals.csexp (opt-in, needs souffle)
```

## Architecture

```
Shen source → kmacros → normalize-term → debruijn → zinc-c → compile-zinc → nat->csexp → Zig VM
```

## shensh — the Shen shell (no /bin/sh)

`./shensh globals.csexp` is an interactive POSIX-style shell whose **lexer,
parser, and expander are Shen code** and whose **process runner is a native
primitive**. `/bin/sh` is fully removed: there is exactly ONE exec call site
in the whole VM (`execvp` in the exec-plan runner, `zig/src/vm/execplan.zig`).

### Pipeline

```
line → sp-lex (shell/shlex.shen) → sp-parse (shell/shparse.shen)
     → shx-plan (shell/shexpand.shen)  → raw plan tree
     → [prim exec-plan] (zig, zig/src/vm/execplan.zig) → fork/dup2/execvp per stage
```

- The four `shell/*.shen` files are **namespace-2 (Shen `global-table`)
  closures**, NOT part of `globals.csexp`. The front-end boots them at startup
  in dependency order — `shlex` → `shparse` →
  `shexpand` → `shell` — each warn-and-continue on failure, AFTER
  `tc-hm-init`, so the HM sig table accumulates across files and the shell
  sources are HM-checked at boot (this is why `shensh` must run from the
  repo root: the boot paths `shell/*.shen` are relative).
- Chain-op symbols in plan trees are **interned lowercase constants**
  (`seq`/`and`/`or`) — never bare `and`/`or`/`append` (those are KLambda
  macros and would macroexpand). `shx-plan` builds raw trees via `(intern ...)`.

### exec-plan contract and plan encoding

`exec-plan` takes ONE tagged plan value and returns the TAGGED
`[exit stdout stderr]` (strings are captured program output). Plans are built
by `shx-plan` in this encoding:

| Value | Encoding |
|---|---|
| Program | `(list Chain)` — chain list |
| Chain | `[op Pipeline]` where op ∈ {`seq`, `and`, `or`} (`;`, `&&`, `||`) |
| Pipeline | `(list Cmd)` — `|` stages |
| Cmd | `[Argv Redirs Sub]` |
| Argv | `(list string)` — already field-split, quoted, `~`/`$VAR`-expanded |
| Redirs | `(list [op fd target])`, op ∈ {`in`, `out`, `append`, `dup`, `hdoc`, `hstr`} |
| Sub | subshell Program or empty — `( ... )` |

Capture uses two **unlinked mkstemp tmpfiles** (out + err). One open fd is
shared between parent (reads it back) and child (writes to it): no pipe
buffer to deadlock on and no name to leak — the file vanishes when both
sides close. `2>&1` is `dup 1 2` applied **after** earlier redirects, so
`2>&1 >file` correctly leaves stderr on the old stdout (POSIX ordering,
tested in the VM tests + e2e).

### Builtins

- **Parent-process (Shen, `shell/shell.shen`)** — `cd`, `pwd`,
  `setenv`/`export` (`NAME VALUE` or `NAME=VALUE`), `exit` (sets `*sh-exit*`).
  These must mutate the shell process itself.
- **Child (Zig, `zig/src/vm/execplan.zig`)** — `echo`, `true`, `false`, `:`, `cd`, `pwd`
  run inside forked children (post-redirect), so they behave uniformly in
  pipelines and subshells. Inside a forked subshell child a single builtin
  runs **in-process** with fds 0/1/2 saved/restored — that is what makes
  `(cd /; pwd)` print `/` (POSIX subshell semantics).
- `$?` reads `*sh-exit-code*` (set from the last exec-plan result).

### The `(` escape (Shen surface at the prompt)

A line starting with `(` (no unquoted `;` `|` `&` — those are shell subshells)
routes through the front-end's eval-klambda-line path: the **bundled flat-Shen
reader/compiler** — `shen-parse-exprs` (the .shen surface reader: `{ A --> B }`
sigs grouped, `[X | Y]` consified, `->` an atom) parses, then each form is
compiled by `shen->kl` (the same dispatcher `shen-load` uses) and dispatched:
a compiled `(defun ...)` registers into namespace 2 via `interp-eval`
(`; registered <name>`), anything else evaluates via `eval-kl` (`=> <result>`).
So BOTH Shen surface (`(define sq { number --> number } X -> (* X X))` then
`(sq 7)` → `49`) and raw KLambda (`(defun f (X) ...)`) work at the prompt.

### sh-continue heredoc protocol

When a line ends inside an unterminated heredoc, `sp-parse` returns
`[pending Delims]` and `shell-eval-line` returns the SYMBOL `sh-continue`.
The `shensh` REPL then prints a `> ` continuation prompt, accumulates
`buffer = buffer + "\n" + line`, and re-evaluates the whole buffer each
line until the delimiter closes. EOF while pending prints
`heredoc: unexpected EOF` and resets the buffer. Parsing never leaves Shen.

### Positional parameters (v1 semantics)

`$0` `$1`..`$9` `$#` `$@` `$*` `$$` `$!` `$-` are supported (lexed as
one-char var parts in `shlex.shen`, expanded in `shexpand.shen`'s
`shx-var-value` dispatch). The front-end sets `*sh-argv0*`, `*sh-posargs*`,
`*sh-flags*`, `*sh-pid*` in the values table at boot (via `(set ...)`
forms, so they land TAGGED — see the note below) and
`shexpand.shen` reads them via `value`, falling back to honest defaults
when unbound:

- `$0` = how the shell was invoked: argv[0] for the interactive REPL; for
  `shensh -c 'cmd' operands...` the first operand names `$0` (bash `-c`
  convention), falling back to argv[0].
- `$1`..`$9` = positional args: none in the interactive REPL; the operands
  after the `-c` name operand. `${9}x` disambiguates from `$9x`.
- `$#` = decimal count of positional args.
- `$@`/`$*` = the positional args: `"$@"` produces separate quoted fields,
  `"$*"` one joined field; unquoted both join with spaces and re-split.
- `$$` = the shell's live PID (Zig `getpid` prim, 5-registry registered).
- `$!` = empty string (v1 has no background jobs — honest, not an error).
- `$-` = `"i"` in the interactive REPL, `"c"` under `-c`.

### Known syntax rejections (clean `error:` messages)

Backtick, `$( )`, bare `&`, and field splitting inside redirect targets are
rejected by the lexer/expander as `error: ... not supported` — caught by
`shell-eval-line`'s trap-error. A truncated (`2>&`) or invalid-target
(`2>&x`) fd-dup is rejected as `error: bad fd-dup ...` (detected by the
`N>&` prefix BEFORE the plain `>` redirect handlers, so it can never be
mis-reported as "background & not supported").


## Partial application (metacircular interp only)

The metacircular interpreter (`shen/interp.shen`) supports partial application:
when a closure is called with fewer arguments than its arity, instead of entering
the closure body, it creates a new closure capturing the provided arguments. This
is implemented via the `arity`, `count-args`, and `drop-grabs` helpers in `interp.shen`,
with arity checks in the `apply` and `appterm` rules.

**The Zig VM does NOT support partial application** — it is intentionally simpler.
It runs only the subset of ZINC required for the meta-interpreter (the
reduced self-contained bundle), where all call sites are proven full-arity.  If
a bundled closure calls another with a short argument list, the metacircular
interp (which runs ON the Zig VM) handles it — the VM never sees partial
application directly.  This split is intentional: the metacircular interp runs
full KLambda; the Zig VM runs only the statically-proven subset.

## Design intent (why static sites skip safe wrappers)

**The end goal:** the meta-circular interpreter (`interp` in `shen/interp.shen`) is
written in Shen and is meant to be PROVEN type-safe using the Shen sequent-calculus
type rules, and the VM is meant to be GENERATED from that proven
interpreter (a static compiler that only compiles that subset, or by specialising
the interpreter). The Zig VM in `zig/src/vm/` is a hand-written stand-in for that
generated interpreter.

Consequence — call sites split into two kinds:

- **Static call sites** — code produced by the compiler is type-safe by
  construction (it comes from the proven interpreter). These need NO runtime type
  check and NO safe wrapper. This is why `zinc-c`/`zinc-t` in `shen/zinc.shen`
  (lines 17-20 / 42-46) special-case `primitive?` heads to emit `[prim F]` — a
  direct primitive dispatch that BYPASSES the global table (and thus any `safe.X`
  wrapper registered via `set-toplevel`). This is intentional, NOT a bug.
- **Dynamic call sites** — boundaries, higher-order use, and untyped user input
  (e.g. `eval-kl` of `tc -` user code, `%%` escapes). These are NOT proven
  type-safe, so they must route through the Shen safe wrappers (`safe.X` in
  `shen/primitives.shen`) so a type error becomes a catchable `simple-error`.

`[global X]` → `safe.X` only fires on the dynamic path (a primitive used *as a
value*, higher-order, or explicit `(function X)`). Normal direct calls use
`[prim X]`. The VM primitives have NO runtime type guards. Type validation is
owned entirely by the Shen safe-wrapper layer. This is safe ONLY for a
type-safe bundle: the canonical bundle (`make bundle` → `globals.csexp`) is the
**reduced self-contained interpreter** (meta-interpreter + safe-subset helpers),
which never passes bad types.

Always-on throw sites that are NOT type guards and stay in release: `simple-error`,
`fail`, `apply`/`appterm` non-callable + too-many-args, `env_pop`, `eval-kl` catch,
and `pos` out-of-bounds inside `trap-error` (semantic, needed for `strlen`/end-of-string).

## Self-hosting tests

| Test | Description | Status |
|---|---|---|
| 1-4 | +, reverse, factorial, open/close via inline OP_PRIM | Pass |
| A | toplevel-interp on `[]` → `[cons]` | Pass |
| B | toplevel-interp on `[number 42]` → `[number 42]` | Pass |
| C | interp `[] [cons] [] [] []` → `[cons]` | Pass |
| 5 | eval-kl `[+ 1 2]` via marshal chain | Pass |
| 6-7 | read-file-as-string, load via apply | Pass |
| 7b | read-from-string | Pass (returns [[+ 1 2]]) |
| 7b' | read-from-string typed define `{ A --> A }` | Pass (returns [[define id ...]]) — regression test for Bug #1 |
| 7c | read via string stream | Pass |
| 8-10 | id, newvar, defun->lambda (bundled in the reduced bundle) | Pass |
| 10b | lambda-as-value application: `((lambda (X) (+ X 100)) 5)` → 105, multi-param `((lambda (X Y) (- X Y)) 10 3)` → 7, `(let F (lambda (X Y) (+ X Y)) (F 3 4))` → 7 | Pass — regression for the kmacros param-list fix (`fix(interp)` 9bc7300). Raw KLambda `(lambda (X ...) Body)` must be unwrapped/curried by `kmacros` (normalize.shen) before debruijn, else body refs don't resolve and the interp dies with `interp: unknown prim`. Use KLambda syntax `(defun F (X) Body)`, not Shen `(defun F X -> ...)`. |

## Key files (under `shen/` unless noted):
- `shen/interp.shen` — meta-circular ZINC VM (loads everything)
- `shen/normalize.shen` — KLambda normalization + debruijn indices
- `shen/zinc.shen` — KLambda → ZINC bytecode compiler
- `shen/compile.shen` — ZINC → canonical s-expression (csexp)
- `shen/primitives.shen` — 37 type-checked safe wrappers
- `zig/src/vm/` — the Zig VM (interp.zig, prims.zig, execplan.zig, marshal.zig, ...)
- `zig/src/gc/` — the Zig moving generational collector (heap.zig, collect.zig, roots.zig, ...)
- `shen/serialize-reduced.shen` — serialize reduced bundle's global-table to csexp (`globals.csexp`)
- `shen/toplevel.shen` — `interp-eval` — compiles defun forms through interpreter
- `shen/load.shen` — flat-shen reader helpers (parse-string, skip-ws, strlen, …)
- `shen/util.shen` — `defun->lambda`, `primitive?` (single source of truth), `dedupe-globals`
- `shen/types.shen` — type definitions + DUPLICATE `primitive?` list (must stay synced!)

## Shen quirks

- `tc -` to disable type checker; Shen 41.2 uses `___` not `===` for datatypes
- `defun` is Shen 22.2 syntax; use `define` or `defun->lambda` for 41.2
- `[X . Y]` is a dirty pair; `[X | Y]` is list cons
- `cn` takes exactly 2 args; string concat needs nested `cn` calls
- `print` outputs to stdout; script mode prints `fn`/`run time` noise from loads
- `eval` mode `-e` results are mixed with `-l` load output on stdout
- `-q` sets `*hush*` which gates `print` but not `write-byte`
- `%%` escapes to host Shen primitives; compiles to `[prim X]` in ZINC

## Zig VM conventions

- **GC**: custom generational collector (`zig/src/gc/`). A 2MB nursery (pages
  marked `space==3`) is the allocation fast lane; the existing full-copy
  `collect()` is the (rare) old-gen collector and compacts old gen. Typed
  headers drive a tag-dispatch scavenger; roots are precise-only via the shadow
  stack + typed walkers (no conservative stack scan); typed
  `gc_scan_value`/`gc_evacuate` handle interior pointers. Write barrier at
  `address->` vector writes (site 1, required); `global_set` barrier deferred
  (see `docs/gc.md`).
  **Drain invariant (Bug 2 fix):** the shared page-queue Cheney drain must
  never treat `cp == freep` as end-of-page while the queue is non-empty —
  objects allocated into a dequeued page's bump slack would never be scanned
  (stale interior pointers → heap corruption). Only the freep page can receive
  new objects, so the drain defers that one page and resumes its walk later.
  `gc_alloc`/`gc_alloc_oldgen` grow the heap when a collect leaves the live set
  above `oldgen_collect_threshold()` (anti-thrash; the pre-fix collector only
  avoided the thrash by dropping live objects).

- csexp atoms: `[len:type]value` — type is `s`/`n`/`S`/`b`
- Opcodes are single chars: `m` pushmark, `p` apply, `r` grab, `v` return, etc.
- `global` loads from table then falls back to the prim table
- Primitives dispatch via the prim table — apply-mode pops mark + args from stack
- Inline `OP_PRIM` (`P`) executes primitive with args from stack + accumulator (ZINC semantics)
- `trap-error`/`simple-error` use setjmp/longjmp semantics
- `eval_kl_depth` recursion guard: ensures depth always decremented even on
  a raised error. Without this, a failed eval-kl blocks all subsequent calls.

## Primitive semantics (critical — must match Shen)

- **`=`** now supports deep structural equality for cons cells via `deep_equal()`.
  Without this, `(= [+ 1 2] [+ 1 2])` returns false, breaking `macroexpand-h`'s
  fixed-point check.  Depth-limited to 1000 for cycle safety.
- **`=` symbol comparison** is strict `strcmp` — no prefix awareness.  Reference
  shen-scheme's `kl:=` uses plain `eq?` (pointer identity on symbols); `foo` and
  `shen.foo` are different symbols and must compare unequal.  The VM MUST NOT
  add `shen.` prefix handling to `=` — prefix consistency is a pipeline concern.
  The pipeline enforces it via: `%% set` in normalize.shen → `shen.initialise`
  completes → `shen.external-symbols` populated → `sysfunc?` returns true for
  `define`/`defun`/`type`/etc. → `package-symbols` leaves them bare.  If `(= define
  shen.define)` ever returns false at runtime, the bug is in `shen.initialise`
  not completing (likely a missing `%%` on a primitive in normalize.shen), NOT in `=`.
- **`=` cons-vs-symbol** and symbol-vs-cons comparisons always return false.
  zinc-c currently generates correct `hd`-wrapped comparisons (e.g.,
  `(= hd(Code) define)`), so flat `(= [define ...] define)` no longer occurs.
- **`%%` in normalize**: ALL primitives must use `%%` prefix in normalize.shen.
  `[set S E]` was missing `%%`, causing `set` to go through `global set` + `apply`
  (safe wrapper) instead of `prim set` (direct primitive).  This broke
  `shen.initialise`'s deeply nested `do` chain.  Always use `[%% set S T]`.
- `n->string N`: number → single-character string via ASCII code. `(n->string 40)` → `"("`
- `string->n S`: first character → ASCII code. `(string->n "(")` → `40`
- `pos S N`: single character at index N (0-based). OOB → `""`. `(pos "hello" 1)` → `"e"`
- `str V`: value→printed string. Numbers use decimal. Symbols use name. Strings pass through.
- `open Path Dir`: file I/O + string streams. ENOENT on `in` → creates string stream from Path.
  String stream data stored externally (not in Value union) to keep sizeof(Value) small.

## Pipeline gotchas

- `%%` compiles to `[prim X]` in ZINC; normalize must flatten curried `%%` calls
  via `flatten-%%app` or you get spurious `apply` after `prim` instructions
- `instr-count` and `label-positions` must handle opcodes with operands explicitly
  (`access _`, `global _`, `jmpf _`, `jmp _`, `number _`, `string _`, `symbol _`,
  `boolean _`, `prim _`) — catch-all `[_ | C]` counts operand atoms as separate
  instructions, inflating jump targets
- `cur` is 1 instruction in csexp stream, not `1 + body_size`
- `parse_bundle` must unwrap `OP_CUR` to get closure body — the `c(...)` wrapper
  is a single instruction whose operand is the closure's code array
- `ps` returns KLambda; unary primitives like `number?` lack `%%` wrapping in
  Shen 41.2 — normalize/debruijn need to handle bare primitives for inline `prim`
- `marshal_to_tagged` must NOT recursively tag VAL_CONS car/cdr. extract-kl handles its
  own recursion on `[cons X Y]`. Recursive marshalling creates impossibly deep nesting.
- ZINC bytecode for the interp family is FLAT: opcodes and operands are separate list elements.
  `[number 42]` = cons('number, cons(42, nil)). NOT cons(cons('number, cons(42, nil)), nil).
- `global` keyword registration: ZINC pattern keywords (number, symbol, cons, lambda, etc.)
  must be forced into the global table as symbols after parse_bundle, or self-compiled
  pattern-matching code resolves them as closures instead of tag symbols.

## Eval/load & serialization

- `interp-eval` in `toplevel.shen` compiles `defun` forms and stores closures in
  `global-table` via `defun->lambda → kl->zinc → toplevel-interp`
- The **reduced** self-contained bundle (`make bundle` → `globals.csexp`) is
  `serialize-reduced.shen` — it walks the deduped `global-table` and serializes
  all closures (~340 in the reduced build).

### Two global namespaces (critical to understand)

There are **two separate global namespaces**, and confusing them is the #1 source
of "why can't the VM see my closure?" bugs:

1. **VM native global table** (`zig/src/vm/tables.zig`). Populated by bundle load
   from the bundle `((name code) ...)` and by init (primitives, `safe.X`
   wrappers, `*stinput*`/`*stoutput*`/`*sterror*`, keywords). Read by the
   `[global X]` opcode.
2. **Metacircular interp's Shen `global-table`** (`shen/interp.shen:6`,
   `(set global-table [])`). A Shen **variable** holding an assoc list
   `[name . closure]`. The interp resolves `[global G]` **not** via the VM
   table but via `lookup-global` (`interp.shen:8`) which reads
   `(value global-table)`. `interp-eval`
   (`toplevel.shen`) `(set global-table (cons [Name Closure] ...))`
   to register a compiled defun.

**Which one does a loaded `.kl` defun land in?** The Shen `global-table`
(namespace 2) — NOT the VM native table (namespace 1). The `set`
primitive writes into the global named `"global-table"`, so the interp's list is
*stored as* a global named `"global-table"`, but a runtime-loaded closure
(`shen.foo`) is **not** its own native global entry.

Consequences:
- Bytecode `[global shen.foo] apply` (namespace 1) will NOT find a
  runtime-loaded closure — the lookup falls back to the symbol, giving
  "apply non-callable"/`appterm non-lambda`.
- To call a runtime-loaded closure, drive it **through the metacircular interp**:
  `eval-kl`, `toplevel-interp`, or a bundled closure that resolves names via
  `lookup-global`. The metacircular interp sees namespace 2.
- A bundled closure that must call a loaded OS function references it via
  `[global X]` **in its own bytecode**, which the interp resolves via
  `lookup-global` (namespace 2) when it executes that bytecode. So bundled code
  reaching OS closures works *as long as execution flows through the interp*.

**Debugging a wrong-value `or`/`appterm non-lambda` at runtime?** First check
whether the closure you're calling is in the VM table or only the Shen
`global-table`. A `[global X]` reaching a non-primitive, non-registered name
returns the symbol `X` — not an error. If you see the symbol coming back as a
"result", you are reading the wrong namespace.

**Tagged vs raw values in the values table (`set`/`value` asymmetry).** The
metacircular interp's `[prim set]` rule (interp.shen) passes the interpreter's
TAGGED representation (`[string S]`/`[number N]` cons cells) to the `set`
primitive, so every REPL/shensh-boot `(set ...)` lands TAGGED in the values
table; `[prim value]` returns it as-is and downstream interp rules pattern-match
the tagged forms (`[prim string?] [string _]`...). But a RAW `value_set` writing
a plain string is UNTAGGED — a bundled closure reading it via `value` then fails
its tagged pattern matches and silently falls to the catch-all/default arm
(symptom: boot globals look set from the REPL `(value ...)` yet shell closures
always take their defaults).
**Rule: set Shen-visible globals through `(set ...)` KLambda forms, never raw
`value_set` — and unwrap both raw and `[number N]` forms when reading them back.

**How the metacircular interp registers a compiled `defun`:** `interp-eval`
(`toplevel.shen`) matches `[defun Name Args Body]`, compiles via
`kl->zinc (defun->lambda ...)` → `toplevel-interp`, and stores `[Name Closure]`
into the interp's `global-table` (namespace 2). The flat-shen compiler's
`shen->kl-forms` feeds each parsed form through `interp-eval` (singular); the
shell boots its `shell/*.shen` sources through `shen_load_source` →
`shen-read-file` → `shen->kl-forms` → `tc-hm-forms` → `interp-eval`.

### n-ary `and`/`or` (compiler gotcha)

`kmacros` in `normalize.shen` must expand **n-ary** `and`/`or`, not just 2-arg:
`read-atom-chars` uses a 5-arg `(or ...)`, `parse-atom` a 3-arg `(and ...)`.
The 2-arg-only rules let these fall through to the general `[X | Y]` rule and
compile to `[global or]`/`[global and]` + apply, which resolve to symbols at
runtime → `appterm non-lambda` returning symbol `or`. See the n-ary rules in
`normalize.shen`.

### Shen module system & package prefixing

- The Shen package system prefixes ALL symbols (definitions AND references) with
  the module name (e.g. `shen.`) during Shen→KLambda compilation.  This happens
  in the Shen reader's `packageh` / `shen.package-symbols` functions.
- `.kl` files from shen-scheme are pre-compiled KLambda.  Most have the `shen.`
  prefix already baked in.  But `yacc.kl` defines `<e>`, `<!>`, `<end>` WITHOUT
  the prefix (generated by the YACC compiler, not the Shen compiler).
- Our `.shen` tools (interp.shen, zinc.shen, etc.) are loaded via Shen's `load`,
  which adds the `shen.` prefix → bytecode references `shen.<e>`
- **Fix**: the bundle serializer runs `shen.add-prefix-aliases`, creating
  `shen.<name>` entries for unprefixed closure names.
  Both `<e>` and `shen.<e>` resolve to the same closure.
- **Do NOT add module prefix aliasing in the VM** — it belongs at the Shen
  pipeline level, during bundle creation.  The VM should only consume
  correctly-named bundles.  This applies especially to `=` and `deep_equal`:
  never make them `shen.`-prefix-aware; prefix consistency is enforced by the
  pipeline (see Primitive semantics above).
- The serializer (`serialize-reduced.shen`) is the correct place to reconcile
  any name-prefix mismatch.

## Bytecode decompiler (`zincdec`)

Standalone binary for decompiling bundled closures (`zig/src/zincdec_main.zig`).
Four output formats:

```sh
./zig/zig-out/bin/zincdec globals.csexp <function-name> [--raw|--asm|--shen|--csexp]
```

| Flag | Format | Example |
|---|---|---|
| `--raw` (default) | Human-readable opcodes | `access 0`, `global +`, `apply` |
| `--asm` | Disassembly w/ addresses | `0000: access 0`, `0003: jmpf 7  ; -> 0007` |
| `--shen` | Shen list for `interp.shen` | `[access 0]`, `[global +]`, `apply` |
| `--csexp` | Raw wire format (round-trippable) | `(ra[1:n]1P[7:s]number?f[1:n]7...)` |

Examples: `zig build zincdec -p zig-out` then
`./zig/zig-out/bin/zincdec globals.csexp +`,
`./zig/zig-out/bin/zincdec globals.csexp reverse --csexp`,
`./zig/zig-out/bin/zincdec globals.csexp shen.repl --shen`

## Flat-shen reader helpers (`load.shen`)

The bare helpers that the flat-shen compiler's `shen-parse-*` family (in
shen-kl-helpers.shen) reuses live in `load.shen`: `parse-string`,
`find-string-end`, `skip-comment`, `skip-ws`, `parse-num-str`, `strlen`,
`chars->str`, plus the `ws-*?`/`digit-*?` char predicates and `str->num`.
- Uses `(n->string N)` for all special chars (avoids Shen's `\` escape issues)
- Shen 41.2 does NOT interpret `\n`/`\t`/`\r` in string literals — use `(n->string 10)` etc.
- `\` in KLambda strings is literal (not escape) — `parse-string-chars` reads until `"`
- `strlen` cached once per parse; all parsers thread `Len` parameter
- `let` destructuring `[A B]` does NOT work with `tc -`; use `hd`/`tl` on returned pairs

## KLambda primitives (added to `primitive?` + `interp` handlers)

- `@p` — tuple constructor, stored as cons cell `[cons A B]`
- `fst`/`snd` — tuple accessors, aliases for `hd`/`tl`
- `gensym` — fresh symbol generation
- `variable?` — predicate for KLambda variable symbols

### Non-standard extras (NOT part of KLambda; kept deliberately)

- `c-strlen`, `char-code`, `substring` — added to the VM prim table
  for the `shen/load.shen` parser hot path only (the flat-shen reader helpers).
  They are **not** part of the standard KLambda primitive set.
  Kept (not removed) for the O(1) `strlen` / alloc-free `char-code` / O(k)
  `substring` the pure-Shen fallbacks in `shen/load.shen` lack; the pure-Shen
  fallbacks in `shen/load.shen` are the canonical semantics.
  `read-file-as-string` and `shen.fail!` are also non-standard names, but
  `read-file-as-string` is **required** by the flat-shen compiler's
  `shen-read-file` (shen-kl-helpers.shen), which is how `shensh` boots
  `shell/*.shen`.

## Shen pitfalls

- `let` DOES work with `tc -` (verified), just types in `define` aren't checked
- `let` destructuring `[A B]` does NOT work with `tc -`; use `hd`/`tl` on returned pairs
- `type` signatures in `define` ARE accepted with `tc -` (just not checked)
- `read-file` returns a list of parsed s-expressions from a file — works for
  both `.shen` and `.kl` files
- `.kl` files use raw KLambda constructs: `defun`, `lambda`, `let`, `cond`,
  `@p`, `where`, `freeze`, `thaw`, `cons?`, `=`, `if`, etc.

## Self-hosting & VM gotchas

- The global table was sized generously to hold all ~1200 closures
- A global lookup that falls back to the prim table for missing names can cause
  "unknown primitive" errors if a bundled closure overwrites a primitive
  and then something expects the raw primitive
- Bundled safe wrappers (safe.+, safe.open, safe.string? etc.) overwrite
  primitives in the global table since bundle load runs after init
- `%%` escapes compile to `[prim X]` which dispatches directly,
  bypassing the global table — so safe wrapper internals still work
- Bytecode that needs an unchecked primitive (bypassing safe-wrapper shadowing)
  uses the inline `OP_PRIM` dispatch (`P[4:s]open`, `P[7:s]eval-kl`, etc.) — the
  same path `%%` escapes use. There is NO `raw.X` namespace; primitives are
  reached only via `OP_PRIM` (direct) or through a safe wrapper (global table).
- `shen.repl`, `shen.read-evaluate-print`, `read`, `compile`, `eval-kl` are
  all in the bundle — the full Shen OS is available
- `gensym`, `@p`, `fst`, `snd`, `variable?` — KLambda primitives added to
  both `primitive?` (Shen side) and the prim table (VM side)

## ZINC argument convention

- **ZINC evaluates args RIGHT-TO-LEFT**: rightmost Shen arg pushed first
  (ends at stack bottom), leftmost pushed last (on top of stack)
- All two-arg primitives pop `a1` (top = leftmost arg) then `a2` (below =
  rightmost arg). E.g., for `(- 5 3)`: stack `[3, 5]`, pop a1=5, a2=3,
  compute `a1 - a2` = 5-3 = 2. `cons` does cons(left, right).
- `open` was the exception — had `dir`/`path` swapped, causing "open bad
  types" in bundled `load`. Fixed: pop `path` first, then `dir`
- **When writing bytecode by hand**, push args in right-to-left order:
  `(s[2:s]in S[8:S]Makefile P[4:s]open)` for `(open "Makefile" in)`
  (inline `OP_PRIM` `P[...]` dispatches directly, bypassing the global table)
- **CRITICAL**: Hand-written bytecode MUST use RTL order. The VM pops
  top-first (leftmost arg). Writing LTR (natural reading order) works
  for commutative ops (+, =, cons-as-pair) but silently produces wrong
  results for non-commutative ops (-, /, trap-error, write-byte).
  This is the #1 recurring bug pattern. See the VM tests for examples.
- The VM test suite uses `m` (pushmark) before args; mark ends up at stack bottom,
  not popped by apply with a primitive (mark must be on top to be popped)
- `appterm` ('t') and `apply` ('p') share identical stack layout:
  `[mark, argN..arg1, function]`. Difference: appterm reuses current frame
  (tail-call, pc=0), apply pushes new CallFrame. Both reject >64 args.
  Appterm additionally rejects zero args and requires pushmark.

## Commit style

- Conventional commits: `feat:`, `fix:`, `chore:`
- Don't commit compiled binaries

## trap-error / primitive error handling

Error handling uses a **per-catch-site chain** of error frames. The VM's
`trap-error`/`eval-kl` and the front-end's REPL/init each install a catch
frame that routes `simple-error` to the enclosing handler; an error raised
outside any catch prints and aborts.

- `simple-error` always throws to the current chain head. Inside a trap-error
  BODY the frame is marked in-trap, so a `simple-error` raised in the body throws.
  **Primitive type guards were removed** — primary ownership of catchable
  runtime type errors is the Shen safe-wrapper layer (`shen/primitives.shen`):
  each `safe.X` validates args and raises a catchable `simple-error` before the
  raw primitive is called. The always-on throw sites (not safe-wrapper-protected,
  not type guards) are: `simple-error`, `fail`, `apply`/`appterm` non-callable +
  too-many-args, `env_pop`, `pos` OOB inside `trap-error`, and eval-kl's catch.
- This routes out-of-bounds access sentinels through error handlers, letting
  `bound?` correctly return false for unbound symbols.

## ZINC calling convention (STANDARD — fully aligned)

The VM now uses **standard ZINC** semantics: all value-producing opcodes push
results to the stack AND set `acc`. There is no `push` opcode — the compiler
relies on auto-push (see "Compiler changes" below).

**Opcodes that push to stack:**
- `OP_NUMBER`, `OP_STRING`, `OP_SYMBOL`, `OP_BOOLEAN` — push operand
- `OP_ACCESS` — push env lookup result
- `OP_GLOBAL` — push global table lookup result
- `OP_CUR` — push newly created closure
- `OP_PRIM` — push primitive result (after execution, no pre-push)
- `OP_APPLY` (VAL_PRIM) — push primitive result
- `OP_APPTERM` (VAL_PRIM) — push primitive result
- `OP_RETURN` — push return value to caller's stack

**Opcodes that pop from stack:**
- `OP_JMPF` — pops condition from stack
- `OP_LET` — pops value from stack (binds to env)
- `OP_APPLY` / `OP_APPTERM` — pop function from stack top, then args up to mark

**Compiler changes:**
- `shen/zinc.shen` (`zinc-c` and `zinc-t`): relies on auto-push. Multi-arg
  primitives and function calls emit bare operand sequences — no `push` opcode.
- The `push` (`u`) opcode has been REMOVED from the VM, the compiler pipeline
  (compile.shen/util.shen/types.shen), and the metacircular interp. It is dead:
  the compiler never emits it, and the bundle/test bytecode contain no `u`.
  `pushmark` (`m`) remains and is still emitted by `zinc-c`/`zinc-t`.

**Bundle recompiled:** `globals.csexp` rebuilt with modified zinc.shen.
All bundled closures now use push semantics natively.

### Metacircular interp — auto-push refactored (DONE)

The metacircular `interp` in `interp.shen` now implements standard ZINC auto-push
semantics. Only 7 value-instruction rules were changed — each pushes the **old**
accumulator to the stack before setting the new value:

```
[access N | C] A E S R    → (interp C (lookup N E) E [A | S] R)
[global G | C] A E S R    → (interp C (lookup-global G) E [A | S] R)
[cur C1 | C] A E S R      → (interp C [lambda C1 E] E [A | S] R)
[number N | C] A E S R    → (interp C [number N] E [A | S] R)
[string Ss | C] A E S R   → (interp C [string Ss] E [A | S] R)
[symbol Ss | C] A E S R   → (interp C [symbol Ss] E [A | S] R)
[boolean B | C] A E S R   → (interp C [boolean B] E [A | S] R)
```

All 85 other rules (binary prims, unary prims, jmpf, let, grab, return, etc.)
remain unchanged. Binary prim rules like `[prim + | C] [number A] E [[number A1] | S] R`
work correctly because auto-push leaves the previous value on the stack top, which
is exactly the rightmost argument.

**The C bridge (push insertion in eval_kl) has been REMOVED.** No bytecode
transformation is needed — the interp natively handles standard ZINC output.

**Key design choice:** Pushing OLD accumulator (not new value) means the accumulator
remains the "current value" at every step, keeping all existing prim rules compatible.

### Metacircular interp — apply/appterm (DONE)

- **Multi-arg `apply`**: Uses `collect-apply-args` helper to collect all args
  up to the mark (skipping A0+mark), then gives callee a fresh stack with
  caller context saved as `[C E Rest]` return frame.
- **Multi-arg `appterm`**: Same arg collection via `collect-apply-args`.
  Tail-call semantics: replaces saved stack in return frame (or starts fresh
  at top level). Zero-arg check added (matches the VM).
- **`collect-apply-args`**: depth-limited (max 64 args, matches the VM),
  errors if mark is missing, signature `(list zinc-value) -> number -> (list zinc-value)`.
- **Env ordering fix**: `(append (reverse Args) E1)` — newest bindings at
  head of env list, matching forward `lookup` in metacircular interp.
  Equivalent to the VM's reverse-index `lookup_env`.

## REPL

- `stinput`/`stoutput` primitives added — return stdin/stdout streams.
  Registered in init so bundled closures find them via the global table.
- `write-byte` flushes for piped output.
- `shen.initialise` (15-char name) must be called before `shen.repl`. Wraps
  `shen.initialise-environment` → `shen.initialise-lambda-forms` →
  `shen.initialise-signedfuncs`.
- REPL is functional. `shen.initialise` + `shen.repl` both execute and return.
  shen.initialise is non-idempotent: first call errors "set: first arg must be
  a symbol" (caught by trap-error), second call returns false. In test mode
  (stdin at EOF), shen.repl returns false immediately.
- **Key fixes enabling REPL:**
  - `*stinput*`/`*stoutput*`/`*sterror*` initialized as stream globals after bundle load
  - `write-byte` arg order fixed (ZINC RTL: byte first, stream last)
  - Call-stack depth was bumped (shen.initialise needs ~65K frames)
  - Stack isolation per CallFrame (commit 00299cf)
  - read-byte/write-byte bypass stack for stream args (commit 6247571)
  - trap-error state save/restore to prevent use-after-return (commit 6247571)
  - Tail-call mark cleanup in return/appterm (commit 27bdcbe)
- Name confusion: `shen.initialise_environment` (underscore, 27 chars) is a
  DIFFERENT function — only resets shen.*call*/shen.*infs* counters. Called by
  shen.loop each iteration. Not the setup function.

(tc -)
\* =============================================================================
   serialize-qbe.shen - walk the reduced bundle's global-table and emit QBE IR
   for the static closures (Slice 3).

   Parallel to serialize-reduced.shen: same shen-load sequence builds the same
   full-arity closures in global-table.  Instead of nat->csexp, each closure is
   lowered via qbe.shen's `lower` (over compile-zinc output) to a QBE function
   `function $clo_<name>(...)`, plus the shared data-literal section.

   Slice 3 lowers ONLY the four Test 1-4 closures (+, reverse, reverse-help,
   factorial) - the differential gate.  `lower` raises a catchable simple-error
   on the constructs still deferred to Slice 5 (cur / trap-error-with-closure /
   dynamic apply), so qbe-lower-try skips them rather than miscompiling.

   Usage:  shen-scheme script shen/serialize-qbe.shen  ->  globals.qbe
   ============================================================================= *\

\* Load the generated primitive tables (primitive?-names and the QBE
   prim-name->mangle->arity table). *\
(load "shen/prims-generated.shen")
(load "shen/qbe-prim-info.shen")

(load "shen/interp.shen")
(tc -)
(load "shen/compile.shen")
(load "shen/load.shen")
(tc -)
(load "shen/shen-kl-helpers.shen")
(load "shen/shen->kl.shen")
(load "shen/qbe-subset.shen")
(load "shen/qbe.shen")

\* === Compile .shen files through our own full-arity compiler (as
   serialize-reduced.shen).  Skips the HM type-checker files (not needed for
   the QBE subset). === *\
(tc -)
(define shen-eval-forms
  [] -> loaded
  [F | R] -> (do (interp-eval F) (shen-eval-forms R)))
(define shen-load
  Path -> (shen-eval-forms (shen->kl-forms (shen-read-file Path))))
(tc +)

(shen-load "shen/util.shen")
(shen-load "shen/types.shen")
(shen-load "shen/zinc.shen")
(shen-load "shen/compile.shen")
(shen-load "shen/normalize.shen")
(shen-load "shen/primitives.shen")
(shen-load "shen/interp.shen")
(shen-load "shen/toplevel.shen")
(shen-load "shen/load.shen")
(shen-load "shen/os-helpers.shen")
(shen-load "shen/shen-kl-helpers.shen")
(shen-load "shen/shen->kl.shen")

\* === Safe-wrapper alias for `+` (the Test 1 entry).  Point the bare name `+`
   at the safe.+ closure (same object), so the QBE driver can call @clo_plus. === *\
(tc -)
(define install-plus-alias
  -> (do
    (set global-table (cons [+ (lookup-global safe.+)] (value global-table)))
    aliases-installed))
(install-plus-alias)
(tc +)

\* === Add shen. prefix aliases (matches serialize-reduced.shen). === *\
(tc -)
(define shen.has-dot?
  "" -> false
  S -> (if (= "." (hdstr S)) true (shen.has-dot? (tlstr S))))
(define shen.add-prefix-aliases
  [] -> aliases-added
  [[Name Closure] | Rest] -> (do
    (if (shen.has-dot? (str Name))
        shen.skip
        (set global-table (cons [(intern (cn "shen." (str Name))) Closure]
                                (value global-table))))
    (shen.add-prefix-aliases Rest)))
(shen.add-prefix-aliases (value global-table))
(tc +)

\* === Emit QBE for the four Test 1-4 closures. === *\

\* All deduped closure names - the `global G` classification set. *\
(set qbe-table (dedupe-globals (value global-table)))

(define qbe-name-list
  [] -> []
  [[N _] | R] -> [N | (qbe-name-list R)])

(set qbe-all-names (qbe-name-list (value qbe-table)))

\* The six closures the differential driver calls (Tests 1-4 + let regression). *\
(set qbe-roots [+ reverse reverse-help factorial qbe-sub2 qbe-let-test])

\* lower wrapped in trap-error: unsupported constructs (cur / dynamic apply)
   raise a catchable simple-error; skip those closures.  `lower` resets its own
   (value qbe-datas) at entry, so accumulate each closure's data literals into
   a shared list. *\
(set qbe-all-datas [])

(define qbe-lower-try { symbol --> klambda --> string }
  N Code -> (trap-error
              (let Fn (lower N Code (value qbe-all-names))
                (do (set qbe-all-datas (append (value qbe-datas) (value qbe-all-datas)))
                    Fn))
              (lambda E "")))

\* Emit one closure (or "" if not a root / not static / not lowerable). *\
(define qbe-entry
  [N [lambda Code []]] ->
    (if (and (element? N (value qbe-roots)) (qbe-static-closure? N))
        (qbe-lower-try N (compile-zinc Code))
        "")
  _ -> "")

(define qbe-entries
  [] -> ""
  [E | R] -> (cn (qbe-entry E) (qbe-entries R))
  _ -> "")

\* Run the entries FIRST (each `lower` appends its data literals to
   qbe-all-datas), then emit the data section + function bodies. *\
(set qbe-fns (qbe-entries (value qbe-table)))

(set *qbe* (cn (qbe-datas-str (value qbe-all-datas))
               (value qbe-fns)))

(set *out* (open "globals.qbe" out))
(pr (value *qbe*) (value *out*))
(close (value *out*))

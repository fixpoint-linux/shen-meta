(tc -)

\* tc-hm-prims.shen — Stage 4: hand-curated primitive type table (~50 entries).
   Safe-subset only.  Types use the tc-hm-types.shen representation.
   Each entry: [name . scheme] where scheme is a forall-quantified type.
   MUST stay in sync with util.shen/types.shen primitive lists.
   This is the THIRD hand-curated sync (with exec_primitive and safe.X). *\

(load "shen/tc-hm-types.shen")

\* ===== Helper: build a curried arrow type from a list of arg types =====
   (tc-build-arrow [[con number] [con number]] [con number])
   → [arrow [con number] [arrow [con number] [con number]]] *\

(define tc-build-arrow
  { (list type) --> type --> type }
  [] Ret -> Ret
  [Dom] Ret -> [arrow Dom Ret]
  [Dom | Rest] Ret -> [arrow Dom (tc-build-arrow Rest Ret)])

\* ===== Helper: make a forall over tvar 0 =====
   (tc-poly1 [arrow [tvar 0] [tvar 0]]) → [forall [0] [arrow [tvar 0] [tvar 0]]]
   (tc-poly2 [arrow [tvar 0] [arrow [tvar 1] [tvar 0]]]) → [forall [0 1] ...] *\

(define tc-poly1
  { type --> type }
  T -> [forall [0] T])

(define tc-poly2
  { type --> type }
  T -> [forall [0 1] T])

(define tc-poly3
  { type --> type }
  T -> [forall [0 1 2] T])

(define tc-mono
  { type --> type }
  T -> T)

\* ===== Build the prim table =====
   Each entry: [Symbol . Scheme]
   We build it as a list and set prim-table. *\

(define tc-build-prim-table
  { --> (list (list symbol type)) }
  ->
  \* List ops *\
  [[(intern "cons")    (tc-poly2 (tc-build-arrow [[tvar 0] [app list [tvar 0]]] [app list [tvar 0]]))]
   [(intern "hd")      (tc-poly2 (tc-build-arrow [[app list [tvar 0]]] [tvar 1]))]
   [(intern "tl")      (tc-poly2 (tc-build-arrow [[app list [tvar 0]]] [tvar 1]))]
   \* Equality *\
   [(intern "=")       (tc-poly1 (tc-build-arrow [[tvar 0] [tvar 0]] [con boolean]))]
   \* Arithmetic: number -> number -> number *\
   [(intern "+")       (tc-mono (tc-build-arrow [[con number] [con number]] [con number]))]
   [(intern "-")       (tc-mono (tc-build-arrow [[con number] [con number]] [con number]))]
   [(intern "*")       (tc-mono (tc-build-arrow [[con number] [con number]] [con number]))]
   [(intern "/")       (tc-mono (tc-build-arrow [[con number] [con number]] [con number]))]
   \* Type predicates: A -> boolean *\
   [(intern "number?")  (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "string?")  (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "symbol?")  (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "boolean?") (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "cons?")    (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "absvector?") (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   \* Comparisons: number -> number -> boolean *\
   [(intern ">")       (tc-mono (tc-build-arrow [[con number] [con number]] [con boolean]))]
   [(intern "<")       (tc-mono (tc-build-arrow [[con number] [con number]] [con boolean]))]
   [(intern ">=")      (tc-mono (tc-build-arrow [[con number] [con number]] [con boolean]))]
   [(intern "<=")      (tc-mono (tc-build-arrow [[con number] [con number]] [con boolean]))]
   \* String ops *\
   [(intern "pos")     (tc-mono (tc-build-arrow [[con string] [con number]] [con string]))]
   [(intern "tlstr")   (tc-mono (tc-build-arrow [[con string]] [con string]))]
   [(intern "hdstr")   (tc-mono (tc-build-arrow [[con string]] [con string]))]
   [(intern "cn")      (tc-mono (tc-build-arrow [[con string] [con string]] [con string]))]
   [(intern "str")     (tc-poly1 (tc-build-arrow [[tvar 0]] [con string]))]
   [(intern "string->n") (tc-mono (tc-build-arrow [[con string]] [con number]))]
   [(intern "n->string") (tc-mono (tc-build-arrow [[con number]] [con string]))]
   [(intern "strlen")  (tc-mono (tc-build-arrow [[con string]] [con number]))]
   \* Absvector ops *\
   [(intern "absvector") (tc-poly1 (tc-build-arrow [[con number]] [con absvector]))]
   [(intern "address->") (tc-poly1 (tc-build-arrow [[con absvector] [con number] [tvar 0]] [tvar 0]))]
   [(intern "<-address") (tc-poly1 (tc-build-arrow [[con absvector] [con number]] [tvar 0]))]
   \* List ops *\
   [(intern "emptylist") (tc-poly1 (tc-build-arrow [[tvar 0]] [app list [tvar 0]]))]
   \* I/O *\
   [(intern "write-byte") (tc-mono (tc-build-arrow [[con number] [con stream]] [con number]))]
   [(intern "read-byte")  (tc-mono (tc-build-arrow [[con stream]] [con number]))]
   [(intern "read-file-as-string") (tc-mono (tc-build-arrow [[con string]] [con string]))]
   [(intern "open")   (tc-mono (tc-build-arrow [[con string] [con symbol]] [con stream]))]
   [(intern "close")  (tc-mono (tc-build-arrow [[con stream]] [app list [con zinc-value]]))]
   \* Shell / process prims (C VM exec_primitive; used by shell/shell.shen).
      exec-plan runs a decoded command plan and returns a plain list
      [exit-code stdout stderr] through eval-kl.  getcwd takes a
      dummy number (C pops & ignores it) and returns the cwd string.
      getpid mirrors getcwd: dummy number -> the process id (number),
      used by $$ shell expansion.  setenv/cd are string->...->boolean.
      All monomorphic. *\
   [(intern "exec-plan")    (tc-mono (tc-build-arrow [[app list [con zinc-value]]] [app list [con zinc-value]]))]
   [(intern "getcwd")       (tc-mono (tc-build-arrow [[con number]] [con string]))]
   [(intern "getpid")       (tc-mono (tc-build-arrow [[con number]] [con number]))]
   [(intern "setenv")       (tc-mono (tc-build-arrow [[con string] [con string]] [con boolean]))]
   [(intern "cd")           (tc-mono (tc-build-arrow [[con string]] [con boolean]))]
   \* Predicates *\
   [(intern "function?") (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "error?")    (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "stream?")   (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   \* Error handling *\
   [(intern "trap-error") (tc-poly2 (tc-build-arrow [[tvar 0] [arrow [con string] [tvar 0]]] [tvar 0]))]
   [(intern "simple-error") (tc-poly1 (tc-build-arrow [[con string]] [tvar 0]))]
   [(intern "error-to-string") (tc-poly1 (tc-build-arrow [[tvar 0]] [con string]))]
   \* fail: KLambda control-flow primitive (used in `<-` backtrack clauses).
      Never returns — throws — so its type can be ANYTHING.  Modelled
      as a nullary forall-quantified return.  Without this the unknown
      fallback (fresh binary arrow) clashes with the then-branch type
      in (if C T [fail]) constructions (zinc-t-tail, zinc-c-tail). *\
   [(intern "fail") (tc-poly1 (tc-build-arrow [] [tvar 0]))]
   \* Symbol/intern *\
   [(intern "intern") (tc-mono (tc-build-arrow [[con string]] [con symbol]))]
   \* State *\
   [(intern "set")   (tc-poly1 (tc-build-arrow [[con symbol] [tvar 0]] [tvar 0]))]
   [(intern "value") (tc-poly1 (tc-build-arrow [[con symbol]] [tvar 0]))]
   \* Eval *\
   [(intern "eval-kl") (tc-poly1 (tc-build-arrow [[con klambda]] [tvar 0]))]
   \* Time *\
   [(intern "get-time") (tc-mono (tc-build-arrow [[con symbol]] [con number]))]
   \* Tuples *\
   [(intern "@p")   (tc-poly2 (tc-build-arrow [[tvar 0] [tvar 1]] [prod [tvar 0] [tvar 1]]))]
   [(intern "fst")  (tc-poly2 (tc-build-arrow [[prod [tvar 0] [tvar 1]]] [tvar 0]))]
   [(intern "snd")  (tc-poly2 (tc-build-arrow [[prod [tvar 0] [tvar 1]]] [tvar 1]))]
   \* Code generation *\
   [(intern "gensym")    (tc-poly1 (tc-build-arrow [[tvar 0]] [con symbol]))]
   [(intern "variable?") (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "newvar")    (tc-mono (tc-build-arrow [] [con symbol]))]
   \* String extended *\
   [(intern "c-strlen")  (tc-mono (tc-build-arrow [[con string]] [con number]))]
   [(intern "char-code") (tc-mono (tc-build-arrow [[con string]] [con number]))]
   [(intern "substring") (tc-mono (tc-build-arrow [[con string] [con number] [con number]] [con string]))]
   \* Membership *\
   [(intern "element?")  (tc-poly1 (tc-build-arrow [[tvar 0] [app list [tvar 0]]] [con boolean]))]
   \* More list ops (Stage 4) *\
   [(intern "append")  (tc-poly1 (tc-build-arrow [[app list [tvar 0]] [app list [tvar 0]]] [app list [tvar 0]]))]
   [(intern "reverse") (tc-poly1 (tc-build-arrow [[app list [tvar 0]]] [app list [tvar 0]]))]
   [(intern "empty?")  (tc-poly1 (tc-build-arrow [[app list [tvar 0]]] [con boolean]))]
   \* assoc: maximally permissive (A --> B --> C).  Real KLambda sig
      would be (A, list (prod A B)) -> (prod A B) | [], but HM has no
      union type and Shen source sigs like (list (list symbol number))
      parse as (list (list symbol)) (parser takes only the first type
      arg of an inner (list ...)).  Returning a fresh tvar lets both
      (empty? (assoc ...)) and (hd (tl (assoc ...))) type-check. *\
   [(intern "assoc")   (tc-poly3 (tc-build-arrow [[tvar 0] [tvar 1]] [tvar 2]))]
   \* Boolean ops *\
   [(intern "not")     (tc-mono (tc-build-arrow [[con boolean]] [con boolean]))]
   \* Identity/generic *\
   [(intern "ps")      (tc-poly1 (tc-build-arrow [[tvar 0]] [tvar 0]))]
   \* Length *\
   [(intern "length")  (tc-poly1 (tc-build-arrow [[app list [tvar 0]]] [con number]))]
   \* User-defined Group-A predicates reached before their home file is
      collected into tc-global-sig-table (or via a redefinition in a later
      file).  These mirror the sigs in types.shen / util.shen.  Harmless
      duplicates: tc-prim-lookup checks prim-table first, so the sig-table
      entry (added later in tc-hm-collect-sigs) is shadowed. *\
   [(intern "primitive?")          (tc-mono (tc-build-arrow [[con symbol]] [con boolean]))]
   [(intern "instruction-keyword?") (tc-mono (tc-build-arrow [[con symbol]] [con boolean]))]
   \* Cross-file Group-A helpers.  These are defined in util.shen with
      sigs, but tc-hm-collect-sigs runs per-file and tc-hm-define
      removes the self-entry from tc-prim-table after checking each
      define, leaving lookup dependent on tc-global-sig-table at the
      moment of cross-file call.  Adding them to the prim-table directly
      removes that fragility.  Sigs mirror util.shen. *\
   [(intern "fold-str")     (tc-mono (tc-build-arrow [[app list [con string]]] [con string]))]
   [(intern "fold-append")  (tc-poly1 (tc-build-arrow [[app list [tvar 0]] [app list [app list [tvar 0]]]] [app list [tvar 0]]))]
   [(intern "intersperse")  (tc-poly1 (tc-build-arrow [[tvar 0] [app list [tvar 0]]] [app list [tvar 0]]))]
   [(intern "index_h")      (tc-poly1 (tc-build-arrow [[tvar 0] [app list [tvar 0]] [con number]] [con number]))]
   [(intern "idx")          (tc-poly1 (tc-build-arrow [[tvar 0] [app list [tvar 0]]] [con number]))]
   \* Compiler pipeline helpers (zinc.shen / normalize.shen).  These mirror
      the source sigs and are added here for the same fragility-removal
      reason as the util.shen helpers above: tc-hm-define strips the
      self-entry from tc-prim-table after each per-define check, leaving
      cross-file call-site lookup dependent on tc-global-sig-table being
      fully populated at the moment of call.  Without these entries,
      kl->zinc's body (which threads kmacros -> normalize-term -> debruijn
      -> zinc-c) hits the unknown-prim fallback (a fresh binary arrow)
      whenever sig-table lookup falls behind, producing a spurious
      arrow-typed body that fails body/ret unification. *\
   [(intern "zinc-c")         (tc-mono (tc-build-arrow [[con klambda]] [con zinc-code]))]
   [(intern "zinc-t")         (tc-mono (tc-build-arrow [[con klambda]] [con zinc-code]))]
   [(intern "kmacros")        (tc-mono (tc-build-arrow [[con klambda]] [con klambda]))]
   [(intern "normalize-term") (tc-mono (tc-build-arrow [[con klambda]] [con klambda]))]
   [(intern "debruijn")       (tc-mono (tc-build-arrow [[app list [con symbol]] [con klambda]] [con klambda]))]
   \* Meta-interpreter code-walkers.  Source sigs in interp.shen declare
      these as (list zinc-instruction) --> ..., but at runtime the value
      passed is the SAME opaque instruction stream interp's first arg
      carries (typed zinc-code): both extract-grab / count-grab loops walk
      the closure's code field C1 from a [lambda C1 E1] pattern, and that
      C1 is then passed back to interp as its first arg.  Declaring the
      arg as zinc-code here (instead of (list zinc-instruction)) keeps
      the checker's view of C1 consistent across the zinc-arity/drop-grabs
      calls and the recursive interp call in the apply clause - otherwise
      tc-unify hits "app vs other" (list zinc-instruction vs zinc-code)
      in the interp multi-arg apply body.  Narrow: only these two helpers
      get the override; zinc-value / zinc-code stay opaque elsewhere. *\
   [(intern "zinc-arity")     (tc-mono (tc-build-arrow [[con zinc-code]] [con number]))]
   [(intern "drop-grabs")     (tc-mono (tc-build-arrow [[con number] [con zinc-code]] [con zinc-code]))]
   ])

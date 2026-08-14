(tc -)

\* tc-hm-w.shen — Stage 2: Algorithm W on the core expression language.
   Safe-subset only; mirrors shen-kl-helpers.shen style.
   Depends on: tc-hm-types.shen for type rep + tc-unify + subst.
   Loads os-helpers transitively through tc-hm-types. *\

(load "shen/tc-hm-types.shen")

\* ===== Primitive type table placeholder =====
   The real table is in tc-hm-prims.shen (Stage 4).
   For Stage 2, we provide a minimal bootstrap table.
   Calls to undefined primitives return a fresh tvar (permissive). *\

(set tc-prim-table [])

(define tc-prim-lookup
  { symbol --> type }
  Name -> (let Pair (tc-assoc Name (%% value tc-prim-table))
            (if (tc-empty? Pair)
                \* Not in prim-table — try cross-define sigs *\
                (let Pair2 (tc-assoc Name (%% value tc-global-sig-table))
                  (if (tc-empty? Pair2)
                      \* Unknown: a fresh tvar is SOUND for genuinely-unknown
                         functions.  The prior binary arrow was an arbitrary
                         arity-2 assumption that produced false rejects on
                         non-2-arg calls (partial-application arrows).  A tvar
                         unifies with whatever the caller demands. *\
                      (tc-fresh-tvar (intern ""))
                      (tc-instantiate (hd (tl Pair2)))))
                (tc-instantiate (hd (tl Pair))))))

\* ===== Expression classification ===== *\

(define tc-expr-tag
  { expr --> symbol }
  X -> (if (symbol? X) symbol
          (if (number? X) number
              (if (string? X) string
                  (if (boolean? X) boolean
                      (if (= X []) empty-list
                          (if (cons? X)
                              (tc-expr-head-tag (hd X))
                              unknown)))))))

(define tc-expr-head-tag
  { expr --> symbol }
  X -> (if (symbol? X)
           (let S X
             (if (= S (intern "lambda")) lambda
                 (if (= S (intern "/.")) slash-dot
                     (if (= S (intern "let")) let-form
                         (if (= S (intern "if")) if-form
                             (if (= S (intern "and")) and-form
                                 (if (= S (intern "or")) or-form
                                     (if (= S (intern "do")) do-form
                                         (if (= S (intern "set")) set-form
                                             (if (= S (intern "%%")) prim-escape
                                                 (if (= S (intern "cons")) cons-form
                                                     (if (= S (intern "protect")) protect-form
                                                         (if (= S (intern "function")) function-form
                                                             app-form)))))))))))))
           app-form))

\* ===== infer: main Algorithm W entry point =====
   Returns [ok [Subst Type]] or [fail Reason]. *\

(define tc-infer
  { env --> expr --> subst --> infer-result }
  Env Expr Sub -> (let Tag (tc-expr-tag Expr)
                    (if (= Tag symbol)
                        (tc-infer-var Env Expr Sub)
                        (if (= Tag number)
                            (tc-infer-lit [con number] Sub)
                            (if (= Tag string)
                                (tc-infer-lit [con string] Sub)
                                (if (= Tag boolean)
                                    (tc-infer-lit [con boolean] Sub)
                                    (if (= Tag empty-list)
                                        (tc-infer-empty Sub)
                                        (if (= Tag lambda)
                                            (tc-infer-lambda Env Expr Sub)
                                            (if (= Tag slash-dot)
                                                (tc-infer-slash-dot Env Expr Sub)
                                                (if (= Tag let-form)
                                                    (tc-infer-let Env Expr Sub)
                                                    (if (= Tag if-form)
                                                        (tc-infer-if Env Expr Sub)
                                                        (if (= Tag and-form)
                                                            (tc-infer-bool-op Env Expr Sub)
                                                            (if (= Tag or-form)
                                                                (tc-infer-bool-op Env Expr Sub)
                                                                (if (= Tag do-form)
                                                                    (tc-infer-do Env Expr Sub)
                                                                    (if (= Tag set-form)
                                                                        (tc-infer-set Env Expr Sub)
                                                                        (if (= Tag prim-escape)
                                                                            (tc-infer-prim-escape Env Expr Sub)
                                                                            (if (= Tag cons-form)
                                                                                (tc-infer-cons Env Expr Sub)
                                                                                (if (= Tag protect-form)
                                                                                    (tc-infer-protect Env Expr Sub)
                                                                                    (if (= Tag function-form)
                                                                                        (tc-infer-function Env Expr Sub)
                                                                                        (tc-infer-app Env Expr Sub))))))))))))))))))))

\* ===== prim-known?: is Name in the prim-table or sig-table?
   Lets tc-infer-var distinguish "known function used as a value"
   (instantiate its scheme) from "unbound Shen global" (treat as
   klambda top).  Function-call position (tc-infer-app) always uses
   tc-prim-lookup, which falls back to a fresh arrow for unknown —
   that permissiveness is wanted at call sites but NOT at value sites. *\

(define tc-prim-known?
  { symbol --> boolean }
  Name -> (if (tc-empty? (tc-assoc Name (%% value tc-prim-table)))
              (if (tc-empty? (tc-assoc Name (%% value tc-global-sig-table)))
                  false
                  true)
              true))

\* ===== Variable lookup =====
   Position-aware: a bare symbol reaching tc-infer-var is in VALUE
   position (a function-call head goes through tc-infer-app, which uses
   tc-prim-lookup directly).  For value position:
     - Bound in env: use env type (instantiate scheme).
     - In prim-table OR sig-table (known function used as a value):
       instantiate its scheme.
     - Otherwise (unbound, e.g. a Shen global like global-table referenced
       by bare name in source): treat as klambda — the sequent-calculus
       top type.  The previous behavior returned a fresh function-arrow,
       which fatally conflicted with primitives like (value S) whose arg
       is symbol: an arrow cannot unify with symbol, so every body that
       touched a Shen global failed at the very first primitive call. *\

(define tc-infer-var
  { env --> symbol --> subst --> infer-result }
  Env Name Sub -> (let Pair (tc-assoc Name Env)
                    (if (tc-empty? Pair)
                        (if (tc-prim-known? Name)
                            (let PT (tc-prim-lookup Name)
                              [ok [Sub PT]])
                            [ok [Sub [con klambda]]])
                        \* In local env — tc-instantiate if it's a scheme *\
                        (let Type (hd (tl Pair))
                          [ok [Sub (tc-instantiate Type)]]))))

(define tc-infer-lit
  { type --> subst --> infer-result }
  Type Sub -> [ok [Sub Type]])

\* ===== Empty list: [] — typed as a fresh tvar.
   In KLambda the empty list is heavily overloaded: it is the empty
   proper list (type [app list A]), the empty code fragment (type
   zinc-code), the empty zinc-value (the [cons] tag without arguments),
   and the empty environment.  Typing it strictly as [app list fresh]
   breaks every body that passes [] as a zinc-code or zinc-value
   argument (e.g. (zinc-c-tail E []) where the sig is klambda --> zinc-code
   --> zinc-code).  Using a fresh tvar lets the surrounding context pin
   it down (sig arg type, primitive domain, return type) while still
   allowing test-w-4-empty-list's check (the tvar unifies with
   [app list A] when the context asks for a list).  Documented Stage-1
   soundness gap: a heterogeneous use of [] across multiple branches
   will not be caught. *\

(define tc-infer-empty
  { subst --> infer-result }
  Sub -> [ok [Sub (tc-fresh-tvar (intern ""))]])

\* ===== Lambda: (lambda X Body) =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-lambda
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "lambda")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let Arg (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let Body (hd Rest2)
                        (let ArgType (tc-fresh-tvar (intern ""))
                          (let NewEnv [[Arg ArgType] | Env]
                            (let R (tc-infer NewEnv Body Sub)
                              (if (tc-ok? R)
                                  (let Pair (tc-ok-subst-type R)
                                    (let FinalSub (hd Pair)
                                      (let BodyType (hd (tl Pair))
                                        [ok [FinalSub [arrow (tc-apply-subst FinalSub ArgType) BodyType]]])))
                                  R)))))
                      [fail "infer-lambda: malformed lambda"])))
              [fail "infer-lambda: malformed lambda"]))
        [fail "infer-lambda: malformed lambda"]))

\* ===== Slash-dot: (/. Args Body) — multi-arg lambda =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-slash-dot
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "/.")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let Arg (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let Body (hd Rest2)
                        (if (cons? Arg)
                            (tc-infer-slash-dot-multi Env Arg Body Sub)
                            (tc-infer-slash-dot-single Env Arg Body Sub)))
                      [fail "infer-slash-dot: malformed"])))
              [fail "infer-slash-dot: malformed"]))
        [fail "infer-slash-dot: malformed"]))

(define tc-infer-slash-dot-single
  { env --> symbol --> expr --> subst --> infer-result }
  Env Arg Body Sub -> (tc-infer-lambda Env [lambda Arg Body] Sub))

(define tc-infer-slash-dot-multi
  { env --> (list symbol) --> expr --> subst --> infer-result }
  Env Args Body Sub ->
    (if (cons? Args)
        (let Arg (hd Args)
          (let Rest (tl Args)
            (if (cons? Rest)
                (tc-infer-lambda Env [lambda Arg [/. Rest Body]] Sub)
                (tc-infer-lambda Env [lambda Arg Body] Sub))))
        [fail "infer-slash-dot-multi: malformed"]))

\* ===== Let: (let X E B) with let-generalization =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-let
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "let")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let Var (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let E (hd Rest2)
                        (let Rest3 (tl Rest2)
                          (if (cons? Rest3)
                              (let B (hd Rest3)
                                (let R (tc-infer Env E Sub)
                                  (if (tc-ok? R)
                                      (let Pair (tc-ok-subst-type R)
                                        (let Sub1 (hd Pair)
                                          (let TypeE (hd (tl Pair))
                                            (let Scheme (tc-generalize Env TypeE)
                                              (let NewEnv [[Var Scheme] | Env]
                                                (tc-infer NewEnv B Sub1))))))
                                      R)))
                              [fail "infer-let: malformed let"])))
                      [fail "infer-let: malformed let"])))
              [fail "infer-let: malformed let"]))
        [fail "infer-let: malformed let"]))

\* ===== Guard-driven type refinement (sound narrowing) =====
   When an if-condition is a type-predicate guard (cons?/symbol?/number?/
   string?/boolean?) applied to a variable X, the guard genuinely
   establishes X's type in the THEN-branch.  We refine X's binding in
   the env passed to the then-branch (and to the continuation of an
   and), so a body like (if (cons? T) (let H (hd T) ...)) type-checks
   even when T's declared sig is opaque (e.g. [con type]).

   Soundness: the refinement is sound because the guard establishes the
   type at runtime.  The refined env is threaded ONLY into the then/true
   branch and the and-continuation — never into the else branch.  The
   refinement PREPENDS a new [X RefinedType] binding to env, shadowing
   any existing X binding via tc-assoc's first-match semantics; we never
   widen or destroy the original binding.  The else branch and any code
   after the if continue to see X's original (unrefined) type.

   Refined types:
     (cons? X)    -> [app list fresh]   (cons cells are list-shaped;
                                          matches the hd/tl domain)
     (symbol? X)  -> [con symbol]
     (number? X)  -> [con number]
     (string? X)  -> [con string]
     (boolean? X) -> [con boolean]

   Limitation (not a soundness issue): bodies that, after the guard,
   pass X to a tc-accessor (tc-con-name, tc-arrow-dom, tc-forall-vars,
   ...) whose sig expects the OPAQUE con form [con type] are not helped
   — the refinement models X as a list, but the accessor models its arg
   as the opaque type.  Reconciling these two views needs a richer type
   system (Stage 8).  Such defines stay FAIL with a different reason
   (con/list instead of the original con/list at the guard hd) — no
   regression in the OK count.  Likewise bodies that pass an opaque arg
   to tc-assoc (whose sig expects a list) are unaffected by this change. *\

(define tc-guard-pred?
  { symbol --> boolean }
  P -> (if (= P (intern "cons?")) true
       (if (= P (intern "symbol?")) true
       (if (= P (intern "number?")) true
       (if (= P (intern "string?")) true
       (if (= P (intern "boolean?")) true
           false))))))

\* tc-guard-refined-type: map a guard predicate symbol to the type it
   establishes.  Only called when (tc-guard-pred? P) is true; the
   [con klambda] fallback keeps the function total. *\

(define tc-guard-refined-type
  { symbol --> type }
  P -> (let Fresh (tc-fresh-tvar (intern ""))
         (if (= P (intern "cons?")) [app list Fresh]
         (if (= P (intern "symbol?")) [con symbol]
         (if (= P (intern "number?")) [con number]
         (if (= P (intern "string?")) [con string]
         (if (= P (intern "boolean?")) [con boolean]
             [con klambda])))))))

\* tc-refine-env-for-atom-guard: if Expr is (PRED? X) for a recognized
   guard predicate PRED? and a bare symbol X, prepend [X RefinedType]
   to Env (shadowing any existing X binding).  Otherwise return Env
   unchanged.  Only singleton-argument guards are refined —
   (cons? (hd Y)) etc. are left alone (cannot refine a sub-expression). *\

(define tc-refine-env-for-atom-guard
  { env --> expr --> env }
  Env Expr ->
    (if (cons? Expr)
        (let Hd (hd Expr)
          (if (symbol? Hd)
              (if (tc-guard-pred? Hd)
                  (let Args (tl Expr)
                    (if (cons? Args)
                        (if (tc-empty? (tl Args))
                            (let X (hd Args)
                              (if (symbol? X)
                                  (let RefinedType (tc-guard-refined-type Hd)
                                    [[X RefinedType] | Env])
                                  Env))
                            Env)
                        Env))
                  Env)
              Env))
        Env))

\* tc-refine-env-from-cond: walk a condition (a single guard or an
   and-chain of guards) and accumulate refinements into Env.  Handles
   (cons? X), (symbol? X), ..., and (and A B) recursively (nested ands
   via recursion).  Returns Env — possibly extended with shadowing
   refined bindings — for use in the then-branch of an if or the
   continuation of an and.  Non-guard conditions and n-ary (>2) ands
   return Env unchanged (no refinement; no regression). *\

(define tc-refine-env-from-cond
  { env --> expr --> env }
  Env Cond ->
    (if (cons? Cond)
        (let Hd (hd Cond)
          (if (symbol? Hd)
              (if (= Hd (intern "and"))
                  (let Rest (tl Cond)
                    (if (cons? Rest)
                        (if (cons? (tl Rest))
                            (if (tc-empty? (tl (tl Rest)))
                                (let A (hd Rest)
                                  (let B (hd (tl Rest))
                                    (tc-refine-env-from-cond
                                      (tc-refine-env-from-cond Env A)
                                      B)))
                                Env)
                            Env)
                        Env))
                  (tc-refine-env-for-atom-guard Env Cond))
              Env))
        Env))

\* ===== If: (if C T E) =====
   Dispatch via explicit head-symbol check (host-Shen compatible).
   Guard refinement: the then-branch T is typed in an env refined by
   the condition C (so (if (cons? X) ...) narrows X in T).  The
   else-branch E uses the original, unrefined env. *\

(define tc-infer-if
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "if")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let C (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let T (hd Rest2)
                        (let Rest3 (tl Rest2)
                          (if (cons? Rest3)
                              (let E (hd Rest3)
                                (let RC (tc-infer Env C Sub)
                                  (if (tc-ok? RC)
                                      (let PairC (tc-ok-subst-type RC)
                                        (let Sub1 (hd PairC)
                                          (let TypeC (hd (tl PairC))
                                            (let RC2 (tc-unify TypeC [con boolean] Sub1)
                                              (if (tc-ok? RC2)
                                                  (let Sub2 (tc-ok-subst RC2)
                                                    (let RT (tc-infer (tc-refine-env-from-cond Env C) T Sub2)
                                                      (if (tc-ok? RT)
                                                          (let PairT (tc-ok-subst-type RT)
                                                            (let Sub3 (hd PairT)
                                                              (let TypeT (hd (tl PairT))
                                                                (let RE (tc-infer Env E Sub3)
                                                                  (if (tc-ok? RE)
                                                                      (let PairE (tc-ok-subst-type RE)
                                                                        (let Sub4 (hd PairE)
                                                                          (let TypeE (hd (tl PairE))
                                                                            (let RU (tc-unify TypeT TypeE Sub4)
                                                                              (if (tc-ok? RU)
                                                                                  (let Sub5 (tc-ok-subst RU)
                                                                                    [ok [Sub5 (tc-apply-subst Sub5 TypeT)]])
                                                                                  RU)))))
                                                                      RE)))))
                                                          RT)))
                                                  RC2)))))
                                      RC)))
                              [fail "infer-if: malformed if"])))
                      [fail "infer-if: malformed if"])))
              [fail "infer-if: malformed if"]))
        [fail "infer-if: malformed if"]))

\* ===== and/or: both args must be boolean, result is boolean =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-bool-op
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr)
             (let Hd (hd Expr)
               (if (= Hd (intern "and")) true
                   (= Hd (intern "or")))))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let A (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let B (hd Rest2)
                        (let RA (tc-infer Env A Sub)
                          (if (tc-ok? RA)
                              (let PairA (tc-ok-subst-type RA)
                                (let Sub1 (hd PairA)
                                  (let TypeA (hd (tl PairA))
                                    (let RU1 (tc-unify TypeA [con boolean] Sub1)
                                      (if (tc-ok? RU1)
                                          (let Sub2 (tc-ok-subst RU1)
                                            (let RB (tc-infer (tc-refine-env-from-cond Env A) B Sub2)
                                              (if (tc-ok? RB)
                                                  (let PairB (tc-ok-subst-type RB)
                                                    (let Sub3 (hd PairB)
                                                      (let TypeB (hd (tl PairB))
                                                        (let RU2 (tc-unify TypeB [con boolean] Sub3)
                                                          (if (tc-ok? RU2)
                                                              [ok [(tc-ok-subst RU2) [con boolean]]]
                                                              RU2)))))
                                                  RB)))
                                          RU1)))))
                              RA)))
                      [fail "infer-bool-op: malformed"])))
              [fail "infer-bool-op: malformed"]))
        [fail "infer-bool-op: malformed"]))

\* ===== do: (do E1 E2 ... En) — return type of last =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-do
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "do")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let E (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let R (tc-infer Env E Sub)
                        (if (tc-ok? R)
                            (let Pair (tc-ok-subst-type R)
                              (let Sub1 (hd Pair)
                                (tc-infer-do Env [do | Rest2] Sub1)))
                            R))
                      (tc-infer Env E Sub))))
              [ok [Sub [con zinc-value]]]))
        [fail "infer-do: malformed"]))

\* ===== set: (set Var Value) — result is the value's type =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-set
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "set")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let Var (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let Val (hd Rest2)
                        (if (symbol? Var)
                            (tc-infer Env Val Sub)
                            [fail "set: first arg must be symbol"]))
                      [fail "infer-set: malformed"])))
              [fail "infer-set: malformed"]))
        [fail "infer-set: malformed"]))

\* ===== %%: (%% Prim args...) — primitive escape =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-prim-escape
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "%%")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let Prim (hd Rest)
                (if (symbol? Prim)
                    (let PrimType (tc-prim-lookup Prim)
                      (tc-infer-app-args Env PrimType (tl Rest) Sub))
                    [fail "%%: first arg must be symbol"]))
              [fail "infer-prim-escape: malformed"]))
        [fail "infer-prim-escape: malformed"]))

\* ===== cons data constructor: [cons H T] — permissive.
   In KLambda a cons cell is heavily overloaded: it builds proper lists,
   it builds tagged-data expressions ([lambda X Body], [access N], ...),
   and it builds opaque code fragments ([grab | C], [prim F | C], ...).
   Strictly typing it as [app list A] (forcing H : A and T : [app list A])
   is WRONG for the tagged-data and code-fragment uses: there T is a
   sibling fragment, not a list tail of the same element type, and the
   whole cell's type is klambda / zinc-code, not a list.

   The Stage-1 pragmatic fix: type [cons H T] as a FRESH TVAR (the
   cell's content is opaque), and let the surrounding context pin it
   down — the return-type unification, a primitive's expected arg
   type, or a sig's arg type.  This loses element-type tracking but
   accepts the cross-shape bodies that KLambda actually contains.

   This is a documented soundness gap (Stage 1): a body like
   [cons 1 [cons "x" []]] (heterogeneous) will type-check against any
   ret-type, since its inferred type is a fresh tvar that unifies with
   anything.  Tightening this is Stage 8 work (shape refinement). *\

(define tc-infer-cons
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "cons")))
        [ok [Sub (tc-fresh-tvar (intern ""))]]
        [fail "infer-cons: malformed cons"]))

\* ===== list-literal: [cons E1 E2 ... En] with n>=3 (or Rest = [E1..En]) =====
   Type as [app list A] where A fresh, unified with each element. *\

(define tc-infer-list-literal
  { env --> (list expr) --> subst --> infer-result }
  Env Elems Sub -> (let A (tc-fresh-tvar (intern ""))
                     (tc-infer-list-literal-elems Env Elems A Sub)))

(define tc-infer-list-literal-elems
  { env --> (list expr) --> type --> subst --> infer-result }
  Env Elems A Sub ->
    (if (cons? Elems)
        (let E (hd Elems)
          (let Rest (tl Elems)
            (let RE (tc-infer-list-elem Env E Sub)
              (if (tc-ok? RE)
                  (let Pair (tc-ok-subst-type RE)
                    (let Sub1 (hd Pair)
                      (let TypeE (hd (tl Pair))
                        (let RU (tc-unify TypeE A Sub1)
                          (if (tc-ok? RU)
                              (let Sub2 (tc-ok-subst RU)
                                (tc-infer-list-literal-elems Env Rest (tc-apply-subst Sub2 A) Sub2))
                              RU)))))
                  RE))))
        [ok [Sub [app list A]]]))

\* ===== infer-list-elem: type a single element in a list literal =====
   Unbound symbol -> [con symbol] (literal), bound symbol -> lookup,
   non-symbol -> normal inference. *\

(define tc-infer-list-elem
  { env --> expr --> subst --> infer-result }
  Env E Sub -> (if (symbol? E)
                    (let Pair (tc-assoc E Env)
                      (if (tc-empty? Pair)
                          \* Unbound symbol: treat as literal symbol *\
                          [ok [Sub [con symbol]]]
                          \* Bound in env: use its type *\
                          [ok [Sub (tc-instantiate (hd (tl Pair)))]]))
                    (tc-infer Env E Sub)))

\* ===== protect: (protect X) — pass through =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-protect
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "protect")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let X (hd Rest)
                (tc-infer Env X Sub))
              [fail "infer-protect: malformed"]))
        [fail "infer-protect: malformed"]))

\* ===== function: (function X) — lookup X as a value =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

(define tc-infer-function
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr) (= (hd Expr) (intern "function")))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let Name (hd Rest)
                (if (symbol? Name)
                    (tc-infer-var Env Name Sub)
                    [fail "function: arg must be symbol"]))
              [fail "infer-function: malformed"]))
        [fail "infer-function: malformed"]))

\* ===== Application: (F a1..aN) ===== *\

(define tc-infer-app
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (cons? Expr)
        (let F (hd Expr)
          (let Args (tl Expr)
            (if (symbol? F)
                \* Named function call *\
                (let FunType (tc-prim-lookup F)
                  (tc-infer-app-args Env FunType Args Sub))
                \* Higher-order: tc-infer F, then apply *\
                (let RF (tc-infer Env F Sub)
                  (if (tc-ok? RF)
                      (let PairF (tc-ok-subst-type RF)
                        (let Sub1 (hd PairF)
                          (let TypeF (hd (tl PairF))
                            (tc-infer-app-args Env TypeF Args Sub1))))
                      RF)))))
        [fail "infer-app: malformed"]))

\* ===== infer-app-args: apply function type to argument list ===== *\

(define tc-infer-app-args
  { env --> type --> (list expr) --> subst --> infer-result }
  Env FunType Args Sub ->
    (if (= Args [])
        [ok [Sub FunType]]
        (let RetType (tc-fresh-tvar (intern ""))
          (let DomType0 (tc-fresh-tvar (intern ""))
            (let ArrowType [arrow DomType0 RetType]
              (tc-infer-app-one Env FunType ArrowType RetType Args Sub))))))

\* ===== infer-app-one: apply one argument, then recurse =====
   Split out to avoid deep nested-let chains that the safe-subset
   alpha-convert cannot rename. *\

(define tc-infer-app-one
  { env --> type --> type --> type --> (list expr) --> subst --> infer-result }
  Env FunType ArrowType RetType Args Sub ->
    (let RU (tc-unify FunType ArrowType Sub)
      (if (tc-ok? RU)
          (tc-infer-app-oneb Env ArrowType RetType Args RU)
          RU)))

\* ===== infer-app-oneb: after successful unify, infer the argument ===== *\

(define tc-infer-app-oneb
  { env --> type --> type --> (list expr) --> infer-result --> infer-result }
  Env ArrowType RetType Args RU ->
    (let Sub1 (tc-ok-subst RU)
      (let DomType (tc-apply-subst Sub1 (tc-arrow-dom ArrowType))
        (let RArg (tc-infer Env (hd Args) Sub1)
          (if (tc-ok? RArg)
              (let PairArg (tc-ok-subst-type RArg)
                (tc-infer-app-two Env DomType RetType Args Sub1 PairArg))
              RArg)))))

\* ===== infer-app-two: unify argument type with domain, then recurse ===== *\

(define tc-infer-app-two
  { env --> type --> type --> (list expr) --> subst --> (list subst type) --> infer-result }
  Env DomType RetType Args Sub1 PairArg ->
    (let Sub2 (hd PairArg)
      (let TypeArg (hd (tl PairArg))
        (let RU2 (tc-unify TypeArg DomType Sub2)
          (if (tc-ok? RU2)
              (let Sub3 (tc-ok-subst RU2)
                (let CodType (tc-apply-subst Sub3 RetType)
                  (tc-infer-app-args Env CodType (tl Args) Sub3)))
              RU2)))))

\* ===== Result helpers for tc-infer ===== *\

(define tc-ok-subst-type
  { infer-result --> (list subst type) }
  [ok [Sub Type]] -> [Sub Type]
  _ -> [[] [con error]])

\* ===== env-lookup-type: get the type of a name from env (without substitution) =====
   Returns the raw type/scheme from env, or tc-fresh-tvar if not found. *\

(define tc-env-lookup-type
  { env --> symbol --> type }
  Env Name -> (let Pair (tc-assoc Name Env)
                (if (tc-empty? Pair)
                    (tc-fresh-tvar (intern ""))
                    (hd (tl Pair)))))

\* ===== infer-define-body: type-check a define body given arg types and return type =====
   Used by Stage 3/4 integration. *\

(define tc-infer-define-body
  { env --> expr --> type --> subst --> infer-result }
  Env Body RetType Sub ->
    (let R (tc-infer Env Body Sub)
      (if (tc-ok? R)
          (let Pair (tc-ok-subst-type R)
            (let Sub1 (hd Pair)
              (let BodyType (hd (tl Pair))
                (let RU (tc-unify BodyType RetType Sub1)
                  (if (tc-ok? RU)
                      [ok [(tc-ok-subst RU) BodyType]]
                      RU)))))
          R)))

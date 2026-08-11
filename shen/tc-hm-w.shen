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
                      \* Unknown: return permissive type *\
                      (let T (tc-fresh-tvar (intern ""))
                        (tc-fresh-arrow T))
                      (tc-instantiate (hd (tl Pair2)))))
                (tc-instantiate (hd (tl Pair))))))

\* fresh-arrow: build arrow T -> T -> ... -> T (binary by default) *\

(define tc-fresh-arrow
  { type --> type }
  T -> (let T1 (tc-fresh-tvar (intern ""))
         [arrow T [arrow T1 T]]))

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

\* ===== Variable lookup ===== *\

(define tc-infer-var
  { env --> symbol --> subst --> infer-result }
  Env Name Sub -> (let Pair (tc-assoc Name Env)
                    (if (tc-empty? Pair)
                        \* Not in local env — try prim table *\
                        (let PT (tc-prim-lookup Name)
                          [ok [Sub PT]])
                        \* In local env — tc-instantiate if it's a scheme *\
                        (let Type (hd (tl Pair))
                          [ok [Sub (tc-instantiate Type)]]))))

(define tc-infer-lit
  { type --> subst --> infer-result }
  Type Sub -> [ok [Sub Type]])

(define tc-infer-empty
  { subst --> infer-result }
  Sub -> (let A (tc-fresh-tvar (intern ""))
           [ok [Sub [app list A]]]))

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

\* ===== If: (if C T E) =====
   Dispatch via explicit head-symbol check (host-Shen compatible). *\

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
                                                    (let RT (tc-infer Env T Sub2)
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
                                            (let RB (tc-infer Env B Sub2)
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

\* ===== cons data constructor: [cons H T] with 2 args =====
   H : A,  T : [app list A],  result : [app list A]
   If 3+ elements after cons, treat as list literal. *\

(define tc-infer-cons
  { env --> expr --> subst --> infer-result }
  Env Expr Sub ->
    (if (and (cons? Expr)
             (let Hd (hd Expr)
               (= Hd (intern "cons"))))
        (let Rest (tl Expr)
          (if (cons? Rest)
              (let H (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let T (hd Rest2)
                        (let Rest3 (tl Rest2)
                          \* 3+ elements? -> list literal *\
                          (if (cons? Rest3)
                              (tc-infer-list-literal Env Rest Sub)
                              \* Exactly 2 args: normal cons typing *\
                              (let A (tc-fresh-tvar (intern ""))
                                (let RH (tc-infer Env H Sub)
                                  (if (tc-ok? RH)
                                      (let PairH (tc-ok-subst-type RH)
                                        (let Sub1 (hd PairH)
                                          (let TypeH (hd (tl PairH))
                                            (let RU1 (tc-unify TypeH A Sub1)
                                              (if (tc-ok? RU1)
                                                  (let Sub2 (tc-ok-subst RU1)
                                                    (let AT (tc-apply-subst Sub2 A)
                                                      (let ListA [app list AT]
                                                        (let RT (tc-infer Env T Sub2)
                                                          (if (tc-ok? RT)
                                                              (let PairT (tc-ok-subst-type RT)
                                                                (let Sub3 (hd PairT)
                                                                  (let TypeT (hd (tl PairT))
                                                                    (let RU2 (tc-unify TypeT ListA Sub3)
                                                                      (if (tc-ok? RU2)
                                                                          [ok [(tc-ok-subst RU2) [app list (tc-apply-subst (tc-ok-subst RU2) AT)]]]
                                                                          RU2)))))
                                                              RT)))))
                                                  RU1)))))
                                        RH))))))
                      (tc-infer-list-literal Env Rest Sub))))
              [fail "infer-cons: malformed cons"]))
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
  { env --> type --> type --> (list expr) --> subst --> infer-result }
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

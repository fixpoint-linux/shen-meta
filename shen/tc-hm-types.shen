(tc -)

\* tc-hm-types.shen — Stage 1: type representation + unification + substitution.
   Safe-subset only; mirrors shen-kl-helpers.shen style.
   No non-linear patterns; uses if-based dispatch for clarity.
   Depends on: os-helpers (append, reverse, empty?, assoc, element?, not) + primitives. *\

\* ===== Inline list helpers (tc- prefixed to avoid host collisions) =====
   Replaces os-helpers.shen dependency. *\

(define tc-empty?
  { (list A) --> boolean }
  [] -> true
  _ -> false)

(define tc-assoc
  { A --> (list (list A B)) --> (list A B) }
  Key [] -> []
  Key [[K V] | Rest] -> (if (= K Key) [K V] (tc-assoc Key Rest))
  _ _ -> [])

(define tc-element?
  { A --> (list A) --> boolean }
  X [] -> false
  X [Y | Rest] -> (if (= X Y) true (tc-element? X Rest))
  _ _ -> false)

(define tc-append
  { (list A) --> (list A) --> (list A) }
  [] Ys -> Ys
  [X | Xs] Ys -> [X | (tc-append Xs Ys)]
  _ _ -> [])

(define tc-reverse
  { (list A) --> (list A) }
  L -> (tc-reverse-help L []))

(define tc-reverse-help
  { (list A) --> (list A) --> (list A) }
  [] Acc -> Acc
  [X | Xs] Acc -> (tc-reverse-help Xs [X | Acc])
  _ _ -> [])

\* ===== Fresh type variable counter ===== *\

(set tc-counter 0)

(define tc-fresh-tvar
  { --> type }
  -> (let N (%% value tc-counter)
       (do (%% set tc-counter (+ N 1))
           [tvar N])))

\* ===== Type tag dispatch ===== *\

\* ===== Type tag dispatch — explicit head-symbol checks (host-Shen compatible) ===== *\

(define tc-type-tag
  { type --> symbol }
  T -> (if (cons? T)
           (let H (hd T)
             (if (= H (intern "tvar")) tvar
                 (if (= H (intern "con")) con
                     (if (= H (intern "arrow")) arrow
                         (if (= H (intern "app")) app
                             (if (= H (intern "prod")) prod
                                 (if (= H (intern "forall")) forall
                                     unknown)))))))
           unknown))

(define tc-tvar-id
  { type --> number }
  T -> (if (and (cons? T) (= (hd T) (intern "tvar")))
           (hd (tl T))
           -1))

(define tc-con-name
  { type --> symbol }
  T -> (if (and (cons? T) (= (hd T) (intern "con")))
           (hd (tl T))
           (intern "")))

(define tc-arrow-dom
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "arrow")))
           (hd (tl T))
           [con error]))

(define tc-arrow-cod
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "arrow")))
           (hd (tl (tl T)))
           [con error]))

(define tc-app-con
  { type --> symbol }
  T -> (if (and (cons? T) (= (hd T) (intern "app")))
           (hd (tl T))
           (intern "")))

(define tc-app-arg
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "app")))
           (hd (tl (tl T)))
           [con error]))

(define tc-prod-fst
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "prod")))
           (hd (tl T))
           [con error]))

(define tc-prod-snd
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "prod")))
           (hd (tl (tl T)))
           [con error]))

(define tc-forall-vars
  { type --> (list number) }
  T -> (if (and (cons? T) (= (hd T) (intern "forall")))
           (hd (tl T))
           []))

(define tc-forall-body
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "forall")))
           (hd (tl (tl T)))
           [con error]))

\* ===== walk: follow substitution bindings to canonical form ===== *\

(define tc-walk
  { type --> subst --> type }
  T Sub -> (if (and (cons? T) (= (hd T) (intern "tvar")))
               (let N (hd (tl T))
                 (let Binding (tc-assoc N Sub)
                   (if (tc-empty? Binding)
                       T
                       (tc-walk (hd (tl Binding)) Sub))))
               T))

\* ===== occurs?: check if a type variable appears in a type ===== *\

(define tc-occurs?
  { type --> type --> subst --> boolean }
  Tv T Sub -> (let W (tc-walk T Sub)
                (tc-occurs?-in Tv W Sub)))

(define tc-occurs?-in
  { type --> type --> subst --> boolean }
  Tv T Sub -> (let TvTag (tc-type-tag Tv)
                (if (= TvTag tvar)
                    (let N (tc-tvar-id Tv)
                      (let TTag (tc-type-tag T)
                        (if (= TTag tvar)
                            (= N (tc-tvar-id T))
                            (if (= TTag arrow)
                                (or (tc-occurs? Tv (tc-arrow-dom T) Sub)
                                    (tc-occurs? Tv (tc-arrow-cod T) Sub))
                                (if (= TTag app)
                                    (tc-occurs? Tv (tc-app-arg T) Sub)
                                    (if (= TTag prod)
                                        (or (tc-occurs? Tv (tc-prod-fst T) Sub)
                                            (tc-occurs? Tv (tc-prod-snd T) Sub))
                                        false))))))
                    false)))

\* ===== unify-var: bind a type variable, with occurs-check =====
   Prefer binding lower-id tvar when both are tvars. *\

(define tc-unify-var
  { type --> type --> subst --> result }
  V T Sub -> (let N (tc-tvar-id V)
               (let TTag (tc-type-tag T)
                 (if (= TTag tvar)
                     (let M (tc-tvar-id T)
                       (if (= N M)
                           [ok Sub]
                           (if (< N M)
                               (if (tc-occurs? V T Sub)
                                   [fail (cn "occurs check: tvar " (cn (str N) " in tvar " (str M)))]
                                   [ok [[N T] | Sub]])
                               (if (tc-occurs? T V Sub)
                                   [fail (cn "occurs check: tvar " (cn (str M) " in tvar " (str N)))]
                                   [ok [[M V] | Sub]]))))
                     (if (tc-occurs? V T Sub)
                         [fail (cn "occurs check: tvar " (cn (str N) " in type"))]
                         [ok [[N T] | Sub]])))))

\* ===== unify: the core unification algorithm =====
   Returns [ok Subst] or [fail Reason] — NEVER throws simple-error. *\

(define tc-unify
  { type --> type --> subst --> result }
  T1 T2 Sub -> (let W1 (tc-walk T1 Sub)
                 (let W2 (tc-walk T2 Sub)
                   (tc-unify-walked W1 W2 Sub))))

(define tc-unify-walked
  { type --> type --> subst --> result }
  W1 W2 Sub -> (let Tag1 (tc-type-tag W1)
                 (let Tag2 (tc-type-tag W2)
                   (if (= Tag1 tvar)
                       (tc-unify-var W1 W2 Sub)
                       (if (= Tag2 tvar)
                           (tc-unify-var W2 W1 Sub)
                           (if (= Tag1 con)
                               (if (= Tag2 con)
                                   (tc-unify-con W1 W2 Sub)
                                   [fail "type mismatch: con vs other"])
                               (if (= Tag1 arrow)
                                   (if (= Tag2 arrow)
                                       (tc-unify-arrow W1 W2 Sub)
                                       [fail "type mismatch: arrow vs other"])
                                   (if (= Tag1 app)
                                       (if (= Tag2 app)
                                           (tc-unify-app W1 W2 Sub)
                                           [fail "type mismatch: app vs other"])
                                       (if (= Tag1 prod)
                                           (if (= Tag2 prod)
                                               (tc-unify-prod W1 W2 Sub)
                                               [fail "type mismatch: prod vs other"])
                                           [fail (cn "type mismatch: " (cn (tc-type->str W1) (cn " vs " (tc-type->str W2))))])))))))))

\* ===== Structural tc-unify helpers ===== *\

(define tc-unify-con
  { type --> type --> subst --> result }
  C1 C2 Sub -> (let N1 (tc-con-name C1)
                 (let N2 (tc-con-name C2)
                   (if (= N1 N2)
                       [ok Sub]
                       \* klambda is the top type: "all data is valid klambda"
                          (Shen datatype klambda).  A value of any con type is
                          also a klambda, so unifying [con klambda] with any
                          other con succeeds with no binding.  This lets
                          structure patterns like [and X Y | Z] under a
                          { klambda --> klambda } sig type their keyword heads
                          and sub-vars against klambda. *\
                       (if (= N1 (intern "klambda"))
                           [ok Sub]
                           (if (= N2 (intern "klambda"))
                               [ok Sub]
                               [fail (cn "con mismatch: " (cn (str N1) (cn " vs " (str N2))))]))))))

(define tc-unify-arrow
  { type --> type --> subst --> result }
  A1 A2 Sub -> (let R1 (tc-unify (tc-arrow-dom A1) (tc-arrow-dom A2) Sub)
                 (if (tc-ok? R1)
                     (tc-unify (tc-arrow-cod A1) (tc-arrow-cod A2) (tc-ok-subst R1))
                     R1)))

(define tc-unify-app
  { type --> type --> subst --> result }
  A1 A2 Sub -> (if (= (tc-app-con A1) (tc-app-con A2))
                   (tc-unify (tc-app-arg A1) (tc-app-arg A2) Sub)
                   [fail (cn "app con mismatch: " (cn (str (tc-app-con A1)) (cn " vs " (str (tc-app-con A2)))))]))

(define tc-unify-prod
  { type --> type --> subst --> result }
  P1 P2 Sub -> (let R1 (tc-unify (tc-prod-fst P1) (tc-prod-fst P2) Sub)
                 (if (tc-ok? R1)
                     (tc-unify (tc-prod-snd P1) (tc-prod-snd P2) (tc-ok-subst R1))
                     R1)))

\* ===== Result helpers ===== *\

(define tc-ok?
  { result --> boolean }
  [ok _] -> true
  _ -> false)

(define tc-ok-subst
  { result --> subst }
  [ok Sub] -> Sub
  _ -> [])

(define tc-fail-reason
  { result --> string }
  [fail R] -> R
  _ -> "")

\* ===== apply-subst: apply a substitution to a type ===== *\

(define tc-apply-subst
  { subst --> type --> type }
  Sub T -> (let Tag (tc-type-tag T)
             (if (= Tag tvar)
                 (let Binding (tc-assoc (tc-tvar-id T) Sub)
                   (if (tc-empty? Binding)
                       T
                       (tc-apply-subst Sub (hd (tl Binding)))))
                 (if (= Tag con)
                     T
                     (if (= Tag arrow)
                         [arrow (tc-apply-subst Sub (tc-arrow-dom T))
                                (tc-apply-subst Sub (tc-arrow-cod T))]
                         (if (= Tag app)
                             [app (tc-app-con T) (tc-apply-subst Sub (tc-app-arg T))]
                             (if (= Tag prod)
                                 [prod (tc-apply-subst Sub (tc-prod-fst T))
                                       (tc-apply-subst Sub (tc-prod-snd T))]
                                 (if (= Tag forall)
                                     (let Vs (tc-forall-vars T)
                                       (let Filtered (tc-filter-subst Vs Sub)
                                         [forall Vs (tc-apply-subst Filtered (tc-forall-body T))]))
                                     T))))))))

\* ===== filter-subst: remove bindings for vars in Vs from Sub ===== *\

(define tc-filter-subst
  { (list number) --> subst --> subst }
  Vs [] -> []
  Vs [[N T] | Rest] -> (if (tc-element? N Vs)
                           (tc-filter-subst Vs Rest)
                           [[N T] | (tc-filter-subst Vs Rest)]))

\* ===== free-tvars: collect all free type variables in a type ===== *\

(define tc-free-tvars
  { type --> (list number) }
  T -> (let Tag (tc-type-tag T)
         (if (= Tag tvar)
             [(tc-tvar-id T)]
             (if (= Tag con)
                 []
                 (if (= Tag arrow)
                     (tc-union-nums (tc-free-tvars (tc-arrow-dom T))
                                    (tc-free-tvars (tc-arrow-cod T)))
                     (if (= Tag app)
                         (tc-free-tvars (tc-app-arg T))
                         (if (= Tag prod)
                             (tc-union-nums (tc-free-tvars (tc-prod-fst T))
                                            (tc-free-tvars (tc-prod-snd T)))
                             (if (= Tag forall)
                                 (tc-diff-nums (tc-free-tvars (tc-forall-body T))
                                               (tc-forall-vars T))
                                 []))))))))

\* ===== union-nums: set union of number lists ===== *\

(define tc-union-nums
  { (list number) --> (list number) --> (list number) }
  [] Ys -> Ys
  [X | Xs] Ys -> (if (tc-element? X Ys)
                     (tc-union-nums Xs Ys)
                     [X | (tc-union-nums Xs Ys)]))

\* ===== diff-nums: set difference (Xs - Ys) ===== *\

(define tc-diff-nums
  { (list number) --> (list number) --> (list number) }
  [] Ys -> []
  [X | Xs] Ys -> (if (tc-element? X Ys)
                     (tc-diff-nums Xs Ys)
                     [X | (tc-diff-nums Xs Ys)]))

\* ===== generalize: quantify free tvars not in ambient env ===== *\

(define tc-generalize
  { env --> type --> type }
  Env Type -> (let EnvFrees (tc-env-tvars Env)
                (let TypeFrees (tc-free-tvars Type)
                  (let GVars (tc-diff-nums TypeFrees EnvFrees)
                    (if (tc-empty? GVars)
                        Type
                        [forall GVars Type])))))

\* ===== env-tvars: collect all tvars appearing in env types ===== *\

(define tc-env-tvars
  { env --> (list number) }
  [] -> []
  [[_ Type] | Rest] -> (tc-union-nums (tc-free-tvars Type) (tc-env-tvars Rest))
  _ -> [])

\* ===== instantiate: replace forall-bound vars with fresh tvars ===== *\

(define tc-instantiate
  { type --> type }
  T -> (if (and (cons? T) (= (hd T) (intern "forall")))
           (let Vs (tc-forall-vars T)
             (let Subs (tc-fresh-subs-for Vs)
               (tc-apply-subst Subs (tc-forall-body T))))
           T))

(define tc-fresh-subs-for
  { (list number) --> subst }
  [] -> []
  [V | Vs] -> [[V (tc-fresh-tvar (intern ""))] | (tc-fresh-subs-for Vs)])

\* ===== type->str: human-readable type representation ===== *\

(define tc-type->str
  { type --> string }
  T -> (let Tag (tc-type-tag T)
         (if (= Tag tvar)
             (cn "t" (str (tc-tvar-id T)))
             (if (= Tag con)
                 (str (tc-con-name T))
                 (if (= Tag arrow)
                     (cn "(" (cn (tc-type->str (tc-arrow-dom T))
                                 (cn " -> " (cn (tc-type->str (tc-arrow-cod T)) ")"))))
                     (if (= Tag app)
                         (cn "(" (cn (str (tc-app-con T))
                                     (cn " " (cn (tc-type->str (tc-app-arg T)) ")"))))
                         (if (= Tag prod)
                             (cn "(" (cn (tc-type->str (tc-prod-fst T))
                                         (cn " * " (cn (tc-type->str (tc-prod-snd T)) ")"))))
                             (if (= Tag forall)
                                 (cn "forall[" (cn (tc-vars->str (tc-forall-vars T))
                                                   (cn "] " (tc-type->str (tc-forall-body T)))))
                                 "<?>"))))))))

(define tc-vars->str
  { (list number) --> string }
  [] -> ""
  [V] -> (str V)
  [V | Vs] -> (cn (str V) (cn " " (tc-vars->str Vs))))

(tc -)

\* tc-hm.shen — Stage 4: HM type checker integration.
   Loads all stages and provides tc-hm-file / tc-hm-all.
   Safe-subset only; mirrors shen-kl-helpers.shen style.
   Depends on: tc-hm-types, tc-hm-w, tc-hm-patterns, tc-hm-sig, tc-hm-prims. *\

(load "shen/tc-hm-types.shen")
(load "shen/tc-hm-w.shen")
(load "shen/tc-hm-prims.shen")
(load "shen/tc-hm-patterns.shen")
(load "shen/tc-hm-sig.shen")

\* ===== Global sigs table: sigs of defines we've already processed =====
   This is how recursive and cross-define calls are resolved.
   Populated incrementally as we check each define. *\

\* tc-global-sig-table initialized by tc-hm-init at runtime (bundle).
   Top-level (set ...) forms are skipped by shen-load; tc-hm-file also
   resets it per file. *\

\* ===== flatten-arrow-domains: extract arg types from a curried arrow =====
   (tc-flatten-arrow-domains [arrow A [arrow B C]]) → [[A B] C] *\

(define tc-flatten-arrow-domains
  { type --> (list (list type) type) }
  T -> (if (and (cons? T) (= (hd T) (intern "arrow")))
           (let D (hd (tl T))
             (let C (hd (tl (tl T)))
               (let Inner (tc-flatten-arrow-domains C)
                 [[D | (hd Inner)] | (tl Inner)])))
           [[] T]))

\* ===== sig-arg-types: get the list of argument types from a scheme ===== *\

(define tc-sig-arg-types
  { type --> (list type) }
  Sig -> (let Inst (tc-instantiate Sig)
           (hd (tc-flatten-arrow-domains Inst))))

\* ===== sig-ret-type: get the return type from a scheme ===== *\

(define tc-sig-ret-type
  { type --> type }
  Sig -> (let Inst (tc-instantiate Sig)
           (hd (tl (tc-flatten-arrow-domains Inst)))))

\* ===== sig-arity: number of arguments in a scheme ===== *\

(define tc-sig-arity
  { type --> number }
  Sig -> (tc-my-length (tc-sig-arg-types Sig)))

\* ===== my-length: local length (mirrors os-helpers style) ===== *\

(define tc-my-length
  { (list A) --> number }
  [] -> 0
  [_ | Rest] -> (+ 1 (tc-my-length Rest)))

\* ===== clause-arity: number of patterns in the FIRST clause =====
   Counts flat rule-list elements before the first -> / <- separator.
   The define's arity comes from the CLAUSE, not the sig: in Shen
   { A --> (B --> C) } and { A --> B --> C } are the SAME curried type,
   and a clause may consume fewer arrows than the sig provides, returning
   the remaining arrow as a higher-order result:
     (define adder { number --> (number --> number) } X -> (lambda Y (+ X Y)))
   Flattening the WHOLE sig (old tc-sig-arg-types) made this look like
   arity 2 while the clause has 1 pattern -> "malformed clause".
   Returns 0 when no arrow is found (malformed clause; callers fail). *\

(define tc-clause-arity
  { (list expr) --> number }
  Rules -> (tc-clause-arity-h Rules 0))

(define tc-clause-arity-h
  { (list expr) --> number --> number }
  [] _ -> 0
  [H | T] N -> (if (tc-rule-arrow? H) N (tc-clause-arity-h T (+ N 1))))

\* ===== arrow-count: how many curried arrows an instantiated sig has ===== *\

(define tc-arrow-count
  { type --> number }
  T -> (if (= (tc-type-tag T) arrow)
          (+ 1 (tc-arrow-count (tc-arrow-cod T)))
          0))

\* ===== take-domains: peel EXACTLY N domains off a curried arrow =====
   (tc-take-domains 1 [arrow A [arrow B C]]) → [[A] [arrow B C]]
   Unlike tc-flatten-arrow-domains this stops after N peels, so the
   "return type" may itself be an arrow (higher-order return).
   Caller MUST first check (<= N (tc-arrow-count T)). *\

(define tc-take-domains
  { number --> type --> (list (list type) type) }
  0 T -> [[] T]
  N T -> (let Inner (tc-take-domains (- N 1) (tc-arrow-cod T))
           [[(tc-arrow-dom T) | (hd Inner)] | (tl Inner)]))

\* ===== sig-for-arity: instantiate the sig ONCE and peel Arity arrows =====
   Single instantiation preserves arg/ret tvar sharing ({ A --> A } keeps
   both ends the SAME tvar).  Returns [ok [[ArgTypes] RetType]] or
   [fail Reason] when the clause needs more arrows than the sig has. *\

(define tc-hm-sig-for-arity
  { number --> type --> result }
  Arity Sig -> (let Inst (tc-instantiate Sig)
                 (let SigArrows (tc-arrow-count Inst)
                   (if (> Arity SigArrows)
                       [fail (cn "clause arity " (cn (str Arity)
                                                 (cn " exceeds sig arity " (str SigArrows))))]
                       [ok (tc-take-domains Arity Inst)]))))

\* ===== has-sig?: check if a define form has a type signature =====
   The sig is the element after the define name, surrounded by {...}. *\

(define tc-has-sig?
  { expr --> boolean }
  X -> (if (cons? X)
           (if (symbol? (hd X))
               (= (hd X) (intern "{"))
               false)
           false))

\* ===== extract-sig: get the sig form from a define =====
   Returns the sig (list with { and }) or [] if no sig. *\

(define tc-extract-sig
  { (list expr) --> expr }
  [] -> []
  [H | T] -> (if (tc-has-sig? H) H (tc-extract-sig T))
  _ -> [])

\* ===== extract-name: get the define name (second element) ===== *\

(define tc-extract-name
  { (list expr) --> symbol }
  [define Name | _] -> Name
  _ -> (intern ""))

\* ===== extract-rules: get the rule list after the sig =====
   Strips [define Name Sig | Rules] → Rules. *\

(define tc-extract-rules
  { (list expr) --> (list expr) }
  [define Name | Rest] -> (if (tc-has-sig? (hd Rest))
                              (tl Rest)
                              Rest)
  _ -> [])

\* ===== tc-hm-define: type-check a single define =====
   Name: the define name
   Sig: the parsed scheme (type)
   Rules: the flat rule list [Pat1 ... -> Body ...]
   Arity comes from the CLAUSE's pattern count (tc-clause-arity), not
   from flattening the sig — a higher-order return sig like
   { number --> (number --> number) } still has 1-pattern clauses.
   Returns [ok Name] or [fail (cn Name Reason)]. *\

(define tc-hm-define
  { symbol --> type --> (list expr) --> tc-result }
  Name Sig Rules ->
    (let Arity (tc-clause-arity Rules)
      (if (tc-clause-malformed? Rules Arity)
          [fail (cn (str Name) ": malformed clause (no -> or <- found)")]
          (let R (tc-hm-sig-for-arity Arity Sig)
            (if (tc-ok? R)
                (let Peeled (tc-ok-subst R)
                  (tc-hm-define-h Name Sig Rules Arity
                                  (hd Peeled) (hd (tl Peeled))))
                [fail (cn (str Name) (cn ": " (tc-fail-reason R)))])))))

\* tc-clause-malformed?: a clause is malformed iff it has NO arrow at all.
   tc-clause-arity returns 0 both for a valid nullary clause (the arrow is
   the FIRST element, arity 0) and for a clause with no arrow anywhere.
   Distinguish by checking whether the first element is an arrow: a nullary
   clause [-> Body ...] starts with one; a malformed clause does not. *\

(define tc-clause-malformed?
  { (list expr) --> number --> boolean }
  Rules Arity -> (if (cons? Rules)
                     (if (tc-rule-arrow? (hd Rules))
                         false
                         (= Arity 0))
                     true))

\* tc-hm-define-h: register the self-sig, check clauses, clean up.
   Same registration dance as before the arity fix: sig goes into
   tc-global-sig-table (kept — cross-define references) and briefly into
   tc-prim-table (popped after — W's tc-infer-var finds it during this
   define's own body check). *\

(define tc-hm-define-h
  { symbol --> type --> (list expr) --> number --> (list type) --> type --> tc-result }
  Name Sig Rules Arity ArgTypes RetType ->
    (do (%% set tc-global-sig-table [[Name Sig] | (%% value tc-global-sig-table)])
        (do (%% set tc-prim-table [[Name Sig] | (%% value tc-prim-table)])
            (let Result (tc-hm-clauses Name ArgTypes RetType Arity Rules [])
              (do (%% set tc-prim-table (tl (%% value tc-prim-table)))
                  Result)))))

\* ===== tc-hm-infer-define: infer a define's type when it has no sig =====
   Classic monomorphic-letrec HM for top-level definitions:
   1. Arity N from the FIRST clause's pattern count.
   2. N SHARED fresh arg tvars a1..aN + fresh ret tvar r;
      SelfType = a1 --> ... --> aN --> r (monomorphic).
   3. Pre-register Name -> SelfType into tc-prim-table so recursive
      self-calls resolve during body checking (standard HM letrec:
      self-reference is monomorphic; generalization happens once at the
      end).  Popped after checking, like the sig path.
   4. Each clause is typed against the SHARED a1..aN with ONE
      accumulating substitution; each body type unifies with r.  All
      clauses therefore must agree on a single type.
   5. FinalType = SelfType under the final substitution; the scheme is
      tc-generalize [] FinalType (ALL free tvars quantified — top-level,
      empty ambient env) and is stored into tc-global-sig-table so later
      defines (this file or later files) resolve it. *\

(define tc-hm-infer-define
  { symbol --> (list expr) --> tc-result }
  Name Rules ->
    (let Arity (tc-clause-arity Rules)
      (if (tc-clause-malformed? Rules Arity)
          [fail (cn (str Name) ": malformed clause (no -> or <- found)")]
          (tc-hm-infer-define-h Name Rules Arity (tc-fresh-tvars Arity)))))

(define tc-hm-infer-define-h
  { symbol --> (list expr) --> number --> (list type) --> tc-result }
  Name Rules Arity ArgTvars ->
    (let RetTvar (tc-fresh-tvar (intern ""))
      (let SelfType (tc-build-arrow ArgTvars RetTvar)
        (tc-hm-infer-define-h2 Name Rules SelfType ArgTvars RetTvar))))

(define tc-hm-infer-define-h2
  { symbol --> (list expr) --> type --> (list type) --> type --> tc-result }
  Name Rules SelfType ArgTvars RetTvar ->
    (do (%% set tc-prim-table [[Name SelfType] | (%% value tc-prim-table)])
        (let R (tc-hm-infer-clauses Name ArgTvars RetTvar Rules [])
          (do (%% set tc-prim-table (tl (%% value tc-prim-table)))
              (if (tc-ok? R)
                  (tc-hm-infer-finish Name SelfType (tc-ok-subst R))
                  R)))))

\* tc-hm-infer-finish: close the letrec — generalize and store. *\

(define tc-hm-infer-finish
  { symbol --> type --> subst --> tc-result }
  Name SelfType FinalSub ->
    (let FinalType (tc-apply-subst FinalSub SelfType)
      (let Scheme (tc-generalize [] FinalType)
        (do (%% set tc-global-sig-table [[Name Scheme] | (%% value tc-global-sig-table)])
            [ok Name]))))

\* ===== tc-fresh-tvars: a list of N fresh tvars ===== *\

(define tc-fresh-tvars
  { number --> (list type) }
  0 -> []
  N -> [(tc-fresh-tvar (intern "")) | (tc-fresh-tvars (- N 1))])

\* ===== tc-hm-infer-clauses: infer all clauses under shared tvars =====
   Loops with tc-hm-clause-remainder (same clause skipping as the sig
   path, incl. where-guards).  Every clause must have the SAME arity as
   the first (Shen requires this anyway); mismatch fails with a clear
   reason instead of a downstream "malformed clause". *\

(define tc-hm-infer-clauses
  { symbol --> (list type) --> type --> (list expr) --> subst --> result }
  Name ArgTvars RetTvar Rules Sub ->
    (if (= Rules [])
        [ok Sub]
        (let Arity (tc-my-length ArgTvars)
          (let NextArity (tc-clause-arity Rules)
            (if (= NextArity Arity)
                (let R (tc-hm-infer-one-clause Name ArgTvars RetTvar Rules Sub)
                  (if (tc-ok? R)
                      (tc-hm-infer-clauses Name ArgTvars RetTvar
                                           (tc-hm-clause-remainder Rules Arity)
                                           (tc-ok-subst R))
                      R))
                [fail (cn (str Name) (cn ": clause arity mismatch: expected "
                          (cn (str Arity) (cn " patterns, found "
                          (str NextArity)))))])))))

\* ===== tc-hm-infer-one-clause: type one clause against shared tvars =====
   Mirrors tc-hm-one-clause, but (a) patterns type against the shared
   ArgTvars rather than sig-arg-types, and (b) the accumulated Sub is
   returned to the caller instead of being discarded. *\

(define tc-hm-infer-one-clause
  { symbol --> (list type) --> type --> (list expr) --> subst --> result }
  Name ArgTvars RetTvar Rules Sub ->
    (let Arity (tc-my-length ArgTvars)
      (let Pats (tc-kl-take Arity Rules)
        (let AfterPats (tc-kl-drop Arity Rules)
          (if (and (cons? AfterPats) (tc-rule-arrow? (hd AfterPats)))
              (tc-hm-infer-one-clause-2 Name ArgTvars RetTvar Pats
                                        (hd (tl AfterPats))
                                        (tl (tl AfterPats))
                                        Sub)
              [fail (cn (str Name) ": malformed clause, expected -> or <-")])))))

(define tc-hm-infer-one-clause-2
  { symbol --> (list type) --> type --> (list expr) --> expr --> (list expr) --> subst --> result }
  Name ArgTvars RetTvar Pats Body AfterBody Sub ->
    (let PatResult (tc-type-patterns Pats ArgTvars Sub)
      (if (tc-ok? PatResult)
          (let Pair (tc-ok-subst-bindings PatResult)
            (let Sub2 (hd Pair)
              (let Binds (hd (tl Pair))
                (let PatEnv (tc-apply-subst-to-env Sub2 Binds)
                  (if (and (cons? AfterBody) (= (hd AfterBody) (intern "where")))
                      (if (cons? (tl AfterBody))
                          (tc-hm-infer-one-clause-guard Name PatEnv Body
                                                        (hd (tl AfterBody)) Sub2 RetTvar)
                          [fail (cn (str Name) ": where with no guard")])
                      (tc-hm-infer-one-clause-body Name PatEnv Body Sub2 RetTvar))))))
          [fail (cn (str Name) (cn ": pattern ["
                    (cn (str Pats) (cn "] typing failed: "
                    (tc-fail-reason PatResult)))))])))

\* tc-hm-infer-one-clause-body: infer the body, unify with the shared
   ret tvar, return the extended substitution. *\

(define tc-hm-infer-one-clause-body
  { symbol --> env --> expr --> subst --> type --> result }
  Name PatEnv Body Sub RetTvar ->
    (let R (tc-infer PatEnv Body Sub)
      (if (tc-ok? R)
          (let Pair (tc-ok-subst-type R)
            (let Sub2 (hd Pair)
              (let BodyType (hd (tl Pair))
                (let RU (tc-unify BodyType RetTvar Sub2)
                  (if (tc-ok? RU)
                      [ok (tc-ok-subst RU)]
                      [fail (cn (str Name) (cn ": body/ret mismatch: "
                                (tc-fail-reason RU)))])))))
          [fail (cn (str Name) (cn ": body infer failed BODY="
                    (cn (str Body) (cn " REASON=" (tc-fail-reason R)))))])))

\* tc-hm-infer-one-clause-guard: where-guard must be boolean; the body
   is then typed with the ORIGINAL Sub (mirrors the sig path). *\

(define tc-hm-infer-one-clause-guard
  { symbol --> env --> expr --> expr --> subst --> type --> result }
  Name PatEnv Body Guard Sub RetTvar ->
    (let RG (tc-infer PatEnv Guard Sub)
      (if (tc-ok? RG)
          (let PairG (tc-ok-subst-type RG)
            (let GuardType (hd (tl PairG))
              (let RU (tc-unify GuardType [con boolean] (hd PairG))
                (if (tc-ok? RU)
                    (tc-hm-infer-one-clause-body Name PatEnv Body Sub RetTvar)
                    [fail (cn (str Name) (cn ": guard not boolean: "
                              (tc-fail-reason RU)))]))))
          [fail (cn (str Name) (cn ": guard infer failed: "
                    (tc-fail-reason RG)))])))

\* ===== tc-hm-clauses: check all clauses of a define ===== *\

(define tc-hm-clauses
  { symbol --> (list type) --> type --> number --> (list expr) --> tc-result --> tc-result }
  Name ArgTypes RetType Arity [] Acc -> [ok Name]
  Name ArgTypes RetType Arity Rules Acc ->
    (let Result (tc-hm-one-clause Name ArgTypes RetType Arity Rules)
      (if (tc-ok? Result)
          (let Remaining (tc-hm-clause-remainder Rules Arity)
            (tc-hm-clauses Name ArgTypes RetType Arity Remaining Result))
          Result)))

\* ===== tc-rule-arrow?: true if X is -> or <- (clause separators) ===== *\

(define tc-rule-arrow?
  { expr --> boolean }
  X -> (if (= X (intern "->")) true
         (if (= X (intern "<-")) true false)))

\* ===== tc-hm-one-clause: check a single clause =====
   Given the flat rule list starting at a clause, type-check it.
   Returns [ok _] or [fail Reason]. *\

(define tc-hm-one-clause
  { symbol --> (list type) --> type --> number --> (list expr) --> tc-result }
  Name ArgTypes RetType Arity Rules ->
    (let Pats (tc-kl-take Arity Rules)
      (let AfterPats (tc-kl-drop Arity Rules)
        (if (and (cons? AfterPats) (tc-rule-arrow? (hd AfterPats)))
            (let Body (hd (tl AfterPats))
              (let AfterBody (tl (tl AfterPats))
                \* Type the patterns *\
                (let PatResult (tc-type-patterns Pats ArgTypes [])
                  (if (tc-ok? PatResult)
                      (let Pair (tc-ok-subst-bindings PatResult)
                        (let Sub (hd Pair)
                          (let Binds (hd (tl Pair))
                            \* Build env: pattern bindings + applied arg types *\
                            (let PatEnv (tc-apply-subst-to-env Sub Binds)
                              \* Check for where guard *\
                              (if (and (cons? AfterBody) (= (hd AfterBody) (intern "where")))
                                  (if (cons? (tl AfterBody))
                                      (tc-hm-one-clause-guard Name PatEnv Body (hd (tl AfterBody)) Sub RetType)
                                      [fail (cn (str Name) ": where with no guard")])
                                  (tc-hm-one-clause-body Name PatEnv Body Sub RetType))))))
                      [fail (cn (str Name) (cn ": pattern [" (cn (str Pats) (cn "] typing failed: " (tc-fail-reason PatResult)))))]))))
            [fail (cn (str Name) ": malformed clause, expected -> or <-")]))))

\* ===== tc-hm-one-clause-body: type-check the body of a single clause =====
   Shallow helper — infers body type, unifies with RetType. *\

(define tc-hm-one-clause-body
  { symbol --> env --> expr --> subst --> type --> tc-result }
  Name PatEnv Body Sub RetType ->
    (let R (tc-infer PatEnv Body Sub)
      (if (tc-ok? R)
          (let Pair2 (tc-ok-subst-type R)
            (let Sub2 (hd Pair2)
              (let BodyType (hd (tl Pair2))
                (let RetApplied (tc-apply-subst Sub2 RetType)
                  (let RU (tc-unify BodyType RetApplied Sub2)
                    (if (tc-ok? RU)
                        [ok Name]
                        [fail (cn (str Name) (cn ": body/ret mismatch: " (tc-fail-reason RU)))]))))))
          [fail (cn (str Name) (cn ": body infer failed BODY=" (cn (str Body) (cn " REASON=" (tc-fail-reason R)))))])))

\* ===== tc-hm-one-clause-guard: type-check a where guard, then the body =====
   Types the guard as boolean (discards its subst for body typing). *\

(define tc-hm-one-clause-guard
  { symbol --> env --> expr --> expr --> subst --> type --> tc-result }
  Name PatEnv Body Guard Sub RetType ->
    (let RG (tc-infer PatEnv Guard Sub)
      (if (tc-ok? RG)
          (let PairG (tc-ok-subst-type RG)
            (let GuardType (hd (tl PairG))
              (let RU (tc-unify GuardType [con boolean] (hd PairG))
                (if (tc-ok? RU)
                    \* Guard OK — type body with ORIGINAL Sub *\
                    (tc-hm-one-clause-body Name PatEnv Body Sub RetType)
                    [fail (cn (str Name) (cn ": guard not boolean: " (tc-fail-reason RU)))]))))
          [fail (cn (str Name) (cn ": guard infer failed: " (tc-fail-reason RG)))])))

\* ===== type-patterns: type a list of patterns against arg types ===== *\

(define tc-type-patterns
  { (list expr) --> (list type) --> subst --> pat-result }
  [] [] Sub -> [ok [Sub []]]
  [Pat | PRest] [Type | TRest] Sub ->
    (let R (tc-type-pattern Pat Type Sub)
      (if (tc-ok? R)
          (let Pair (tc-ok-subst-bindings R)
            (let Sub2 (hd Pair)
              (let Binds (hd (tl Pair))
                (let R2 (tc-type-patterns PRest TRest Sub2)
                  (if (tc-ok? R2)
                      (let Pair2 (tc-ok-subst-bindings R2)
                        (let Sub3 (hd Pair2)
                          (let Binds2 (hd (tl Pair2))
                            [ok [Sub3 (tc-append Binds Binds2)]])))
                      R2)))))
          R))
  _ _ _ -> [fail "type-patterns: arity mismatch"])

\* ===== apply-subst-to-env: apply substitution to all types in an env ===== *\

(define tc-apply-subst-to-env
  { subst --> env --> env }
  Sub [] -> []
  Sub [[Name Type] | Rest] -> [[Name (tc-apply-subst Sub Type)] | (tc-apply-subst-to-env Sub Rest)]
  Sub _ -> [])

\* ===== tc-hm-clause-remainder: skip past one clause to the next =====
   Rules = [Pat1..PatN -> Body (where Guard)? Remaining...]
   Skip Arity patterns + arrow + Body + optional where Guard, return Remaining. *\

(define tc-hm-clause-remainder
  { (list expr) --> number --> (list expr) }
  Rules Arity -> (let AfterPats (tc-kl-drop Arity Rules)
                   (if (and (cons? AfterPats) (tc-rule-arrow? (hd AfterPats)))
                       (if (cons? (tl AfterPats))
                           (let AfterBody (tl (tl AfterPats))
                             (if (and (cons? AfterBody) (= (hd AfterBody) (intern "where")))
                                 (if (cons? (tl AfterBody))
                                     (tl (tl AfterBody))
                                     [])
                                 AfterBody))
                           [])
                       [])))

\* ===== tc-kl-take / kl-drop: list helpers (mirrors shen-kl-helpers) ===== *\

(define tc-kl-take
  { number --> (list A) --> (list A) }
  0 _ -> []
  N [H | Rest] -> [H | (tc-kl-take (- N 1) Rest)]
  N [] -> [])

(define tc-kl-drop
  { number --> (list A) --> (list A) }
  0 L -> L
  N [_ | Rest] -> (tc-kl-drop (- N 1) Rest)
  N [] -> [])

\* ===== tc-hm-file: type-check all defines in a source file =====
   Reads the file using shen-read-file, finds all define forms,
   parses their sigs, and checks each one.
   Returns a list of [ok Name] or [fail Reason] per define. *\

(define tc-hm-file
  { string --> (list tc-result) }
  Path -> (let Forms (shen-read-file Path)
            (tc-hm-forms Forms)))

(define tc-hm-forms
  { (list expr) --> (list tc-result) }
  Forms -> (do (tc-hm-collect-sigs Forms)
               (tc-hm-forms-check Forms)))

\* ===== tc-hm-collect-sigs: pre-pass over all define forms, populating
   tc-global-sig-table with every [Name Sig] so forward/cross references
   between defines in the same file are visible during body checking.
   (Do not clear tc-global-sig-table here — cross-file sigs accumulate.) *\

(define tc-hm-collect-sigs
  { (list expr) --> (list symbol) }
  [] -> []
  [F | Rest] -> (if (tc-hm-define-form? F)
                     (let Name (tc-extract-name F)
                       (let SigForm (tc-extract-sig (tl (tl F)))
                         (if (cons? SigForm)
                             (let ParsedSig (tc-parse-sig SigForm)
                               (do (%% set tc-global-sig-table [[Name ParsedSig] | (%% value tc-global-sig-table)])
                                   (tc-hm-collect-sigs Rest)))
                             (tc-hm-collect-sigs Rest))))
                     (tc-hm-collect-sigs Rest)))

\* ===== tc-hm-forms-check: the actual per-define check pass ===== *\

(define tc-hm-forms-check
  { (list expr) --> (list tc-result) }
  [] -> []
  [F | Rest] -> (if (tc-hm-define-form? F)
                     (let Result (tc-hm-one-form F)
                       [Result | (tc-hm-forms-check Rest)])
                     (tc-hm-forms-check Rest)))

(define tc-hm-define-form?
  { expr --> boolean }
  X -> (if (cons? X)
           (if (symbol? (hd X))
               (= (hd X) (intern "define"))
               false)
           false))

\* ===== tc-hm-one-form: check ONE define form =====
   Sig present  → tc-hm-define (sig-anchored check).
   Sig absent   → tc-hm-infer-define (infer + generalize + store the
                  scheme).  This replaces the old "no type signature,
                  skipping" fail: a missing sig now still gets the body
                  CHECKED (trust boundary for shen-load) instead of
                  aborting the load. *\

(define tc-hm-one-form
  { expr --> tc-result }
  Form -> (let Name (tc-extract-name Form)
            (let SigForm (tc-extract-sig (tl (tl Form)))
              (let Rules (tc-extract-rules Form)
                (if (cons? SigForm)
                    (let ParsedSig (tc-parse-sig SigForm)
                      (tc-hm-define Name ParsedSig Rules))
                    (tc-hm-infer-define Name Rules))))))

\* ===== tc-hm-all: type-check all Group A files ===== *\

(define tc-hm-all
  { --> (list (list string (list tc-result))) }
  -> (do (tc-hm-init)
         (let Files [\* Group A: 6 files with sigs *\
                    "shen/types.shen"
                    "shen/util.shen"
                    "shen/zinc.shen"
                    "shen/compile.shen"
                    "shen/normalize.shen"
                    "shen/interp.shen"]
           (tc-hm-files Files))))

(define tc-hm-files
  { (list string) --> (list (list string (list tc-result))) }
  [] -> []
  [F | Rest] -> [[F (tc-hm-file F)] | (tc-hm-files Rest)])

\* ===== Result formatting ===== *\

(define print-tc-result
  { tc-result --> string }
  [ok Name] -> (cn "OK: " (str Name))
  [fail Reason] -> (cn "FAIL: " Reason)
  X -> (cn "UNKNOWN: " (str X)))

(define print-tc-results
  { (list tc-result) --> string }
  [] -> ""
  [R] -> (cn (print-tc-result R) (n->string 10))
  [R | Rest] -> (cn (print-tc-result R) (cn (n->string 10) (print-tc-results Rest))))

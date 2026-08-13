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
   Returns [ok Name] or [fail (cn Name Reason)]. *\

(define tc-hm-define
  { symbol --> type --> (list expr) --> tc-result }
  Name Sig Rules ->
    (let ArgTypes (tc-sig-arg-types Sig)
      (let RetType (tc-sig-ret-type Sig)
        (let Arity (tc-my-length ArgTypes)
          \* Add self-sig to global table for recursive calls *\
          (do (%% set tc-global-sig-table [[Name Sig] | (%% value tc-global-sig-table)])
              \* Also register in tc-prim-table so W's tc-infer-var finds it *\
              (do (%% set tc-prim-table [[Name Sig] | (%% value tc-prim-table)])
                  (let Result (tc-hm-clauses Name ArgTypes RetType Arity Rules [])
                    \* Clean up: remove self from tables *\
                    (do (%% set tc-prim-table (tl (%% value tc-prim-table)))
                        Result))))))))

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

(define tc-hm-one-form
  { expr --> tc-result }
  Form -> (let Name (tc-extract-name Form)
            (let SigForm (tc-extract-sig (tl (tl Form)))
              (if (cons? SigForm)
                  (let ParsedSig (tc-parse-sig SigForm)
                    (let Rules (tc-extract-rules Form)
                      (tc-hm-define Name ParsedSig Rules)))
                  [fail (cn (str Name) ": no type signature, skipping")]))))

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

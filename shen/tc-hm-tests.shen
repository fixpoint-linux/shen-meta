(tc -)

\* tc-hm-tests.shen — synthetic test cases for the HM type checker.
   Bundled by serialize-reduced.shen and driven by run-tc-hm-tests
   (tc-hm-runtime.shen) via the C VM --tc-hm-tests flag.  The runner
   tc-hm-tests-run-all returns a summary string (print is not a C primitive
   in the reduced bundle).  Tests cover: unification, Algorithm W, pattern
   typing, sig parsing. *\

\* Load components directly to avoid shen-read-file dependency in tc-hm.shen *\
(load "shen/tc-hm-types.shen")
(load "shen/tc-hm-w.shen")
(load "shen/tc-hm-prims.shen")
(load "shen/tc-hm-patterns.shen")
(load "shen/tc-hm-sig.shen")
\* Stage 6 tests exercise tc-hm-define / tc-hm-infer-define (define level) *\
(load "shen/tc-hm.shen")

\* ===== Test infrastructure ===== *\

(set test-passed 0)
(set test-failed 0)

(define tc-assert-ok
  { string --> result --> (list symbol) }
  Label [ok _] -> (do (%% set test-passed (+ (%% value test-passed) 1))
                      [])
  Label [fail Reason] -> (do (%% set test-failed (+ (%% value test-failed) 1))
                              (%% set test-failures (cons (cn "FAIL " (cn Label (cn ": " Reason))) (%% value test-failures)))
                              [])
  Label X -> (do (%% set test-failed (+ (%% value test-failed) 1))
                 (%% set test-failures (cons (cn "FAIL " (cn Label ": unexpected result")) (%% value test-failures)))
                 []))

(define tc-assert-fail
  { string --> result --> (list symbol) }
  Label [fail _] -> (do (%% set test-passed (+ (%% value test-passed) 1))
                        [])
  Label [ok _] -> (do (%% set test-failed (+ (%% value test-failed) 1))
                      (%% set test-failures (cons (cn "FAIL " (cn Label ": expected fail, got ok")) (%% value test-failures)))
                      [])
  Label X -> (do (%% set test-failed (+ (%% value test-failed) 1))
                 (%% set test-failures (cons (cn "FAIL " (cn Label ": unexpected result")) (%% value test-failures)))
                 []))

(define tc-assert-equal
  { string --> A --> A --> (list symbol) }
  Label Expected Actual ->
    (if (= Expected Actual)
        (do (%% set test-passed (+ (%% value test-passed) 1))
            [])
        (do (%% set test-failed (+ (%% value test-failed) 1))
            (%% set test-failures (cons (cn "FAIL " (cn Label (cn ": expected " (cn (str Expected) (cn " got " (str Actual)))))) (%% value test-failures)))
            [])))

\* ================================================================
   STAGE 1 TESTS — Unification
   ================================================================ *\

(define test-unify-1-equal-numbers
  { --> (list symbol) }
  -> (tc-assert-ok "unify: number=number"
       (tc-unify [con number] [con number] [])))

(define test-unify-2-number-vs-string
  { --> (list symbol) }
  -> (tc-assert-fail "unify: number vs string"
       (tc-unify [con number] [con string] [])))

(define test-unify-3-tvar-binds-to-con
  { --> (list symbol) }
  -> (tc-assert-ok "unify: tvar=number"
       (tc-unify [tvar 0] [con number] [])))

(define test-unify-4-tvar-binds-to-arrow
  { --> (list symbol) }
  -> (tc-assert-ok "unify: tvar=arrow"
       (tc-unify [tvar 0] [arrow [con number] [con number]] [])))

(define test-unify-5-occurs-check-fires
  { --> (list symbol) }
  -> (tc-assert-fail "unify: occurs check tvar=arrow(tvar)"
       (tc-unify [tvar 0] [arrow [tvar 0] [con number]] [])))

(define test-unify-6-two-tvars-equal
  { --> (list symbol) }
  -> (tc-assert-ok "unify: tvar0=tvar0 (same)"
       (tc-unify [tvar 0] [tvar 0] [])))

(define test-unify-7-two-tvars-different
  { --> (list symbol) }
  -> (tc-assert-ok "unify: tvar0=tvar1"
       (tc-unify [tvar 0] [tvar 1] [])))

(define test-unify-8-arrow-structural
  { --> (list symbol) }
  -> (tc-assert-ok "unify: arrow(number,number)=arrow(number,number)"
       (tc-unify [arrow [con number] [con number]]
              [arrow [con number] [con number]] [])))

(define test-unify-9-arrow-mismatch
  { --> (list symbol) }
  -> (tc-assert-fail "unify: arrow vs con"
       (tc-unify [arrow [con number] [con number]] [con number] [])))

(define test-unify-10-polymorphic-arrow
  { --> (list symbol) }
  -> (tc-assert-ok "unify: arrow(tvar0,number)=arrow(number,number)"
       (tc-unify [arrow [tvar 0] [con number]]
              [arrow [con number] [con number]] [])))

(define test-unify-11-app-types
  { --> (list symbol) }
  -> (tc-assert-ok "unify: (list t0)=(list number)"
       (tc-unify [app list [tvar 0]] [app list [con number]] [])))

(define test-unify-12-app-mismatch-con
  { --> (list symbol) }
  -> (tc-assert-fail "unify: (list number) vs (vector number)"
       (tc-unify [app list [con number]] [app vector [con number]] [])))

(define test-unify-13-prod-types
  { --> (list symbol) }
  -> (tc-assert-ok "unify: prod(number,string)=prod(number,string)"
       (tc-unify [prod [con number] [con string]]
              [prod [con number] [con string]] [])))

(define test-unify-14-deep-arrow
  { --> (list symbol) }
  -> (tc-assert-ok "unify: deep arrow with tvar"
       (tc-unify [arrow [con number] [arrow [tvar 0] [con boolean]]]
              [arrow [con number] [arrow [con string] [con boolean]]] [])))

(define test-unify-15-walk-follows-chain
  { --> (list symbol) }
  -> (let Sub [[0 [tvar 1]] | [[1 [con number]] | []]]
       (tc-assert-ok "unify: walk through chain"
         (tc-unify [tvar 0] [con number] Sub))))

(define test-unify-16-apply-subst
  { --> (list symbol) }
  -> (let Sub [[0 [con number]]]
       (tc-assert-equal "apply-subst: tvar->con"
         [arrow [con number] [con number]]
         (tc-apply-subst Sub [arrow [tvar 0] [con number]]))))

(define test-unify-17-free-tvars
  { --> (list symbol) }
  -> (tc-assert-equal "free-tvars: arrow(t0,t1)"
         [0 1]
         (tc-sort-nums (tc-free-tvars [arrow [tvar 0] [tvar 1]]))))

(define test-unify-18-instantiate-forall
  { --> (list symbol) }
  -> (let Scheme [forall [0] [arrow [tvar 0] [tvar 0]]]
       (let Inst (tc-instantiate Scheme)
         \* Should have fresh tvars replacing 0 *\
         (let Tag (tc-type-tag Inst)
           (tc-assert-equal "instantiate: forall becomes arrow"
             arrow Tag)))))

(define test-unify-19-generalize
  { --> (list symbol) }
  -> (let Type [arrow [tvar 0] [tvar 0]]
       (let Gen (tc-generalize [] Type)
         (tc-assert-equal "generalize: free tvar becomes forall"
           forall (tc-type-tag Gen)))))

(define test-unify-20-occurs-check-deep
  { --> (list symbol) }
  -> (tc-assert-fail "unify: occurs check tvar0 in arrow(tvar1,arrow(tvar0,bool))"
       (tc-unify [tvar 0] [arrow [tvar 1] [arrow [tvar 0] [con boolean]]] [])))

\* ================================================================
   STAGE 2 TESTS — Algorithm W on expressions
   ================================================================ *\

(define test-w-1-lambda-id
  { --> (list symbol) }
  -> (let R (tc-infer [] [lambda X X] [])
       (if (tc-ok? R)
           (let Type (hd (tl (tc-ok-subst-type R)))
             (tc-assert-equal "W: lambda x.x is arrow"
               arrow (tc-type-tag Type)))
           (tc-assert-ok "W: lambda x.x" R))))

(define test-w-2-number-lit
  { --> (list symbol) }
  -> (let R (tc-infer [] 42 [])
       (if (tc-ok? R)
           (let Type (hd (tl (tc-ok-subst-type R)))
             (tc-assert-equal "W: 42 is number"
               [con number] (tc-apply-subst (hd (tc-ok-subst-type R)) Type)))
           (tc-assert-ok "W: 42 literal" R))))

(define test-w-3-string-lit
  { --> (list symbol) }
  -> (let R (tc-infer [] "hello" [])
       (if (tc-ok? R)
           (tc-assert-ok "W: string literal" [ok []])
           (tc-assert-ok "W: string literal" R))))

(define test-w-4-empty-list
  { --> (list symbol) }
  -> (let R (tc-infer [] [] [])
       (if (tc-ok? R)
           (let Type (hd (tl (tc-ok-subst-type R)))
             (tc-assert-equal "W: [] infers to a fresh tvar"
               tvar (tc-type-tag Type)))
           (tc-assert-ok "W: empty list" R))))

(define test-w-5-let-id
  { --> (list symbol) }
  -> (let R (tc-infer [] [let id 42 id] [])
       (if (tc-ok? R)
           (let Type (hd (tl (tc-ok-subst-type R)))
             (let Final (tc-apply-subst (hd (tc-ok-subst-type R)) Type)
               (tc-assert-equal "W: let id = 42 in id is number"
                 [con number] Final)))
           (tc-assert-ok "W: let id" R))))

(define test-w-6-plus-numbers-ok
  { --> (list symbol) }
  -> (tc-assert-ok "W: (+ 1 2) ok"
       (tc-infer [] [+ 1 2] [])))

(define test-w-7-plus-string-fails
  { --> (list symbol) }
  -> (tc-assert-fail "W: (+ 1 x) fails"
       (tc-infer [] [+ 1 "x"] [])))

(define test-w-8-if-bool
  { --> (list symbol) }
  -> (tc-assert-ok "W: (if true 1 2)"
       (tc-infer [] [if true 1 2] [])))

(define test-w-9-if-nonbool-condition
  { --> (list symbol) }
  -> (tc-assert-fail "W: (if 1 2 3) fails"
       (tc-infer [] [if 1 2 3] [])))

(define test-w-10-and-bool
  { --> (list symbol) }
  -> (tc-assert-ok "W: (and true false)"
       (tc-infer [] [and true false] [])))

(define test-w-11-cons-data
  { --> (list symbol) }
  -> (tc-assert-ok "W: [cons 1 []]"
       (tc-infer [] [cons 1 []] [])))

\* ================================================================
   STAGE 2b TESTS — Guard-driven type refinement
   (if (cons? X) ...) narrows X in the then-branch.
   ================================================================ *\

\* (cons? X) narrows X from opaque [con type] to [app list fresh] in
   the then-branch, so (hd X) type-checks against hd's (list a) domain.
   Without refinement this fails: [con type] vs [app list fresh]. *\

(define test-w-12-cons-narrows-then
  { --> (list symbol) }
  -> (let R (tc-infer [[X [con type]]]
                      [if [cons? X] [hd X] 0]
                      [])
       (tc-assert-ok "W: (if (cons? X) (hd X) 0) narrows X in then" R)))

\* (symbol? X) narrows X to [con symbol] in the then-branch, so a
   symbol-expecting primitive (value) accepts it.  Without refinement
   this fails: [con type] vs [con symbol] at (value X). *\

(define test-w-13-symbol-narrows-then
  { --> (list symbol) }
  -> (let R (tc-infer [[X [con type]]]
                      [if [symbol? X] [value X] 0]
                      [])
       (tc-assert-ok "W: (if (symbol? X) (value X) 0) narrows X" R)))

\* Soundness: the else-branch is NOT refined.  X keeps its declared
   [con string] type (NOT a top rep-name), so (+ X 1) fails (number
   expected).  This guards against an unsound refinement that would
   leak into the else-branch. *\

(define test-w-14-no-refine-in-else
  { --> (list symbol) }
  -> (tc-assert-fail "W: else branch not refined (no leak)"
       (tc-infer [[X [con string]]]
                 [if [number? X] 0 [+ X 1]]
                 [])))

\* and-chain: (and (cons? X) (= (hd X) 5)) refines X before typing the
   second operand, so (hd X) inside the = type-checks.  Without the
   bool-op refinement this fails inside the and's second argument. *\

(define test-w-15-and-chain-refines
  { --> (list symbol) }
  -> (let R (tc-infer [[X [con type]]]
                      [if [and [cons? X] [= [hd X] 5]] 1 0]
                      [])
       (tc-assert-ok "W: (and (cons? X) (= (hd X) 5)) refines X" R)))

\* ================================================================
   STAGE 3 TESTS — Pattern typing
   ================================================================ *\

(define test-pat-1-wildcard
  { --> (list symbol) }
  -> (tc-assert-ok "pat: _ : number"
       (tc-type-pattern (intern "_") [con number] [])))

(define test-pat-2-variable
  { --> (list symbol) }
  -> (let R (tc-type-pattern (intern "X") [con number] [])
       (if (tc-ok? R)
           (let Binds (hd (tl (tc-ok-subst-bindings R)))
             (if (empty? Binds)
                 (tc-assert-fail "pat: X should produce binding" [fail "empty"])
                 (tc-assert-ok "pat: X : number" [ok []])))
           R)))

(define test-pat-3-empty-list
  { --> (list symbol) }
  -> (tc-assert-ok "pat: [] : (list number)"
       (tc-type-pattern [] [app list [con number]] [])))

(define test-pat-4-cons-pattern
  { --> (list symbol) }
  -> (tc-assert-ok "pat: [cons X Y] : zinc-value"
       (tc-type-pattern [cons (intern "X") (intern "Y")] [con zinc-value] [])))

(define test-pat-5-number-tag
  { --> (list symbol) }
  -> (tc-assert-ok "pat: [number X] : zinc-value"
       (tc-type-pattern [number (intern "X")] [con zinc-value] [])))

\* ================================================================
   STAGE 4 TESTS — Sig parsing + integration
   ================================================================ *\

(define test-sig-1-simple-arrow
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") number --> number (intern "}")])
       (tc-assert-equal "sig: {number --> number}"
         arrow (tc-type-tag Parsed))))

(define test-sig-2-polymorphic
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") A --> A (intern "}")])
       (tc-assert-equal "sig: {A --> A} is forall"
         forall (tc-type-tag Parsed))))

(define test-sig-3-multi-arg
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") A --> [list A] --> number (intern "}")])
       (tc-assert-equal "sig: {A --> (list A) --> number} is forall"
         forall (tc-type-tag Parsed))))

(define test-sig-4-no-type-vars
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") --> symbol (intern "}")])
       (tc-assert-equal "sig: {--> symbol} parses to symbol (nullary)"
         symbol (tc-con-name Parsed))))

\* ================================================================
   STAGE 5 TESTS — Root-cause-D fix: opaque rep-name top-type,
   opaque-ground extension, and fresh-tvar fallback in tc-prim-lookup.
   These pin the soundness-critical 8-name set the unification core
   and pattern-typing core both consume.  A drift here reintroduces
   the 66-FAIL baseline regressions.
   ================================================================ *\

\* tc-top-type? MUST be true for each of the 8 rep names — they are
   the checker's opaque internal reps and must unify with any
   structural form (analogous to klambda top).  One test per name so
   a future set drift is visible. *\

(define test-top-rep-1-type
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con type] is top"
     true (tc-top-type? [con (intern "type")])))

(define test-top-rep-2-expr
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con expr] is top"
     true (tc-top-type? [con (intern "expr")])))

(define test-top-rep-3-subst
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con subst] is top"
     true (tc-top-type? [con (intern "subst")])))

(define test-top-rep-4-env
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con env] is top"
     true (tc-top-type? [con (intern "env")])))

(define test-top-rep-5-result
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con result] is top"
     true (tc-top-type? [con (intern "result")])))

(define test-top-rep-6-infer-result
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con infer-result] is top"
     true (tc-top-type? [con (intern "infer-result")])))

(define test-top-rep-7-pat-result
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con pat-result] is top"
     true (tc-top-type? [con (intern "pat-result")])))

(define test-top-rep-8-tc-result
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con tc-result] is top"
     true (tc-top-type? [con (intern "tc-result")])))

\* Negative: zinc-value MUST NOT be top (Stage-5 vacuation warning:
   making zinc-value top would vacate the checker). *\

(define test-top-rep-9-zinc-value-not-top
  { --> (list symbol) }
  -> (tc-assert-equal "top: [con zinc-value] is NOT top (opaque-ground only)"
     false (tc-top-type? [con (intern "zinc-value")])))

\* tc-opaque-ground? MUST be true for each rep name — this routes
   [ok X]/[fail X] cons patterns typed against [con result] /
   [con tc-result] to opaque-cons (vars bind to fresh tvars). *\

(define test-opaque-rep-1-type
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con type] is opaque-ground"
     true (tc-opaque-ground? [con (intern "type")] [])))

(define test-opaque-rep-2-expr
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con expr] is opaque-ground"
     true (tc-opaque-ground? [con (intern "expr")] [])))

(define test-opaque-rep-3-subst
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con subst] is opaque-ground"
     true (tc-opaque-ground? [con (intern "subst")] [])))

(define test-opaque-rep-4-env
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con env] is opaque-ground"
     true (tc-opaque-ground? [con (intern "env")] [])))

(define test-opaque-rep-5-result
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con result] is opaque-ground"
     true (tc-opaque-ground? [con (intern "result")] [])))

(define test-opaque-rep-6-infer-result
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con infer-result] is opaque-ground"
     true (tc-opaque-ground? [con (intern "infer-result")] [])))

(define test-opaque-rep-7-pat-result
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con pat-result] is opaque-ground"
     true (tc-opaque-ground? [con (intern "pat-result")] [])))

(define test-opaque-rep-8-tc-result
  { --> (list symbol) }
  -> (tc-assert-equal "opaque-ground: [con tc-result] is opaque-ground"
     true (tc-opaque-ground? [con (intern "tc-result")] [])))

\* tc-prim-lookup on an unknown symbol MUST return a tvar, not an
   arrow.  The prior binary arrow was an arbitrary arity-2
   assumption that produced false rejects on non-2-arg calls. *\

(define test-prim-lookup-unknown-tvar
  { --> (list symbol) }
  -> (tc-assert-equal "prim-lookup: unknown symbol returns tvar (not arrow)"
     tvar (tc-type-tag (tc-prim-lookup (intern "tc-unknown-prim-xyzzy")))))

\* A 1-arg call to an unknown function MUST infer to a tvar (the
   fresh-tvar fallback unifies with the demanded arrow, leaving the
   return type as a fresh tvar).  The binary arrow would have
   required exactly 2 args. *\

(define test-infer-app-unknown-1arg-tvar
  { --> (list symbol) }
  -> (let R (tc-infer [] [(intern "tc-unknown-prim-xyzzy") 5] [])
       (if (tc-ok? R)
           (let Pair (tc-ok-subst-type R)
             (let Type (hd (tl Pair))
               (tc-assert-equal "infer: 1-arg call to unknown infers to tvar"
                 tvar (tc-type-tag Type))))
           (tc-assert-ok "infer: 1-arg call to unknown should succeed" R))))

\* ================================================================
   STAGE 6 TESTS — define-level checking: higher-order return sigs
   (arity-from-clause fix) and top-level inference of sig-less defines.
   NB: tests run in ORDER inside tc-hm-tests-run-all; the cross-use and
   scheme-stored tests depend on earlier inference tests having run
   (inference registers schemes into tc-global-sig-table as a side effect).
   ================================================================ *\
\* GOAL A — higher-order return sigs (arity from the clause, not the sig) *\

(define test-define-1-ho-ret-sig
  { --> (list symbol) }
  -> (tc-assert-ok "define: {number --> (number --> number)} X -> (lambda Y (+ X Y))"
       (tc-hm-define (intern "tst-adder")
         (tc-parse-sig [(intern "{") number --> number --> number (intern "}")])
         [(intern "X") (intern "->")
          [lambda (intern "Y") [(intern "+") (intern "X") (intern "Y")]]])))

(define test-define-2-ho-ret-body-mismatch
  { --> (list symbol) }
  -> (tc-assert-fail "define: ho return sig rejects non-function body"
       (tc-hm-define (intern "tst-adder-bad")
         (tc-parse-sig [(intern "{") number --> number --> number (intern "}")])
         [(intern "X") (intern "->") [(intern "+") (intern "X") 1]])))

(define test-define-3-arity-exceeds-sig
  { --> (list symbol) }
  -> (tc-assert-fail "define: clause arity exceeding sig arrows fails cleanly"
       (tc-hm-define (intern "tst-arity")
         (tc-parse-sig [(intern "{") number --> number (intern "}")])
         [(intern "X") (intern "Y") (intern "->") (intern "X")])))

(define test-define-4-nested-app-ret
  { --> (list symbol) }
  -> (tc-assert-ok "define: {A --> (list A)} nested non-arrow ret still checks"
       (tc-hm-define (intern "tst-wrap")
         (tc-parse-sig [(intern "{") A --> [list A] (intern "}")])
         [(intern "X") (intern "->") [cons (intern "X") []]])))

\* GOAL B — top-level inference for sig-less defines *\

(define test-infer-1-id-infers
  { --> (list symbol) }
  -> (tc-assert-ok "infer: sigless X -> X infers"
       (tc-hm-infer-define (intern "tst-id")
                           [(intern "X") (intern "->") (intern "X")])))

(define test-infer-2-id-scheme-stored
  { --> (list symbol) }
  -> (let Pair (tc-assoc (intern "tst-id") (%% value tc-global-sig-table))
       (tc-assert-equal "infer: X -> X stored as polymorphic forall scheme"
         forall (tc-type-tag (hd (tl Pair))))))

(define test-infer-3-num-body
  { --> (list symbol) }
  -> (tc-assert-ok "infer: X -> (+ X 1) infers number->number"
       (tc-hm-infer-define (intern "tst-inc")
         [(intern "X") (intern "->") [(intern "+") (intern "X") 1]])))

(define test-infer-4-bad-body-fails
  { --> (list symbol) }
  -> (tc-assert-fail "infer: ill-typed sigless body fails"
       (tc-hm-infer-define (intern "tst-bad")
         [(intern "X") (intern "->") [(intern "+") (intern "X") "s"]])))

(define test-infer-5-recursive-fact
  { --> (list symbol) }
  -> (tc-assert-ok "infer: recursive sigless factorial infers"
       (tc-hm-infer-define (intern "tst-fact")
         [(intern "N") (intern "->")
          [if [(intern "=") (intern "N") 0] 1
              [(intern "*") (intern "N")
               [(intern "tst-fact") [(intern "-") (intern "N") 1]]]]])))

(define test-infer-6-fact-mono-arrow
  { --> (list symbol) }
  -> (let Pair (tc-assoc (intern "tst-fact") (%% value tc-global-sig-table))
       (tc-assert-equal "infer: fact stored as (mono) arrow, not forall"
         arrow (tc-type-tag (hd (tl Pair))))))

(define test-infer-7-multi-clause-ok
  { --> (list symbol) }
  -> (tc-assert-ok "infer: multi-clause consistent defines infer"
       (tc-hm-infer-define (intern "tst-self")
         [(intern "X") (intern "->") (intern "X")
          0 (intern "->") 0])))

(define test-infer-8-multi-clause-conflict
  { --> (list symbol) }
  -> (tc-assert-fail "infer: multi-clause return-type conflict rejected"
       (tc-hm-infer-define (intern "tst-conf")
         [(intern "X") (intern "->") [(intern "+") (intern "X") 1]
          (intern "Y") (intern "->") "boom"])))

(define test-infer-9-arity-mismatch
  { --> (list symbol) }
  -> (tc-assert-fail "infer: clauses with different arity rejected"
       (tc-hm-infer-define (intern "tst-ari")
         [(intern "X") (intern "->") (intern "X")
          (intern "X") (intern "Y") (intern "->") (intern "X")])))

(define test-infer-10-cross-use
  { --> (list symbol) }
  -> (tc-assert-ok "infer: later define resolves an inferred scheme"
       (tc-hm-infer-define (intern "tst-use")
         [(intern "N") (intern "->") [(intern "tst-fact") (intern "N")]])))

\* ================================================================
   TEST RUNNER
   ================================================================ *\

\* Render the accumulated failure strings (already reversed into test order),
   one per line.  cn takes exactly 2 args; (n->string 10) is a real newline
   (Shen 41.2 does not interpret "\n" in string literals). *\
(define tc-tests-failures-str
  { (list string) --> string }
  [] -> ""
  [F] -> (cn F (n->string 10))
  [F | Rest] -> (cn F (cn (n->string 10) (tc-tests-failures-str Rest))))

\* Build the Passed/Failed summary line plus any failure details. *\
(define tc-tests-summary-str
  { number --> number --> (list string) --> string }
  Passed Failed Failures ->
    (let Header (cn "=== TC-HM Test Results ===" (n->string 10))
      (let PassedLine (cn "Passed: " (cn (str Passed) (n->string 10)))
        (let FailedLine (cn "Failed: " (cn (str Failed) (n->string 10)))
          (let Details (tc-tests-failures-str Failures)
            (let Tail (if (= Failed 0) "All tests passed!" "Some tests FAILED.")
              (cn (cn (cn Header PassedLine) (cn FailedLine Details)) Tail)))))))

(define tc-hm-tests-run-all
  { --> string }
  -> (do (%% set test-passed 0)
         (%% set test-failed 0)
         (%% set test-failures [])
         \* Stage 1: Unification *\
         (test-unify-1-equal-numbers)
         (test-unify-2-number-vs-string)
         (test-unify-3-tvar-binds-to-con)
         (test-unify-4-tvar-binds-to-arrow)
         (test-unify-5-occurs-check-fires)
         (test-unify-6-two-tvars-equal)
         (test-unify-7-two-tvars-different)
         (test-unify-8-arrow-structural)
         (test-unify-9-arrow-mismatch)
         (test-unify-10-polymorphic-arrow)
         (test-unify-11-app-types)
         (test-unify-12-app-mismatch-con)
         (test-unify-13-prod-types)
         (test-unify-14-deep-arrow)
         (test-unify-15-walk-follows-chain)
         (test-unify-16-apply-subst)
         (test-unify-17-free-tvars)
         (test-unify-18-instantiate-forall)
         (test-unify-19-generalize)
         (test-unify-20-occurs-check-deep)
         \* Stage 2: Algorithm W *\
         (test-w-1-lambda-id)
         (test-w-2-number-lit)
         (test-w-3-string-lit)
         (test-w-4-empty-list)
         (test-w-5-let-id)
         (test-w-6-plus-numbers-ok)
         (test-w-7-plus-string-fails)
         (test-w-8-if-bool)
         (test-w-9-if-nonbool-condition)
         (test-w-10-and-bool)
         (test-w-11-cons-data)
         \* Stage 2b: Guard-driven type refinement *\
         (test-w-12-cons-narrows-then)
         (test-w-13-symbol-narrows-then)
         (test-w-14-no-refine-in-else)
         (test-w-15-and-chain-refines)
         \* Stage 3: Pattern typing *\
         (test-pat-1-wildcard)
         (test-pat-2-variable)
         (test-pat-3-empty-list)
         (test-pat-4-cons-pattern)
         (test-pat-5-number-tag)
         \* Stage 4: Sig parsing *\
         (test-sig-1-simple-arrow)
         (test-sig-2-polymorphic)
         (test-sig-3-multi-arg)
         (test-sig-4-no-type-vars)
         \* Stage 5: Root-cause-D fix — rep-name top-type, opaque-ground, prim-lookup fallback *\
         (test-top-rep-1-type)
         (test-top-rep-2-expr)
         (test-top-rep-3-subst)
         (test-top-rep-4-env)
         (test-top-rep-5-result)
         (test-top-rep-6-infer-result)
         (test-top-rep-7-pat-result)
         (test-top-rep-8-tc-result)
         (test-top-rep-9-zinc-value-not-top)
         (test-opaque-rep-1-type)
         (test-opaque-rep-2-expr)
         (test-opaque-rep-3-subst)
         (test-opaque-rep-4-env)
         (test-opaque-rep-5-result)
         (test-opaque-rep-6-infer-result)
         (test-opaque-rep-7-pat-result)
         (test-opaque-rep-8-tc-result)
         (test-prim-lookup-unknown-tvar)
         (test-infer-app-unknown-1arg-tvar)
         \* Stage 6: define-level checking — higher-order ret sigs + inference *\
         (test-define-1-ho-ret-sig)
         (test-define-2-ho-ret-body-mismatch)
         (test-define-3-arity-exceeds-sig)
         (test-define-4-nested-app-ret)
         (test-infer-1-id-infers)
         (test-infer-2-id-scheme-stored)
         (test-infer-3-num-body)
         (test-infer-4-bad-body-fails)
         (test-infer-5-recursive-fact)
         (test-infer-6-fact-mono-arrow)
         (test-infer-7-multi-clause-ok)
         (test-infer-8-multi-clause-conflict)
         (test-infer-9-arity-mismatch)
         (test-infer-10-cross-use)
         \* Report: build the summary string and RETURN it.  print is NOT a C
            primitive in the reduced bundle (print/pr are Shen OS functions the
            reduced bundle skips), so (print ...) miscompiles to [global print]
            + apply.  Return a string the C VM --tc-hm-tests driver prints. *\
         (tc-tests-summary-str (%% value test-passed)
                               (%% value test-failed)
                               (tc-reverse (%% value test-failures)))))

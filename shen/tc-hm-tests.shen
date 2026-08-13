(tc -)

\* tc-hm-tests.shen — synthetic test cases for the HM type checker.
   Load on host shen-scheme and run (run-tc-hm-tests).
   Tests cover: unification, Algorithm W, pattern typing, sig parsing. *\

\* Load components directly to avoid shen-read-file dependency in tc-hm.shen *\
(load "shen/tc-hm-types.shen")
(load "shen/tc-hm-w.shen")
(load "shen/tc-hm-prims.shen")
(load "shen/tc-hm-patterns.shen")
(load "shen/tc-hm-sig.shen")

\* ===== Test infrastructure ===== *\

(set test-passed 0)
(set test-failed 0)

(define tc-assert-ok
  { string --> result --> (list symbol) }
  Label [ok _] -> (do (%% set test-passed (+ (%% value test-passed) 1))
                      [])
  Label [fail Reason] -> (do (%% set test-failed (+ (%% value test-failed) 1))
                              (print (cn "FAIL " (cn Label (cn ": " Reason))))
                              (print "\n")
                              [])
  Label X -> (do (%% set test-failed (+ (%% value test-failed) 1))
                 (print (cn "FAIL " (cn Label ": unexpected result")))
                 (print "\n")
                 []))

(define tc-assert-fail
  { string --> result --> (list symbol) }
  Label [fail _] -> (do (%% set test-passed (+ (%% value test-passed) 1))
                        [])
  Label [ok _] -> (do (%% set test-failed (+ (%% value test-failed) 1))
                      (print (cn "FAIL " (cn Label ": expected fail, got ok")))
                      (print "\n")
                      [])
  Label X -> (do (%% set test-failed (+ (%% value test-failed) 1))
                 (print (cn "FAIL " (cn Label ": unexpected result")))
                 (print "\n")
                 []))

(define tc-assert-equal
  { string --> A --> A --> (list symbol) }
  Label Expected Actual ->
    (if (= Expected Actual)
        (do (%% set test-passed (+ (%% value test-passed) 1))
            [])
        (do (%% set test-failed (+ (%% value test-failed) 1))
            (print (cn "FAIL " (cn Label (cn ": expected " (cn (str Expected) (cn " got " (str Actual)))))))
            (print "\n")
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
  -> (let Sub [[0 [con number]] | [[1 [con boolean]] | []]]
       (tc-assert-ok "unify: walk through chain"
         (tc-unify [tvar 0] [tvar 1] Sub))))

(define test-unify-16-apply-subst
  { --> (list symbol) }
  -> (let Sub [[0 [con number]]]
       (tc-assert-equal "apply-subst: tvar→con"
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
             (tc-assert-equal "W: [] is (list tvar)"
               list (tc-app-con Type)))
           (tc-assert-ok "W: empty list" R))))

(define test-w-5-let-id
  { --> (list symbol) }
  -> (let R (tc-infer [] [let id [lambda X X] [id 42]] [])
       (if (tc-ok? R)
           (let Type (hd (tl (tc-ok-subst-type R)))
             (let Final (tc-apply-subst (hd (tc-ok-subst-type R)) Type)
               (tc-assert-equal "W: let id = \\x.x in id 42"
                 [con number] Final)))
           (tc-assert-ok "W: let id" R))))

(define test-w-6-plus-numbers-ok
  { --> (list symbol) }
  -> (tc-assert-ok "W: (+ 1 2) ok"
       (tc-infer [] [+ 1 2] [])))

(define test-w-7-plus-string-fails
  { --> (list symbol) }
  -> (tc-assert-fail "W: (+ 1 \"x\") fails"
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
         arrow (tc-type-tag (tc-forall-body Parsed)))))

(define test-sig-2-polymorphic
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") A --> A (intern "}")])
       (tc-assert-equal "sig: {A --> A} is forall"
         forall (tc-type-tag Parsed))))

(define test-sig-3-multi-arg
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") A --> (list A) --> number (intern "}")])
       (tc-assert-equal "sig: {A --> (list A) --> number} is forall"
         forall (tc-type-tag Parsed))))

(define test-sig-4-no-type-vars
  { --> (list symbol) }
  -> (let Parsed (tc-parse-sig [(intern "{") --> symbol (intern "}")])
       (tc-assert-equal "sig: {--> symbol} is arrow (nullary)"
         arrow (tc-type-tag Parsed))))

\* ================================================================
   TEST RUNNER
   ================================================================ *\

(define run-tc-hm-tests
  { --> string }
  -> (do (%% set test-passed 0)
         (%% set test-failed 0)
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
         \* Report *\
         (print (cn "\n=== TC-HM Test Results ===\n"))
         (print (cn "Passed: " (cn (str (%% value test-passed)) "\n")))
         (print (cn "Failed: " (cn (str (%% value test-failed)) "\n")))
         (if (= (%% value test-failed) 0)
             (print "All tests passed!\n")
             (print "Some tests FAILED.\n"))
         ""))

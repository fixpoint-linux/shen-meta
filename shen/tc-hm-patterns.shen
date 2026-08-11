(tc -)

\* tc-hm-patterns.shen - Stage 3: pattern typing for define clauses.
   Safe-subset only; mirrors shen-kl-helpers.shen style.
   Depends on: tc-hm-types.shen for type rep + unify.
   Given a pattern and a declared type, produce variable bindings
   and tc-unify the pattern's expected type with the declared type.

   Design note: tc-type-pattern dispatches on (tc-pat-tag Pat) via a
   MULTI-CLAUSE define (tc-type-pattern-dispatch) whose clause heads
   are LITERAL lowercase symbols.  This keeps the Shen source FLAT -
   shen-kl-helpers' compile-pattern treats each literal symbol as a
   (= Slot TAG) test, so the dispatcher compiles to a (cond [...])
   chain that kmacros then rewrites into nested ifs INSIDE the
   compiler (not the reader).  Writing the dispatch as one giant
   nested (if ...) in source hits the Shen reader's nesting limit
   (it broke the bundle at depth ~16).  DO NOT collapse the
   dispatcher back into a single nested-if form. *\

(load "shen/tc-hm-types.shen")

\* ===== Pattern classification ===== *\

\* tc-pat-tag: classify a pattern into a dispatch tag.
   Lowercase symbol patterns (literal constructor keywords like
   access / and / cur appearing inside a structure pattern) are
   routed to symbol-lit so tc-type-pattern can unify them with
   [con symbol] via tc-type-pat-lit. *\

(define tc-pat-tag
  { expr --> symbol }
  Pat -> (if (= Pat (intern "_"))
              wildcard
              (if (variable? Pat)
                  variable
                  (if (number? Pat)
                      number-lit
                      (if (string? Pat)
                          string-lit
                          (if (boolean? Pat)
                              boolean-lit
                              (if (= Pat [])
                                  empty-list
                                  (if (cons? Pat)
                                      (tc-pat-head-tag (hd Pat) Pat)
                                      (if (symbol? Pat)
                                          symbol-lit
                                          unknown)))))))))

\* tc-pat-head-tag: classify the head of a cons pattern.
   Head=cons with the SECOND element also cons => genuine
   [cons P1 P2] constructor pattern; otherwise it is a
   reader-consified list literal (e.g. [X] -> (cons X ())) and is
   routed to list-pat.
   The reader consifies bracketed list literals BEFORE the pattern
   compiler runs, so tc-pat-head-tag must distinguish the two cases
   itself. *\

(define tc-pat-head-tag
  { expr --> expr --> symbol }
  Hd Full -> (if (symbol? Hd)
                  (if (= Hd (intern "cons"))
                      (if (cons? (tl Full))
                          (if (= (hd (tl Full)) (intern "cons"))
                              cons-pat
                              list-pat)
                          list-pat)
                      (if (= Hd (intern "number"))
                          number-tag
                          (if (= Hd (intern "symbol"))
                              symbol-tag
                              (if (= Hd (intern "string"))
                                  string-tag
                                  (if (= Hd (intern "boolean"))
                                      boolean-tag
                                      (if (= Hd (intern "stream"))
                                          stream-tag
                                          (if (= Hd (intern "lambda"))
                                              lambda-tag
                                              (if (= Hd (intern "error"))
                                                  error-tag
                                                  (if (= Hd (intern "absvector"))
                                                      absvector-tag
                                                      list-pat)))))))))
                  list-pat))

\* ===== type-pattern: type a pattern against a declared type =====
   Returns [ok [Subst Bindings]] or [fail Reason].
   Bindings = [[name . type] | ...] for pattern variables.

   Multi-clause dispatch on the tag symbol keeps the source shallow
   (see file header).  The catch-all _ routes unknown tags (and any
   bare lowercase symbol falling through tc-pat-tag's symbol-lit
   branch via tc-pat-head-tag's list-pat fallback) to the list
   pattern handler. *\

(define tc-type-pattern
  { expr --> type --> subst --> pat-result }
  Pat DeclType Sub -> (tc-type-pattern-dispatch (tc-pat-tag Pat) Pat DeclType Sub))

(define tc-type-pattern-dispatch
  { symbol --> expr --> type --> subst --> pat-result }
  wildcard      Pat DeclType Sub -> (tc-type-pat-wildcard DeclType Sub)
  variable      Pat DeclType Sub -> (tc-type-pat-variable Pat DeclType Sub)
  number-lit    Pat DeclType Sub -> (tc-type-pat-lit [con number] DeclType Sub)
  string-lit    Pat DeclType Sub -> (tc-type-pat-lit [con string] DeclType Sub)
  boolean-lit   Pat DeclType Sub -> (tc-type-pat-lit [con boolean] DeclType Sub)
  symbol-lit    Pat DeclType Sub -> (tc-type-pat-lit [con symbol] DeclType Sub)
  empty-list    Pat DeclType Sub -> (tc-type-pat-empty DeclType Sub)
  cons-pat      Pat DeclType Sub -> (tc-type-pat-cons Pat DeclType Sub)
  number-tag    Pat DeclType Sub -> (tc-type-pat-tag Pat DeclType Sub)
  symbol-tag    Pat DeclType Sub -> (tc-type-pat-tag Pat DeclType Sub)
  string-tag    Pat DeclType Sub -> (tc-type-pat-tag Pat DeclType Sub)
  boolean-tag   Pat DeclType Sub -> (tc-type-pat-tag Pat DeclType Sub)
  stream-tag    Pat DeclType Sub -> (tc-type-pat-zv-tag Pat DeclType Sub)
  lambda-tag    Pat DeclType Sub -> (tc-type-pat-zv-tag Pat DeclType Sub)
  error-tag     Pat DeclType Sub -> (tc-type-pat-zv-tag Pat DeclType Sub)
  absvector-tag Pat DeclType Sub -> (tc-type-pat-zv-tag Pat DeclType Sub)
  list-pat      Pat DeclType Sub -> (tc-type-pat-list Pat DeclType Sub)
  _             Pat DeclType Sub -> (tc-type-pat-list Pat DeclType Sub))

\* ===== Wildcard: tc-unify tc-fresh-tvar with declared type, no bindings ===== *\

(define tc-type-pat-wildcard
  { type --> subst --> pat-result }
  DeclType Sub -> (let RU (tc-unify (tc-fresh-tvar (intern "")) DeclType Sub)
                    (if (tc-ok? RU)
                        [ok [(tc-ok-subst RU) []]]
                        RU)))

\* ===== Variable: fresh-tvar, bind name:tvar, tc-unify with declared type ===== *\

(define tc-type-pat-variable
  { symbol --> type --> subst --> pat-result }
  Var DeclType Sub -> (let VarType (tc-fresh-tvar (intern ""))
                        (let RU (tc-unify VarType DeclType Sub)
                          (if (tc-ok? RU)
                              (let FinalSub (tc-ok-subst RU)
                                [ok [FinalSub [[Var (tc-apply-subst FinalSub VarType)]]]])
                              RU))))

\* ===== Literal: tc-unify concrete type with declared type, no bindings =====
   Used for number/string/boolean literals AND for symbol-lit
   (lowercase constructor keywords like access / and / cur appearing
   as literal elements inside structure patterns - they unify with
   [con symbol]). *\

(define tc-type-pat-lit
  { type --> type --> subst --> pat-result }
  LitType DeclType Sub -> (let RU (tc-unify LitType DeclType Sub)
                            (if (tc-ok? RU)
                                [ok [(tc-ok-subst RU) []]]
                                RU)))

\* ===== Empty list: [app list fresh-tvar] ===== *\

(define tc-type-pat-empty
  { type --> subst --> pat-result }
  DeclType Sub -> (let ListType [app list (tc-fresh-tvar (intern ""))]
                    (let RU (tc-unify ListType DeclType Sub)
                      (if (tc-ok? RU)
                          [ok [(tc-ok-subst RU) []]]
                          RU))))

\* ===== Cons pattern: [cons P1 P2] - opaque zinc-value =====
   Stage 1 soundness gap (documented): whole pattern and both
   sub-patterns default to zinc-value.  Sound for what it checks;
   does not refine sub-pattern types against the declared type. *\

(define tc-type-pat-cons
  { expr --> type --> subst --> pat-result }
  Pat DeclType Sub ->
    (if (and (cons? Pat)
             (let Hd (hd Pat)
               (= Hd (intern "cons"))))
        (let Rest (tl Pat)
          (if (cons? Rest)
              (let P1 (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let P2 (hd Rest2)
                        (let ZV [con zinc-value]
                          (let RU (tc-unify ZV DeclType Sub)
                            (if (tc-ok? RU)
                                (let Sub1 (tc-ok-subst RU)
                                  (let R1 (tc-type-pattern P1 ZV Sub1)
                                    (if (tc-ok? R1)
                                        (let Pair1 (tc-ok-subst-bindings R1)
                                          (let Sub2 (hd Pair1)
                                            (let Binds1 (hd (tl Pair1))
                                              (let R2 (tc-type-pattern P2 ZV Sub2)
                                                (if (tc-ok? R2)
                                                    (let Pair2 (tc-ok-subst-bindings R2)
                                                      (let Sub3 (hd Pair2)
                                                        (let Binds2 (hd (tl Pair2))
                                                          [ok [Sub3 (tc-append Binds1 Binds2)]])))
                                                    R2)))))
                                        R1)))
                                RU))))
                      [fail "type-pat-cons: malformed cons pattern"])))
              [fail "type-pat-cons: malformed cons pattern"]))
        [fail "type-pat-cons: malformed cons pattern"]))

\* ===== Tag pattern: [number X], [symbol X], etc. - opaque zinc-value =====
   Whole pattern: zinc-value. Variable X: zinc-value (opaque). *\

(define tc-type-pat-tag
  { expr --> type --> subst --> pat-result }
  [Tag Var] DeclType Sub ->
    (if (variable? Var)
        (let ZV [con zinc-value]
          (let RU (tc-unify ZV DeclType Sub)
            (if (tc-ok? RU)
                (let Sub1 (tc-ok-subst RU)
                  [ok [Sub1 [[Var ZV]]]])
                RU)))
        [fail "type-pat-tag: second element must be a variable"])
  _ _ _ -> [fail "type-pat-tag: malformed tag pattern"])

\* ===== ZV tag with arbitrary sub-patterns =====
   For [stream Dir X], [lambda C E], [error X], [absvector X].
   Whole pattern: [con zinc-value]. Each variable sub-arg binds to
   [con zinc-value] (opaque, Stage 1 soundness gap).  Non-variable
   sub-args are skipped (they are literal tag keywords like the
   direction symbol in [stream in X]). *\

(define tc-type-pat-zv-tag
  { expr --> type --> subst --> pat-result }
  Pat DeclType Sub ->
    (if (cons? Pat)
        (let ZV [con zinc-value]
          (let RU (tc-unify ZV DeclType Sub)
            (if (tc-ok? RU)
                (let Sub1 (tc-ok-subst RU)
                  (tc-type-pat-zv-tag-args (tl Pat) ZV Sub1))
                RU)))
        [fail "type-pat-zv-tag: malformed"]))

(define tc-type-pat-zv-tag-args
  { (list expr) --> type --> subst --> pat-result }
  Args ElmType Sub -> (if (cons? Args)
                          (let Arg (hd Args)
                            (let Rest (tl Args)
                              (if (variable? Arg)
                                  (let R (tc-type-pat-zv-tag-args Rest ElmType Sub)
                                    (if (tc-ok? R)
                                        (let Pair (tc-ok-subst-bindings R)
                                          (let Sub2 (hd Pair)
                                            (let Binds (hd (tl Pair))
                                              [ok [Sub2 [[Arg ElmType] | Binds]]])))
                                        R))
                                  (tc-type-pat-zv-tag-args Rest ElmType Sub))))
                          [ok [Sub []]]))

\* ===== List pattern: [H | T] - proper list decomposition =====
   H : A, T : [app list A], whole : [app list A].
   No structure-pattern branch: a [H | T] pattern under an opaque
   ground DeclType falls through ordinary list typing (the cons-or-
   list disambiguation in tc-pat-head-tag ensures genuine [cons P1
   P2] never reaches this handler). *\

(define tc-type-pat-list
  { expr --> type --> subst --> pat-result }
  [H | T] DeclType Sub ->
    (let A (tc-fresh-tvar (intern ""))
      (let ListA [app list A]
        (let RU (tc-unify ListA DeclType Sub)
          (if (tc-ok? RU)
              (let Sub1 (tc-ok-subst RU)
                (let AH (tc-apply-subst Sub1 A)
                  (let R1 (tc-type-pattern H AH Sub1)
                    (if (tc-ok? R1)
                        (let Pair1 (tc-ok-subst-bindings R1)
                          (let Sub2 (hd Pair1)
                            (let Binds1 (hd (tl Pair1))
                              (let AT (tc-apply-subst Sub2 A)
                                (let ListAT [app list AT]
                                  (let R2 (tc-type-pattern T ListAT Sub2)
                                    (if (tc-ok? R2)
                                        (let Pair2 (tc-ok-subst-bindings R2)
                                          (let Sub3 (hd Pair2)
                                            (let Binds2 (hd (tl Pair2))
                                              [ok [Sub3 (tc-append Binds1 Binds2)]])))
                                        R2)))))))
                        R1))))
              RU))))
  _ _ _ -> [fail "type-pat-list: malformed list pattern"])

\* ===== Result helpers for pattern typing ===== *\

(define tc-ok-subst-bindings
  { pat-result --> (list subst (list (list symbol type))) }
  [ok [Sub Binds]] -> [Sub Binds]
  _ -> [[] []])

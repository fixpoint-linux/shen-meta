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

\* tc-opaque-ground?: true iff DeclType (after walking) is a [con X]
   for X in the recognised opaque ground type names (zinc-value, klambda,
   zinc-code, zinc-instruction, absvector, stream, error).  Patterns
   matched against an opaque ground type are typed permissively: literal
   sub-patterns are skipped, variables bind to fresh tvars, and
   cons-cell patterns recurse.  This lets structure patterns like
   [label L | C] under a { zinc-code --> ... } sig type-check without
   forcing the literal keyword `label` to unify with the opaque type. *\

(define tc-opaque-ground?
  { type --> subst --> boolean }
  T Sub -> (let W (tc-walk T Sub)
             (if (and (cons? W) (= (hd W) (intern "con")))
                 (tc-element? (tc-con-name W)
                              [(intern "zinc-value")
                               (intern "klambda")
                               (intern "zinc-code")
                               (intern "zinc-instruction")
                               (intern "absvector")
                               (intern "stream")
                               (intern "error")])
                 false)))

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
   shen-read-file (the .shen reader used by --tc-hm) encodes every
   source bracket list with a literal 'cons marker: source [a b] reads
   as [cons a [cons b []]] (a 3-element list whose first element is the
   symbol cons).  Source [a | b] reads as [cons a b].  Both forms are
   semantically cons-cell patterns: P1 = car, P2 = cdr.  We route ANY
   3-element proper list whose head is 'cons to cons-pat (the safe-subset
   compiler + C VM handle the rest).  Lists whose head is a recognised
   tag keyword (number/symbol/string/...) route to the corresponding
   *-tag handler; everything else falls through to list-pat. *\

(define tc-pat-head-tag
  { expr --> expr --> symbol }
  Hd Full -> (if (symbol? Hd)
                  (if (= Hd (intern "cons"))
                      (if (tc-pat-cons-shape? Full)
                          cons-pat
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

\* tc-pat-cons-shape?: true iff Full is a 3-element proper list whose
   head is the symbol cons — i.e. a reader-encoded cons-cell pattern
   [cons P1 P2].  We require exactly 3 elements so that [cons] (1 source
   element) reading as [cons cons []] still counts (P1=cons, P2=[]),
   but a 4+-element literal like [cons A B C] (source [cons A B C])
   falls through to list-pat. *\

(define tc-pat-cons-shape?
  { expr --> boolean }
  Full -> (if (cons? Full)
              (if (= (hd Full) (intern "cons"))
                  (tc-pat-cons-shape?-rest (tl Full))
                  false)
              false))

(define tc-pat-cons-shape?-rest
  { expr --> boolean }
  Rest -> (if (cons? Rest)
              (tc-pat-cons-shape?-rest2 (tl Rest))
              false))

(define tc-pat-cons-shape?-rest2
  { expr --> boolean }
  Rest -> (if (cons? Rest)
              (tc-empty? (tl Rest))
              false))

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
                                (if (tc-opaque-ground? DeclType Sub)
                                    [ok [Sub []]]
                                    RU))))

\* ===== Empty list: [app list fresh-tvar], or opaque ground =====
   `[]` against a (list A) type unifies with [app list fresh]; against
   an opaque ground type (zinc-value/klambda/zinc-code/...) it matches
   permissively (the empty list IS a valid value of any opaque ground
   type).  This lets patterns like `[]` inside `[cons X []]` (reader
   form of source `[X]`) succeed against an opaque DeclType. *\

(define tc-type-pat-empty
  { type --> subst --> pat-result }
  DeclType Sub -> (let ListType [app list (tc-fresh-tvar (intern ""))]
                    (let RU (tc-unify ListType DeclType Sub)
                      (if (tc-ok? RU)
                          [ok [(tc-ok-subst RU) []]]
                          (if (tc-opaque-ground? DeclType Sub)
                              [ok [Sub []]]
                              RU)))))

\* ===== Cons pattern: [cons P1 P2] - the reader-encoded cons-cell pattern.
   shen-read-file wraps every source bracket list with a literal 'cons
   marker, so source [a | b] reads as [cons a b] and source [a b] reads
   as [cons a [cons b []]].  Both forms reach this handler: P1 = car
   pattern, P2 = cdr pattern.
   Dispatch on DeclType:
     - If DeclType walks to [app list A]: list decomposition.  P1 : A,
       P2 : [app list A].  This handles `[X | _] : (list zinc-value)`
       and `[X] : (list A)` correctly (P1 binds to the element type,
       P2 to the list tail type).
     - Otherwise (opaque ground like zinc-value/zinc-code/klambda, or a
       tvar, or any other con): opaque-cons.  P1 and P2 are typed
       permissively via tc-type-pat-opaque-sub: literals are skipped,
       variables bind to fresh tvars, and nested cons-cell patterns
       recurse.  This handles [cons X Y] : zinc-value, [label L | C] :
       zinc-code, [cons F Args] : klambda, etc.  Soundness gap: the
       sub-pattern types are not refined against the declared opaque
       type — Stage 1 permissiveness. *\

(define tc-type-pat-cons
  { expr --> type --> subst --> pat-result }
  Pat DeclType Sub ->
    (if (and (cons? Pat) (= (hd Pat) (intern "cons")))
        (let Rest (tl Pat)
          (if (cons? Rest)
              (let P1 (hd Rest)
                (let Rest2 (tl Rest)
                  (if (cons? Rest2)
                      (let P2 (hd Rest2)
                        (tc-type-pat-cons2 P1 P2 DeclType Sub))
                      [fail "type-pat-cons: malformed cons pattern"])))
              [fail "type-pat-cons: malformed cons pattern"]))
        [fail "type-pat-cons: malformed cons pattern"]))

\* tc-type-pat-cons2: dispatch on whether DeclType is a list type.
   OPAQUE-GROUND CHECK FIRST: if DeclType walks to [con X] for X in the
   opaque-ground set (zinc-value, klambda, zinc-code, zinc-instruction,
   absvector, stream, error), route straight to opaque-cons.  We cannot
   rely on the unify-failure fallback because the tc-unify-walked
   top-type rule (klambda is top) makes [app list A] unify with klambda
   succeed, which would wrongly send an opaque cons into list-decomp and
   force its literal keyword heads to unify with the post-walk element
   type.  In the genuine list-decomp case (DeclType is [app list A] or a
   tvar), the head pattern P1 is typed against the element type A.  When
   A is itself an opaque ground type, literal keyword heads like `grab`
   inside `[grab | C] : (list zinc-instruction)` are routed through
   tc-type-pat-opaque-sub so they match permissively. *\

(define tc-type-pat-cons2
  { expr --> expr --> type --> subst --> pat-result }
  P1 P2 DeclType Sub ->
    (if (tc-opaque-ground? DeclType Sub)
        (tc-type-pat-cons-opaque P1 P2 DeclType Sub)
        (let A (tc-fresh-tvar (intern ""))
      (let ListA [app list A]
        (let RU (tc-unify ListA DeclType Sub)
          (if (tc-ok? RU)
              \* list-decomp: P1 : A, P2 : (list A) *\
              (let Sub1 (tc-ok-subst RU)
                (let AH (tc-apply-subst Sub1 A)
                  (let R1 (tc-type-pat-cons-head P1 AH Sub1)
                    (if (tc-ok? R1)
                        (let Pair1 (tc-ok-subst-bindings R1)
                          (let Sub2 (hd Pair1)
                            (let Binds1 (hd (tl Pair1))
                              (let AT (tc-apply-subst Sub2 A)
                                (let ListAT [app list AT]
                                  (let R2 (tc-type-pattern P2 ListAT Sub2)
                                    (if (tc-ok? R2)
                                        (let Pair2 (tc-ok-subst-bindings R2)
                                          (let Sub3 (hd Pair2)
                                            (let Binds2 (hd (tl Pair2))
                                              [ok [Sub3 (tc-append Binds1 Binds2)]])))
                                        R2)))))))
                        R1))))
              \* opaque-cons: permissive sub-pattern typing *\
              (tc-type-pat-cons-opaque P1 P2 DeclType Sub)))))))

\* tc-type-pat-cons-head: type the head sub-pattern P1 against the
   list element type AH.  If AH is an opaque ground type, route through
   tc-type-pat-opaque-sub so literal keyword heads (grab, label, ...)
   match permissively.  Otherwise use the normal tc-type-pattern. *\

(define tc-type-pat-cons-head
  { expr --> type --> subst --> pat-result }
  P1 AH Sub ->
    (if (tc-opaque-ground? AH Sub)
        (tc-type-pat-opaque-sub P1 AH Sub)
        (tc-type-pattern P1 AH Sub)))

\* tc-type-pat-cons-opaque: type P1 and P2 permissively against an
   opaque ground DeclType.  P1 is the car pattern (often a literal
   keyword like `label` or `access` inside a structure pattern), P2 is
   the cdr pattern.  Both go through tc-type-pat-opaque-sub which
   skips literals, binds variables to fresh tvars, and recurses on
   nested cons-cell patterns. *\

(define tc-type-pat-cons-opaque
  { expr --> expr --> type --> subst --> pat-result }
  P1 P2 OpaqueType Sub ->
    (let R1 (tc-type-pat-opaque-sub P1 OpaqueType Sub)
      (if (tc-ok? R1)
          (let Pair1 (tc-ok-subst-bindings R1)
            (let Sub2 (hd Pair1)
              (let Binds1 (hd (tl Pair1))
                (let R2 (tc-type-pat-opaque-sub P2 OpaqueType Sub2)
                  (if (tc-ok? R2)
                      (let Pair2 (tc-ok-subst-bindings R2)
                        (let Sub3 (hd Pair2)
                          (let Binds2 (hd (tl Pair2))
                            [ok [Sub3 (tc-append Binds1 Binds2)]])))
                      R2)))))
          R1)))

\* tc-type-pat-opaque-sub: permissive sub-pattern typing under an
   opaque ground DeclType.  Wildcards and literals match silently,
   variables bind to fresh tvars (so the body's constraints determine
   their actual type), and cons-cell patterns recurse through
   tc-type-pat-cons.  Tag patterns like [number X] are flattened by the
   reader into [cons number [cons X []]] so they reach this handler
   via the cons-pat branch and bind X to a fresh tvar. *\

(define tc-type-pat-opaque-sub
  { expr --> type --> subst --> pat-result }
  Pat OpaqueType Sub -> (tc-type-pat-opaque-sub-dispatch (tc-pat-tag Pat) Pat OpaqueType Sub))

(define tc-type-pat-opaque-sub-dispatch
  { symbol --> expr --> type --> subst --> pat-result }
  wildcard Pat OpaqueType Sub -> [ok [Sub []]]
  variable Pat OpaqueType Sub -> (let V (tc-fresh-tvar (intern ""))
                                   [ok [Sub [[Pat V]]]])
  cons-pat Pat OpaqueType Sub -> (tc-type-pat-cons Pat OpaqueType Sub)
  _ Pat OpaqueType Sub -> [ok [Sub []]])

\* ===== Tag pattern: [number X], [symbol X], etc. =====
   Whole pattern unifies with DeclType as zinc-value.  Variable X binds
   to a REFINED type (number/symbol/string/boolean) per the tag, not
   opaque zinc-value (option-C sanity check: tighter self-check). *\

(define tc-tag-refined-type
  { symbol --> type }
  Tag -> (if (= Tag (intern "number")) [con number]
          (if (= Tag (intern "symbol")) [con symbol]
          (if (= Tag (intern "string")) [con string]
          (if (= Tag (intern "boolean")) [con boolean]
              [con zinc-value])))))

(define tc-type-pat-tag
  { expr --> type --> subst --> pat-result }
  [Tag Var] DeclType Sub ->
    (if (variable? Var)
        (let ZV [con zinc-value]
          (let RU (tc-unify ZV DeclType Sub)
            (if (tc-ok? RU)
                (let Sub1 (tc-ok-subst RU)
                  (let Ref (tc-tag-refined-type Tag)
                    [ok [Sub1 [[Var Ref]]]]))
                RU)))
        [fail "type-pat-tag: second element must be a variable"])
  _ _ _ -> [fail "type-pat-tag: malformed tag pattern"])

\* ===== ZV tag with arbitrary sub-patterns =====
   For [stream Dir X], [lambda C E], [error X], [absvector X].
   Whole pattern: [con zinc-value].  Each variable sub-arg binds to a
   REFINED type per the tag (option-C sanity check), instead of the
   Stage-1 opaque [con zinc-value].  Non-variable sub-args are skipped
   (literal tag keywords like the direction in [stream in X]). *\

(define tc-type-pat-zv-tag
  { expr --> type --> subst --> pat-result }
  Pat DeclType Sub ->
    (if (cons? Pat)
        (let ZV [con zinc-value]
          (let RU (tc-unify ZV DeclType Sub)
            (if (tc-ok? RU)
                (let Sub1 (tc-ok-subst RU)
                  (tc-zv-tag-typed (hd Pat) (tl Pat) Sub1))
                RU)))
        [fail "type-pat-zv-tag: malformed"]))

\* tc-zv-tag-typed: dispatch on the tag symbol, bind each var sub-arg to
   its refined type per types.shen.  Args is the tag's sub-pattern list. *\

(define tc-zv-tag-typed
  { symbol --> (list expr) --> subst --> pat-result }
  Tag Args Sub ->
    (if (= Tag (intern "lambda"))
        (tc-type-pat-zv-tag-args Args [[con zinc-code] [app list [con zinc-value]]] Sub)
        (if (= Tag (intern "error"))
            (tc-type-pat-zv-tag-args Args [[con exception]] Sub)
            (if (= Tag (intern "absvector"))
                (tc-type-pat-zv-tag-args Args [[con absvector]] Sub)
                (if (= Tag (intern "stream"))
                    (tc-zv-tag-stream Args Sub)
                    (tc-type-pat-zv-tag-args Args [] Sub))))))

\* tc-zv-tag-stream: [stream Dir X].  Dir is a literal direction symbol
   (in/out); X binds to the parameterized stream type. *\

(define tc-zv-tag-stream
  { (list expr) --> subst --> pat-result }
  Args Sub ->
    (if (and (cons? Args) (symbol? (hd Args)))
        (if (= (hd Args) (intern "in"))
            (tc-type-pat-zv-tag-args (tl Args) [[app stream [con in]]] Sub)
            (if (= (hd Args) (intern "out"))
                (tc-type-pat-zv-tag-args (tl Args) [[app stream [con out]]] Sub)
                (tc-type-pat-zv-tag-args Args [] Sub)))
        (tc-type-pat-zv-tag-args Args [] Sub)))

\* tc-type-pat-zv-tag-args: bind variable sub-args to a per-arg type list.
   TypeList is parallel to Args; literal (non-variable) sub-args consume a
   type position but bind nothing.  Empty TypeList -> bind all vars opaque. *\

(define tc-type-pat-zv-tag-args
  { (list expr) --> (list type) --> subst --> pat-result }
  Args TypeList Sub -> (if (cons? Args)
                          (let Arg (hd Args)
                            (let Rest (tl Args)
                              (if (variable? Arg)
                                  (let ArgType (if (cons? TypeList)
                                                  (hd TypeList)
                                                  [con zinc-value])
                                    (let TRest (if (cons? TypeList) (tl TypeList) [])
                                      (let R (tc-type-pat-zv-tag-args Rest TRest Sub)
                                        (if (tc-ok? R)
                                            (let Pair (tc-ok-subst-bindings R)
                                              (let Sub2 (hd Pair)
                                                (let Binds (hd (tl Pair))
                                                  [ok [Sub2 [[Arg ArgType] | Binds]]])))
                                            R))))
                                  (tc-type-pat-zv-tag-args Rest (if (cons? TypeList) (tl TypeList) []) Sub))))
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

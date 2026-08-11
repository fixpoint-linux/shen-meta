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
   [(intern "hd")      (tc-poly1 (tc-build-arrow [[app list [tvar 0]]] [tvar 0]))]
   [(intern "tl")      (tc-poly1 (tc-build-arrow [[app list [tvar 0]]] [app list [tvar 0]]))]
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
   \* Predicates *\
   [(intern "function?") (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "error?")    (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   [(intern "stream?")   (tc-poly1 (tc-build-arrow [[tvar 0]] [con boolean]))]
   \* Error handling *\
   [(intern "trap-error") (tc-poly2 (tc-build-arrow [[tvar 0] [arrow [con string] [tvar 0]]] [tvar 0]))]
   [(intern "simple-error") (tc-poly1 (tc-build-arrow [[con string]] [tvar 0]))]
   [(intern "error-to-string") (tc-poly1 (tc-build-arrow [[tvar 0]] [con string]))]
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
   [(intern "assoc")   (tc-poly2 (tc-build-arrow [[tvar 0] [app list [prod [tvar 0] [tvar 1]]]] [prod [tvar 0] [tvar 1]]))]
   \* Boolean ops *\
   [(intern "not")     (tc-mono (tc-build-arrow [[con boolean]] [con boolean]))]
   \* Identity/generic *\
   [(intern "ps")      (tc-poly1 (tc-build-arrow [[tvar 0]] [tvar 0]))]
   \* Length *\
   [(intern "length")  (tc-poly1 (tc-build-arrow [[app list [tvar 0]]] [con number]))]
   ])

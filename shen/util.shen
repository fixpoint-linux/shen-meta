(define id { A --> A }
  X -> X)

\* fresh-var: fresh symbol with prefix P, matching sys.kl gensym semantics —
   (gensym Y) -> Y1, Y2, ... sharing the shen.*gensym* counter via [prim set].
   MUST NOT compile to [prim gensym]: the C gensym primitive ignores its
   prefix and returns lowercase shen.gensym_N — not a variable — which makes
   debruijn (normalize.shen:145) (fail) on body references to gensym'd
   lambda/let params (breaks shen.lambda-function's curried wrappers and
   hence read-from-string of define forms).  Counter defaults to 0 when
   shen.*gensym* is unbound (pre-shen.initialise). *\
(define fresh-var { symbol --> symbol }
  P -> (let N (trap-error (value shen.*gensym*) (/. E 0))
         (let M (set shen.*gensym* (+ N 1))
           (intern (cn (str P) (str M))))))

(define newvar { --> symbol }
  -> (fresh-var (intern "V")))

(define index_h { A --> (list A) --> number --> number }
  X [H | Rest] C -> C where (= X H)
  X [_ | Rest] C -> (index_h X Rest (+ 1 C))
  _ _ _          -> -1)

(define idx { A --> (list A) --> number }
  X L -> (index_h X L 0))

(define intersperse { A --> (list A) --> (list A) }
  V []         -> []
  V [X]        -> [X]
  V [X | Rest] -> [X V | (intersperse V Rest)]
  _ _          -> [])

(define fold-append { (list A) --> (list (list A)) --> (list A) }
  A []      -> A
  A [H]     -> (fold-append (append A H) [])
  A [H | T] -> (fold-append (append A H) T)
  _ _       -> (simple-error "impossible"))

(define fold-str { (list string) --> string }
  [] -> ""
  [S] -> S
  [S | Rest] -> (cn S (fold-str Rest)))

(define defun->lambda { klambda --> klambda }
  [defun Name [] Body]           -> [lambda (newvar) Body]
  [defun Name [Arg] Body]        -> [lambda Arg Body]
  [defun Name [Arg | Args] Body] -> [lambda Arg (defun->lambda [defun Name Args Body])]
  _                              -> (simple-error "defun->lambda: invalid arg"))

\* dedupe-globals keeps the FIRST (front = newest = shen-load'd) occurrence of
   each name, matching the comment in serialize-reduced.shen.  The old version
   kept the LAST (back = oldest = host set-toplevel), which let curried
   host-compiled closures shadow the flat full-arity ones from shen-load,
   breaking the C VM (partial application). *\
(define dedupe-globals { (list (list symbol zinc-value)) --> (list (list symbol zinc-value)) }
  Table -> (dedupe-globals-h Table []))

(define dedupe-globals-h
  { (list (list symbol zinc-value)) --> (list symbol) --> (list (list symbol zinc-value)) }
  [] _ -> []
  [[N V] | R] Seen -> (if (element? N Seen)
                         (dedupe-globals-h R Seen)
                         [[N V] | (dedupe-globals-h R [N | Seen])]))

(define primitive? { symbol --> boolean }
  \* Single source: the generated primitive?-names list (from vm/prims.def via
     the Makefile gen-prims target) — set at C-VM runtime by vm_load_bundle and
     at bundle-build time by shen/prims-generated.shen.  MUST match types.shen.
     Hot prims first in prims.def so element? short-circuits on early matches. *\
  X -> (element? X (value primitive?-names)))

\* Zinc instruction keywords used as list constructors in zinc-c/zinc-t RHS.
   These must NOT be wrapped with [function ...] by debruijn. *\
(define instruction-keyword? { symbol --> boolean }
  \* Reordered: hot instruction heads first (access/global/prim/let are the
     most common zinc-c/zinc-t RHS constructors).  Pure membership. *\
  X -> (element? X [access global prim let number string symbol boolean
                    grab apply appterm cur cons label jmpf jmp
                    endlet pushmark mark error lambda absvector stream in out]))
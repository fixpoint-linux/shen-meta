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
  \* Reordered: hot prims first so element? short-circuits on early matches.
     cons/hd/tl are the heads of ~70K recorded-source cons cells; = and the
     arithmetic + comparison prims dominate the recorded bodies.  Order is
     semantically irrelevant (pure membership) but hugely affects compile cost.
     MUST stay in sync with types.shen. *\
  X -> (element? X [cons hd tl = + / * - number? > < >= <=
                    string? symbol? boolean? cons? absvector?
                    pos tlstr hdstr cn str string->n n->string
                    absvector address-> <-address emptylist
                    write-byte read-byte read-file-as-string open close function?
                    trap-error simple-error error-to-string intern
                    set value eval-kl get-time error? stream?
                    @p fst snd gensym variable? newvar
                    c-strlen char-code substring element?]))

\* Zinc instruction keywords used as list constructors in zinc-c/zinc-t RHS.
   These must NOT be wrapped with [function ...] by debruijn. *\
(define instruction-keyword? { symbol --> boolean }
  \* Reordered: hot instruction heads first (access/global/prim/let are the
     most common zinc-c/zinc-t RHS constructors).  Pure membership. *\
  X -> (element? X [access global prim let number string symbol boolean
                    grab apply appterm cur cons label jmpf jmp
                    endlet pushmark mark error lambda absvector stream in out]))
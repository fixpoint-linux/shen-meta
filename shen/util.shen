(define id { A --> A }
  X -> X)

(define newvar { --> symbol }
  -> (gensym (protect V)))

(define index_h { A --> (list A) --> number --> number }
  X [X | Rest] C -> C
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
  X -> (element? X [+ / * - trap-error simple-error error-to-string intern
                    set value number? > < >= <= string? pos tlstr hdstr cn str
                    string->n n->string absvector address-> <-address emptylist
                    absvector? cons? cons hd tl write-byte read-byte read-file-as-string open function?
                    close = eval-kl get-time symbol? boolean? error? stream?
                    @p fst snd gensym variable? newvar
                    c-strlen char-code substring]))

\* Zinc instruction keywords used as list constructors in zinc-c/zinc-t RHS.
   These must NOT be wrapped with [function ...] by debruijn. *\
(define instruction-keyword? { symbol --> boolean }
  X -> (element? X [access global grab let jmpf jmp label
                    cons symbol prim appterm number string boolean
                    cur endlet pushmark apply mark
                    error lambda absvector stream in out]))
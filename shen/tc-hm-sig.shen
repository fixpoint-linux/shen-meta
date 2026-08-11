(tc -)

\* tc-hm-sig.shen — Stage 4: signature parser for {A --> B} type sigs.
   Parses the sig form produced by shen-read-file:
   [(intern "{") ...content... (intern "}")] where content
   is a list of type expressions separated by -->.
   Safe-subset only; mirrors shen-kl-helpers.shen style. *\

(load "shen/tc-hm-types.shen")

\* ===== Helper: is a symbol uppercase? (used to detect type vars) ===== *\

(define tc-uppercase-symbol?
  { symbol --> boolean }
  S -> (let Name (str S)
         (if (= (strlen Name) 0)
             false
             (let Ch (string->n (pos Name 0))
               (and (>= Ch 65) (<= Ch 90))))))

\* ===== sig-tvar-counter: assign unique numbers to type var names ===== *\

(set tc-sig-tvar-counter 0)

\* ===== reset-sig-counter: reset before parsing a new sig ===== *\

(define tc-reset-sig-counter
  { --> (list number) }
  -> (do (%% set tc-sig-tvar-counter 0)
         []))

\* ===== sig-tvar: get or create a tvar number for a type var name =====
   Returns the tvar number (NOT a [tvar N] type). *\

(set tc-sig-tvar-map [])

(define tc-sig-tvar
  { symbol --> number }
  Name -> (let Pair (tc-assoc Name (%% value tc-sig-tvar-map))
            (if (tc-empty? Pair)
                (let N (%% value tc-sig-tvar-counter)
                  (do (%% set tc-sig-tvar-counter (+ N 1))
                      (%% set tc-sig-tvar-map [[Name N] | (%% value tc-sig-tvar-map)])
                      N))
                (hd (tl Pair)))))

\* ===== parse-sig-type: parse a single type expression from sig =====
   number    → [con number]
   string    → [con string]
   symbol    → [con symbol]
   boolean   → [con boolean]
   zinc-value → [con zinc-value]
   zinc-code  → [con zinc-code]
   klambda    → [con klambda]
   absvector  → [con absvector]
   stream     → [con stream]
   A (uppercase) → [tvar (tc-sig-tvar A)]
   (list T)  → [app list (tc-parse-sig-type T)]
   otherwise → error *\

(define tc-parse-sig-type
  { expr --> type }
  X -> (if (symbol? X)
            (let S X
              (if (= S (intern "number"))
                  [con number]
                  (if (= S (intern "string"))
                      [con string]
                      (if (= S (intern "symbol"))
                          [con symbol]
                          (if (= S (intern "boolean"))
                              [con boolean]
                              (if (= S (intern "zinc-value"))
                                  [con zinc-value]
                                  (if (= S (intern "zinc-code"))
                                      [con zinc-code]
                                      (if (= S (intern "klambda"))
                                          [con klambda]
                                          (if (= S (intern "absvector"))
                                              [con absvector]
                                              (if (= S (intern "stream"))
                                                  [con stream]
                                                  (if (tc-uppercase-symbol? S)
                                                      [tvar (tc-sig-tvar S)]
                                                      [con X])))))))))))
            (if (cons? X)
                (if (tc-sig-arrow? X)
                    (tc-parse-sig-arrow X)
                    (tc-parse-sig-app X))
                [con error])))

\* ===== sig-arrow?: does a type expression contain --> (a nested arrow)?
   e.g. [klambda --> klambda] from (klambda --> klambda).  If so it must be
   parsed by tc-parse-sig-arrow, not tc-parse-sig-app (which only handles
   (list T)).  Scans the flat list only (does not descend into nested lists,
   which tc-parse-sig-type reaches recursively). *\

(define tc-sig-arrow?
  { expr --> boolean }
  X -> (if (cons? X)
           (if (= (hd X) (intern "-->"))
               true
               (tc-sig-arrow? (tl X)))
           false))

\* ===== parse-sig-app: parse (list T) type application ===== *\

(define tc-parse-sig-app
  { expr --> type }
  X -> (if (and (cons? X) (= (hd X) (intern "list")))
           (let Rest (tl X)
             (if (cons? Rest)
                 (let T (hd Rest)
                   [app list (tc-parse-sig-type T)])
                 (simple-error "parse-sig-app: (list) missing type argument")))
           (simple-error (cn "parse-sig-app: unknown type app " (str X)))))

\* ===== parse-sig-arrow: parse A --> B --> C into curried arrow =====
   The sig content is: [Arg1 --> Arg2 --> ... --> Ret].
   We split on --> and build curried arrows. *\

(define tc-parse-sig-arrow
  { (list expr) --> type }
  [Arg] -> (tc-parse-sig-type Arg)
  [--> | Rest] -> (tc-parse-sig-arrow Rest)
  [Arg --> | Rest] -> (let ArgType (tc-parse-sig-type Arg)
                        (let RetType (tc-parse-sig-arrow Rest)
                          [arrow ArgType RetType]))
  X -> (simple-error (cn "parse-sig-arrow: malformed sig " (str X))))

\* ===== parse-sig: parse a full sig form [(intern "{") ... (intern "}")] =====
   Returns a forall-quantified scheme, or just the type if monomorphic. *\

(define tc-parse-sig
  { expr --> type }
  Sig -> (let Stripped (tc-strip-sig-braces Sig)
           (do (str Sig)
               (str Stripped)
               (%% set tc-sig-tvar-map [])
               (tc-reset-sig-counter)
               (let Parsed (tc-parse-sig-arrow Stripped)
                 (let TVars (tc-collect-sig-tvars Parsed)
                   (let TVarsSorted (tc-sort-nums TVars)
                     (if (tc-empty? TVarsSorted)
                         Parsed
                         (let Reversed (tc-reverse TVarsSorted)
                           [forall Reversed Parsed]))))))))

\* ===== strip-sig-braces: remove { and } from the sig form =====
   Input:  [{ --> } number number] or [{ number --> number }]
   Output: [number --> number] *\

(define tc-strip-sig-braces
  { expr --> (list expr) }
  X -> (if (cons? X)
           (if (= (hd X) (intern "{"))
               (tc-strip-sig-braces-h (tl X))
               X)
           X))

(define tc-strip-sig-braces-h
  { (list expr) --> (list expr) }
  [] -> []
  [H | T] -> (if (= H (intern "}"))
                 []
                 [H | (tc-strip-sig-braces-h T)]))

\* ===== collect-sig-tvars: collect all tvar numbers used in a type =====
   Same as tc-free-tvars but we don't subtract foralls (pre-quantification). *\

(define tc-collect-sig-tvars
  { type --> (list number) }
  T -> (let Tag (tc-type-tag T)
         (if (= Tag tvar)
             [(tc-tvar-id T)]
             (if (= Tag con)
                 []
                 (if (= Tag arrow)
                     (tc-union-nums (tc-collect-sig-tvars (tc-arrow-dom T))
                                    (tc-collect-sig-tvars (tc-arrow-cod T)))
                     (if (= Tag app)
                         (tc-collect-sig-tvars (tc-app-arg T))
                         (if (= Tag prod)
                             (tc-union-nums (tc-collect-sig-tvars (tc-prod-fst T))
                                            (tc-collect-sig-tvars (tc-prod-snd T)))
                             (if (= Tag forall)
                                 (tc-diff-nums (tc-collect-sig-tvars (tc-forall-body T))
                                               (tc-forall-vars T))
                                 []))))))))

\* ===== sort-nums: insertion sort a list of numbers ===== *\

(define tc-sort-nums
  { (list number) --> (list number) }
  [] -> []
  [X | Xs] -> (tc-insert-num X (tc-sort-nums Xs)))

(define tc-insert-num
  { number --> (list number) --> (list number) }
  N [] -> [N]
  N [X | Xs] -> (if (< N X)
                    [N X | Xs]
                    [X | (tc-insert-num N Xs)]))

\* ===== sig-type->str: readable form of a parsed sig type ===== *\

(define tc-sig-type->str
  { type --> string }
  T -> (tc-type->str T))

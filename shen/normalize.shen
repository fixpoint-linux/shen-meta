\* https://github.com/Shen-Language/wiki/wiki/KLambda#equivalent-forms *\
(load "shen/util.shen")
(load "shen/types.shen")

(define map-kmacros { (list klambda) --> (list klambda) }
  []      -> []
  [H | T] -> [(kmacros H) | (map-kmacros T)])

(define kmacros { klambda --> klambda }
  [freeze X]                                   -> [lambda (newvar) (kmacros X)]
  [thaw X]                                     -> [(kmacros X) 0]
  \* Lambda param lists: unwrap single / curry multiple.  Raw KLambda from the
     reader carries (lambda (X ...) Body) with a param LIST; the compiler core
     (debruijn/zinc) expects the single-binding form (lambda X Body).  Without
     these rules the generic [X | Y] rule macro-expands INSIDE the param list
     ([X] -> [X 0] pollution) and debruijn then scopes the whole param list as
     ONE element, so body references never resolve and the interp dies with
     "interp: unknown prim" on the first primitive in the body.  Must precede
     the generic [X | Y] rule. *\
  [lambda [X] Y]                                -> [lambda X (kmacros Y)]
  [lambda [X | Ps] Y]                           -> [lambda X (kmacros [lambda Ps Y])]
  [lambda [] Y]                                 -> [lambda (newvar) (kmacros Y)]
  [and]                                        -> true
  [and X]                                      -> (kmacros X)
  [and X Y | Z]                                -> (kmacros [if (kmacros X) (kmacros [and Y | Z]) false])
  [or]                                         -> false
  [or X]                                       -> (kmacros X)
  [or X Y | Z]                                 -> (kmacros [if (kmacros X) true (kmacros [or Y | Z])])
  [cond [X Y] | Rest]                          -> (kmacros [if (kmacros X) (kmacros Y) (kmacros [cond | Rest])])
  [cond]                                       -> [simple-error "No condition was true"]
  [trap-error B E]                             -> [trap-error (kmacros [lambda (newvar) (kmacros B)]) (kmacros E)]
  [if true X Y]                                -> (kmacros X)
  [if false X Y]                               -> (kmacros Y)
  [do X]                                       -> (kmacros X)
  [do X | Y]                                   -> [let (kmacros (newvar)) (kmacros X) (kmacros [do | Y])]
  [number? [type X number]]                    -> true
  [symbol? [type X symbol]]                    -> true
  [string? [type X string]]                    -> true
  [boolean? [type X boolean]]                  -> true
  [cons? [type X [list _]]]                    -> true
  [simple-error [type X string]]               -> [%% simple-error X]
  [get-time [type unix symbol]]                -> [%% get-time unix]
  [get-time [type run symbol]]                 -> [%% get-time run]
  [close [type X stream]]                      -> [%% close X]
  [read-byte [type X stream]]                  -> [%% read-byte X]
  [absvector [type X number]]                  -> [%% absvector X]
  [n->string [type X number]]                  -> [%% n->string X]
  [string->n [type X string]]                  -> [%% string->n X]
  [value [type X symbol]]                      -> [%% value X]
  [intern [type "true" string]]                -> true
  [intern [type "false" string]]               -> false
  [intern [type X string]]                     -> [%% intern X]
  [error-to-string [type X exception]]         -> [%% error-to-string X]
  [open [type X string] [type in symbol]]      -> [%% open X in]
  [open [type X string] [type out symbol]]     -> [%% open X out]
  [write-byte [type N number] [type S stream]] -> [%% write-byte N S]
  [cn [type S string] [type S1 string]]        -> [%% cn S S1]
  [pos [type S string] [type N number]]        -> [%% pos S N]
  [<= [type N number] [type N1 number]]        -> [%% <= N N1]
  [>= [type N number] [type N1 number]]        -> [%% >= N N1]
  [< [type N number] [type N1 number]]         -> [%% < N N1]
  [> [type N number] [type N1 number]]         -> [%% > N N1]
  [set [type S symbol] Y]                      -> [%% set S Y]
  [- [type N number] [type N1 number]]         -> [%% - N N1]
  [* [type N number] [type N1 number]]         -> [%% * N N1]
  [/ [type N number] [type N1 number]]         -> [%% / N N1]
  [+ [type N number] [type N1 number]]         -> [%% + N N1]
  [type X Y]                                   -> X
  [X]                                          -> [X 0]
  [X Y]                                        -> [(kmacros X) (kmacros Y)]
  [X | Y]                                      -> [(kmacros X) | (map-kmacros Y)]
  []                                           -> [%% emptylist 0]
  X                                            -> X)

\* http://matt.might.net/articles/a-normalization/ *\
(define atomic? { A --> boolean }
  X  -> true where (number? X)
  X  -> true where (symbol? X)
  X  -> true where (string? X)
  X  -> true where (boolean? X)
  X  -> true where (variable? X)
  _  -> false)

\* normalize-term seeds the normalization.  normalize/normalize-name/
   normalize-names are now DIRECT-STYLE (no K : (klambda --> klambda)
   continuation threaded through /. lambdas) — each sub-normalization result
   is bound to a name and threaded directly.  This is SEMANTICALLY-EQUIVALENT
   to the prior CPS form (verified by self-hosting):
   both compile to correct, equal code.  Note it is NOT byte-identical for
   nested lets — CPS hoisted inner lets to left-nested form, the direct style
   preserves right-nested source order; both evaluate identically.  The
   benefit: no closure-allocating continuations, so the whole front-end is
   first-order and can be compiled statically. *\
(define normalize-term { klambda --> klambda } Exp -> (normalize Exp))

(define flatten-%%app { klambda --> (list klambda) --> klambda }
  T Ts -> (if (and (cons? T) (= (hd T) %%))
              [%% | (append (tl T) Ts)]
              [T | Ts]))

(define normalize { klambda --> klambda }
  \* Shen 41.2: [[fn %%] X] -> bare %% call (no args) *\
  [[fn %%] X]          -> [%% X] where (symbol? X)
  \* Shen 41.2: [[[fn %%] X] | Args] -> %% call with args. 
     Must be BEFORE [F | E] to intercept the full expression before it's split *\
  [[[fn %%] X] | Args] -> [%% X | (normalize-names Args)] where (symbol? X)
  \* Shen 41.2: [fn X] -> function reference *\
  [fn X]               -> [function X] where (symbol? X)
  [lambda Param Body]  -> [lambda Param (normalize-term Body)]
  [let V X Y]          -> [let V (normalize X) (normalize Y)]
  [if X Y Z]           -> [if (normalize-name X) (normalize-term Y) (normalize-term Z)]
  [set S E]            -> (let T (normalize-name E)
                             [let (newvar) [%% set S T] T])
  \* Bare primitive (Shen 41.2 ps strips %% from unary primitives) *\
  [F | E]              -> [%% F | (normalize-names E)] where (primitive? F)
  [F | E]              -> (let T (normalize-name F)
                             (let Ts (normalize-names E)
                               (flatten-%%app T Ts)))
  X                    -> X where (atomic? X))

(define normalize-name { klambda --> klambda }
  E -> (let Aexp (normalize E)
         (if (atomic? Aexp)
             Aexp
             (if (and (cons? Aexp) (symbol? (hd Aexp)))
                 Aexp
                 (let T (newvar)
                   [let T Aexp T])))))

(define normalize-names { klambda --> (list klambda) }
  Exps -> (if (empty? Exps)
              []
              (let T (normalize-name (hd Exps))
                (let Ts (normalize-names (tl Exps))
                  [T | Ts]))))

(define map-debruijn { (list symbol) --> (list klambda) --> (list klambda) }
  Scope []      -> []
  Scope [H | T] -> [(debruijn Scope H) | (map-debruijn Scope T)])

(define debruijn { (list symbol) --> klambda --> klambda }
  Scope [let X Y Z]  -> [let (debruijn Scope Y) (debruijn [X | Scope] Z)]
  Scope [lambda X Y] -> [lambda (debruijn [X | Scope] Y)]
  Scope [if X Y Z]   -> [if (debruijn Scope X) (debruijn Scope Y) (debruijn Scope Z)]
  Scope [%% X Y]     <- (if (primitive? X) [X (debruijn Scope Y)] (fail)) where (symbol? X)
  Scope [%% X | Y]   <- (if (primitive? X) [X | (map-debruijn Scope Y)] (fail)) where (symbol? X)

  \* [function X] is a KLambda global reference — must NOT be wrapped
     in another [function ...].  Without this rule, debruijn wraps the
     'function' keyword itself, producing [[function function] X] which
     zinc-c compiles to [global function] instead of [global X]. *\
  Scope [function X] -> [function X] where (symbol? X)

  \* Zinc instruction keywords used as list constructors in zinc-c/zinc-t
     RHS must NOT be wrapped with [function ...].  Without these rules,
     [prim F] becomes [[function prim] F] → [global prim] → crash. *\
  Scope [K]         -> [K] where (instruction-keyword? K)
  Scope [K X]       -> [K (debruijn Scope X)] where (instruction-keyword? K)
  Scope [K | X]     -> [K | (map-debruijn Scope X)] where (instruction-keyword? K)

  Scope [X Y]        <- (if (not (element? X Scope)) [[function X] (debruijn Scope Y)] (fail)) where (symbol? X)
  Scope [X | Y]      <- (if (not (element? X Scope)) [[function X] | (map-debruijn Scope Y)] (fail)) where (symbol? X)
  Scope [X Y]        -> [(debruijn Scope X) (debruijn Scope Y)]
  Scope [X | Y]      -> [(debruijn Scope X) | (map-debruijn Scope Y)]
  Scope X            <- (if (element? X Scope) [lookup (idx X Scope)] [symbol X]) where (variable? X)
  Scope X            <- (if (and (not (variable? X)) (symbol? X) (not (element? X Scope))) [symbol X] (fail))
  Scope X            -> X)
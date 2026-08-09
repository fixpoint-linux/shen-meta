\* https://caml.inria.fr/pub/papers/xleroy-zinc.pdf *\
(define map-zinc-c { klambda --> (list zinc-code) }
  []      -> []
  [H | T] -> [(zinc-c H) | (map-zinc-c T)])

\* Compile a list of klambda args left-to-right (caller passes them pre-reversed)
   threading a Tail accumulator.  Produces code_A1 ++ code_A2 ++ ... ++ Tail. *\
(define zinc-c-args { (list klambda) --> zinc-code --> zinc-code }
  []       Tail -> Tail
  [A | R]  Tail -> (zinc-c-tail A (zinc-c-args R Tail)))

(define zinc-t-tail { klambda --> zinc-code --> zinc-code }
  [lookup X]   Tail -> [access X | Tail] where (number? X)
  [function X] Tail -> [global X | Tail] where (symbol? X)
  \* Single-element symbol list [K] is a literal value, not a call *\
  [K]          Tail -> [symbol K | Tail] where (symbol? K)
  [lambda X]   Tail -> [grab | (zinc-t-tail X Tail)]
  [let X Y]    Tail -> (zinc-c-tail X [let | (zinc-t-tail Y Tail)])
  [if X Y Z]   Tail -> (let F (gensym l) (let E (gensym l)
                        (zinc-c-tail X [jmpf F | (zinc-t-tail Y [jmp E | [label F | (zinc-t-tail Z [label E | Tail])]])])))
  [symbol X]   Tail -> [symbol X | Tail] where (symbol? X)
  \* %% escapes: (%% F A1..An) compiles directly to a primitive dispatch. *\
  [%% F A]     Tail -> (zinc-c-tail A [prim F | Tail]) where (and (symbol? F) (primitive? F))
  [%% F | Args] Tail -> (zinc-c-args (reverse (tl Args)) (zinc-c-tail (hd Args) [prim F | Tail]))
                   where (and (symbol? F) (primitive? F))
  [F A]        Tail <- (if (primitive? F) (zinc-c-tail A [prim F | Tail]) (fail)) where (symbol? F)
  [F | Args]   Tail <- (if (primitive? F)
                        (zinc-c-args (reverse (tl Args)) (zinc-c-tail (hd Args) [prim F | Tail]))
                        (fail)) where (symbol? F)
  [F | Args]   Tail -> [pushmark | (zinc-c-args (reverse Args) (zinc-c-tail F [appterm | Tail]))]
  X            Tail -> [boolean X | Tail] where (boolean? X)
  X            Tail -> [number X | Tail] where (number? X)
  X            Tail -> [string X | Tail] where (string? X)
  []           Tail -> Tail
  _            Tail -> (simple-error "zinc-t: unknown expression"))

(define zinc-c-tail { klambda --> zinc-code --> zinc-code }
  [lookup X]   Tail -> [access X | Tail] where (number? X)
  [function X] Tail -> [global X | Tail] where (symbol? X)
  \* Single-element symbol list [K] is a literal value, not a call *\
  [K]          Tail -> [symbol K | Tail] where (symbol? K)
  [lambda X]   Tail -> [cur | [(zinc-t-tail X [return]) | Tail]]
  [let X Y]    Tail -> (zinc-c-tail X [let | (zinc-c-tail Y [endlet | Tail])])
  [if X Y Z]   Tail -> (let F (gensym l) (let E (gensym l)
                        (zinc-c-tail X [jmpf F | (zinc-c-tail Y [jmp E | [label F | (zinc-c-tail Z [label E | Tail])]])])))
  [symbol X]   Tail -> [symbol X | Tail] where (symbol? X)
  \* %% escapes: (%% F A1..An) compiles directly to a primitive dispatch,
     bypassing the global table / safe wrappers (matches C VM's [prim F]). *\
  [%% F A]     Tail -> (zinc-c-tail A [prim F | Tail]) where (and (symbol? F) (primitive? F))
  [%% F | Args] Tail -> (zinc-c-args (reverse (tl Args)) (zinc-c-tail (hd Args) [prim F | Tail]))
                   where (and (symbol? F) (primitive? F))
  [F A]        Tail <- (if (primitive? F) (zinc-c-tail A [prim F | Tail]) (fail)) where (symbol? F)
  [F | Args]   Tail <- (if (primitive? F)
                        (zinc-c-args (reverse (tl Args)) (zinc-c-tail (hd Args) [prim F | Tail]))
                        (fail)) where (symbol? F)
  [F | Args]   Tail -> [pushmark | (zinc-c-args (reverse Args) (zinc-c-tail F [apply | Tail]))]
  X            Tail -> [boolean X | Tail] where (boolean? X)
  X            Tail -> [number X | Tail] where (number? X)
  X            Tail -> [string X | Tail] where (string? X)
  []           Tail -> Tail
  _            Tail -> (simple-error "zinc-c: unknown expression"))

(define zinc-c { klambda --> zinc-code }
  E -> (zinc-c-tail E []))

(define zinc-t { klambda --> zinc-code }
  E -> (zinc-t-tail E []))
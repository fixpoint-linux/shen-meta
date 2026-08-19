(load "shen/normalize.shen")
(load "shen/util.shen")
(load "shen/zinc.shen")

\* Defun table - association list of [name . closure] pairs *\
(set global-table [])

\* Values table - separate association list of [name . value] pairs.
   The metacircular interp's value/set resolve through these two tables:
   global-table for defuns (read by lookup-global), value-table for
   runtime (set X V) bindings (read by interp-value). *\
(set value-table [])

(define lookup-global { symbol --> zinc-value }
  G -> (let Table (value global-table)
         (let Pair (assoc G Table)
           (if (empty? Pair)
               (simple-error (cn "global not found: " (str G)))
               (hd (tl Pair))))))

\* interp-value: resolve (value S) in interpreted code.  Search the Shen
   value-table (namespace 2) first; if not found there, fall through to the
   C values table (namespace 1) via %% value.  %% value / %% set reach the
   C primitives directly (the Shen value-table list is itself stored as the
   C values-table key "value-table"). *\
(define interp-value { symbol --> zinc-value }
  S -> (let Pair (assoc S (%% value value-table))
         (if (empty? Pair)
             (%% value S)
             (hd (tl Pair)))))

(define interp-set { symbol --> zinc-value --> zinc-value }
  S V -> (do (%% set value-table (cons [S V] (%% value value-table)))
             V))

\* Reference implementation, this is basically a transliteration
  of the rules in the paper *\
(define lookup { number --> (list zinc-value) --> zinc-value }
  0 [X | _] -> X
  X [_ | Z] -> (lookup (- X 1) Z)
  _ _       -> (simple-error "failed lookup"))

(define interp-jmp { zinc-code --> symbol --> zinc-code }
  [label L | C] K -> C where (= K L)
  [C1 | C] L      -> (interp-jmp C L)
  _ _             -> (simple-error "failed jump"))

(define extract-kl { zinc-value --> klambda }
  [cons]      -> []
  [cons X Y]  -> (cons (extract-kl X) (extract-kl Y))
  [number X]  -> X
  [symbol X]  -> X
  [string X]  -> X
  [boolean X] -> X
  [lambda C E] -> [lambda C E]
  [error X]    -> X
  [absvector X] -> X
  [stream in X] -> X
  [stream out X] -> X
  mark         -> []
  X            -> X)



(define collect-apply-args { (list zinc-value) --> number --> (list zinc-value) }
  \* Hit V1 before mark: V1 is the enclosing context's pending value (the
     accumulator at pushmark time under RTL arg evaluation).  Preserve it into
     the saved stack — discarding it loses the enclosing call's in-flight arg. *\
  [V1 V2 | S] N -> [[] [V1 | S]] where (= V2 mark)
  \* At A0 position but N > 64: too many args pushed before mark *\
  [V1 V2 | S] N -> (simple-error "too many args (>64)") where (> N 64)
  \* Collect V1 as an arg, recurse with incremented counter *\
  [V1 | S] N -> (let Result (collect-apply-args S (+ N 1))
                [[V1 | (hd Result)] | (tl Result)])
  \* Empty stack — no mark found, bytecode is malformed *\
  [] _ -> (simple-error "missing pushmark"))

(define zinc-arity { (list zinc-instruction) --> number }
  \* The [cur] that created this closure wrapped a 1-param lambda whose
     parameter is bound by APPLY (into env), not by a grab.  Every closure
     therefore has arity = (leading grabs in C1) + 1.  Without the +1 a
     3-arg defun reports A=2 and a 0-arg defun (defun->lambda gives
     [lambda newvar Body]) reports A=0 while its dummy arg is the newvar. *\
  [grab | C] -> (+ 1 (zinc-arity C))
  _ -> 1)

(define count-args { (list zinc-value) --> number --> number }
  [] Acc -> Acc
  [_ | Args] Acc -> (count-args Args (+ 1 Acc)))

\* element?-h: list membership for the [prim element?] interp rule, matching
   the C primitive's semantics (deep_equal against TOP-LEVEL elements).
   The interp's values are TAGGED: a list (H1 H2 ...) is [cons H1 [cons H2
   [cons]]] — the `cons` tag symbol occupies position 0 of every cell.  The
   old flat walk (X [H | T]) iterated the tag symbols and the SUBLISTS as if
   they were elements, so membership only matched by accident on 1-element
   lists — e.g. shen.misc? (element? on a 19-element literal chain) always
   returned false, breaking shen.alpha? and the whole symbol parser.  Walk
   the tagged pairs instead: head H, recurse on tail Tl. *\
(define element?-h { zinc-value --> (list zinc-value) --> boolean }
  X [cons H Tl] -> true where (= X H)
  X [cons H Tl] -> (element?-h X Tl)
  _ _           -> false)

(define drop-grabs { number --> (list zinc-instruction) --> (list zinc-instruction) }
  N C -> C where (= N 0)
  N [grab | C] -> (drop-grabs (- N 1) C)
  N _ -> (simple-error "drop-grabs: not enough grabs"))

\* interp-trap-body: the [prim trap-error] rule's protected-body evaluation,
   extracted into a shallow top-level defun.  The trap-error body is wrapped
   by kmacros (normalize.shen) into a native thunk [lambda (newvar) (kmacros B)]
   capturing B's free variables by absolute env index.  Inside interp's
   97-rule cond chain those indices are computed from the STATIC nesting
   depth (~72), but the flat jumped code interp's rule compiles to has a
   runtime env of only 5 slots (the params C A E S R) — the thunk then reads
   env[68..71] out of bounds (lookup_env's number-0 sentinel) and crashes
   the first interpreted (put ...) call during shen.initialise-environment.
   A top-level helper has no rule-chain nesting, so its thunk captures its
   own 4 params at small correct indices.  See handoff-shenos-init-glm. *\
(define interp-apply-handler
  { zinc-value --> zinc-value --> zinc-value }
  \* The C trap-error primitive passes the caught error to the handler as a
     RAW C error value (VAL_ERROR).  The interp represents errors as the
     tagged form [error X], which is what [prim error-to-string] / [prim error?]
     pattern-match on.  Without this wrap, error-to-string falls through to
     the "interp: unknown prim" catch-all and the REPL prints a bogus error
     instead of the real message. *\
  [lambda HC HE] Err -> (interp HC [lambda HC HE] [[error Err] | HE] [] []))

(define interp-trap-body
  { zinc-code --> (list zinc-value) --> (list zinc-value) --> (list zinc-value) --> zinc-value }
  C1 E1 S R -> (let H (hd S)
                \* The thunk body is a cur'd lambda whose code ends with a
                   trailing `return` (zinc-c-tail appends [return] to every
                   non-tail lambda).  Run it with a FRESH return stack [] —
                   passing the live R would let that trailing return pop the
                   ENCLOSING call's frame, replaying the caller's continuation
                   (the value was computed twice: e.g. shen.app's
                   (cn (shen.arg->str X Z) Y) ran prim cn twice -> "foo::").
                   Matches the C VM, whose trap-error primitive executes the
                   thunk via a fresh vm_exec_env frame stack.  H is captured
                   BEFORE, and R is unused by the body — it is kept in the
                   signature for the [prim trap-error] rule's shape. *\
                (trap-error (interp C1 [lambda C1 E1] [cons | E1] S [])
                            (lambda Err (interp-apply-handler H Err)))))

(define interp { zinc-code --> zinc-value --> (list zinc-value) --> (list zinc-value) --> (list zinc-value) --> zinc-value }
  [access N | C] A E S R                                        -> (interp C (lookup N E) E [A | S] R)
  [global G | C] A E S R                                        -> (interp C (lookup-global G) E [A | S] R)
  \* jmpf consumes the branch condition (in A) without producing a new value.
     Under push-OLD-acc the next value op would re-push that stale condition
     onto the stack, corrupting the enclosing call's arg list (lands as a cn
     right arg -> 'true'/'false' garbage -> infinite recursion in shen.app).
     The C VM pops the condition (zincvm.c OP_JMPF).  Mirror that: pop the
     enclosing pending value V (stack top, pushed by the condition's first
     value op) back into acc, consuming the condition.  [boolean false] rules
     MUST precede the general A rules so false jumps. *\
  [jmpf L | C] [boolean false] E [V | S] R                       -> (interp (interp-jmp C L) V E S R)
  [jmpf L | C] A E [V | S] R                                     -> (interp C V E S R)
  [jmpf L | C] [boolean false] E [] R                            -> (interp (interp-jmp C L) [cons] E [] R)
  [jmpf L | C] A E [] R                                          -> (interp C [cons] E [] R)
  [jmp L | C] A E S R                                           -> (interp (interp-jmp C L) A E S R)
  [label L | C] A E S R                                         -> (interp C A E S R)
  [apply | C] [lambda C1 E1] E S R ->
    (let Collected (collect-apply-args S 0)
      (let Args (hd Collected)
        (let Rest (hd (tl Collected))
          (let A (zinc-arity C1)
            (let N (count-args Args 0)
              (if (= N A)
                  (interp C1 [lambda C1 E1] (append (reverse Args) E1) [] [[C E Rest] | R])
                  (if (< N A)
                      (interp C [lambda (drop-grabs N C1) (append (reverse Args) E1)] E Rest R)
                      (simple-error "apply: too many args"))))))))
  \* Appterm — tail call with return frame: collect all args up to mark.
     A tail call is the LAST expression of the caller's body: its result
     returns to the CALLER'S CALLER (C_call/E_call) with the ORIGINAL saved
     stack S_saved.  The current leftover (Rest above the mark) belongs to
     the dying frame — it must be DISCARDED, not swapped into the frame.
     Swapping it in (the old behaviour) replaced the caller's real pending
     values with the dead push-OLD-acc artifact (the entry closure), so the
     caller's continuation popped a [lambda ...] closure where it expected
     its own argument — e.g. shen.app's (cn (shen.arg->str X Z) Y) got the
     arg->str closure as cn's right arg instead of Y.  Matches the C VM's
     OP_APPTERM, which reuses the frame and keeps the caller's saved stack. *\
  [appterm | C] [lambda C1 E1] E S [[C_call E_call S_saved] | R] ->
    (let Collected (collect-apply-args S 0)
      (let Args (hd Collected)
        (if (empty? Args)
            (simple-error "appterm zero args")
            (let A (zinc-arity C1)
              (let N (count-args Args 0)
                (if (= N A)
                    (interp C1 [lambda C1 E1] (append (reverse Args) E1) [] [[C_call E_call S_saved] | R])
                    (if (< N A)
                        (interp C_call [lambda (drop-grabs N C1) (append (reverse Args) E1)] E_call S_saved R)
                        (simple-error "appterm: too many args"))))))))
  \* Appterm — tail call at top level: collect all args up to mark *\
  [appterm | C] [lambda C1 E1] E S [] ->
    (let Collected (collect-apply-args S 0)
      (let Args (hd Collected)
        (if (empty? Args)
            (simple-error "appterm zero args")
            (let A (zinc-arity C1)
              (let N (count-args Args 0)
                (if (= N A)
                    (interp C1 [lambda C1 E1] (append (reverse Args) E1) [] [])
                    (if (< N A)
                        [lambda (drop-grabs N C1) (append (reverse Args) E1)]
                        (simple-error "appterm: too many args"))))))))
  [pushmark | C] A E S R                                        -> (interp C A E [mark | S] R)
  [cur C1 | C] A E S R                                          -> (interp C [lambda C1 E] E [A | S] R)
  \* Grab: with stack isolation, args are already in env. Empty stack = no-op. *\
  [grab | C] A E [] R                                              -> (interp C A E [] R)
  \* Grab with value: bind it (curried partial application fallback) *\
  [grab | C] A E [V | S] R                                      -> (interp C A [V | E] S R)
  \* Return: restore caller's code, env, and saved stack. Return value in A. *\
  [return | C] A E S [[C_caller E_caller S_saved] | R] ->
    (interp C_caller A E_caller S_saved R)
  \* Return at top level: just return the accumulator *\
  [return | C] A E S [] -> A
  \* let binds the let-value A (old acc) into env but, like jmpf, consumes A
     without producing a new value; under push-OLD-acc the next value op would
     re-push the let-value onto the stack, corrupting the enclosing call's arg
     list (zinc.shen:43 emits non-tail let, so let CAN be a call argument).
     Pop the enclosing pending value V (stack top) back into acc. *\
  [let | C] A E [V | S] R                                         -> (interp C V [A | E] S R)
  [let | C] A E [] R                                              -> (interp C [cons] [A | E] [] R)
  [endlet | C] A [V | E] S R                                    -> (interp C A E S R)
  [number N | C] A E S R                                        -> (interp C [number N] E [A | S] R)
  [string Ss | C] A E S R                                       -> (interp C [string Ss] E [A | S] R)
  [symbol Ss | C] A E S R                                       -> (interp C [symbol Ss] E [A | S] R)
  [boolean B | C] A E S R                                       -> (interp C [boolean B] E [A | S] R)
  [prim emptylist | C] [number 0] E S R                         -> (interp C [cons] E S R)
  [prim cn | C] A E [mark | S] R                                 -> (interp [prim cn | C] A E S R)
  [prim cn | C] mark E S R                                       -> (interp [prim cn | C] [cons] E S R)  
  [prim cn | C] [string A] E [[string A1] | S] R                -> (interp C [string (cn A A1)] E S R)
  [prim cn | C] A E [A1 | S] R                                   -> (interp C [string (cn (extract-kl A) (extract-kl A1))] E S R)
  [prim symbol? | C] [symbol _] E S R                           -> (interp C [boolean true] E S R)
  [prim symbol? | C] A E S R                                    -> (interp C [boolean false] E S R)
  [prim boolean? | C] [boolean _] E S R                         -> (interp C [boolean true] E S R)
  [prim boolean? | C] A E S R                                   -> (interp C [boolean false] E S R)
  [prim stream? | C] [stream in _] E S R                        -> (interp C [boolean true] E S R)
  [prim stream? | C] [stream out _] E S R                       -> (interp C [boolean true] E S R)
  [prim stream? | C] A E S R                                    -> (interp C [boolean true] E S R) where (stream? A)
  [prim stream? | C] A E S R                                    -> (interp C [boolean false] E S R)
  [prim get-time | C] [symbol A] E S R                          -> (interp C [number (get-time A)] E S R)
  [prim eval-kl | C] A E S R                                    -> (interp C (toplevel-interp (kl->zinc (extract-kl A))) E S R)
  [prim close | C] [stream in A] E S R                          -> (interp C (do (close A) [cons]) E S R)
  [prim close | C] [stream out A] E S R                         -> (interp C (do (close A) [cons]) E S R)
  [prim close | C] A E S R                                      -> (interp C (do (close A) [cons]) E S R) where (stream? A)
  [prim read-byte | C] [stream in A] E S R                      -> (interp C [number (read-byte A)] E S R)
  [prim read-byte | C] A E S R                                  -> (interp C [number (read-byte A)] E S R) where (stream? A)
  [prim tl | C] [cons _ A] E S R                                -> (interp C A E S R)
  [prim hd | C] [cons A _] E S R                                -> (interp C A E S R)
  [prim cons? | C] [cons _ _] E S R                             -> (interp C [boolean true] E S R)
  \* [cons] is the TAGGED EMPTY LIST ().  KLambda (cons? ()) is false — the
     OS parsers guard every (hd V)/(head V) with (cons? V), so answering true
     here sends them head/tl of () ("interp: unknown prim - hd" during
     shen.<digit> — the read-from-string parse failure).  A real 1-element
     semantic list (a) is [cons a [cons]] — 2 elements — matched by the rule
     above.  Only the empty list is the 1-element [cons]. *\
  [prim cons? | C] A E S R                                      -> (interp C [boolean false] E S R)
  \* element?: deep_equal list membership (matches C primitive).  Leftmost arg
     (needle) is the accumulator, rightmost (list) is on the stack. *\
  [prim element? | C] X E [L | S] R                            -> (interp C [boolean (element?-h X L)] E S R)
  [prim absvector | C] [number A] E S R                         -> (interp C [absvector (absvector A)] E S R)
  [prim absvector? | C] [absvector _] E S R                     -> (interp C [boolean true] E S R)
  [prim absvector? | C] A E S R                                 -> (interp C [boolean false] E S R)
  [prim n->string | C] [number A] E S R                         -> (interp C [string (n->string A)] E S R)
  [prim string->n | C] [string A] E S R                         -> (interp C [number (string->n A)] E S R)
  [prim str | C] [symbol A] E S R                               -> (interp C [string (str A)] E S R)
  [prim str | C] [number A] E S R                               -> (interp C [string (str A)] E S R)
  [prim str | C] [string A] E S R                               -> (interp C [string A] E S R)
  [prim str | C] [boolean true] E S R                           -> (interp C [string "true"] E S R)
  [prim str | C] [boolean false] E S R                          -> (interp C [string "false"] E S R)
  [prim str | C] A E S R                                        -> (interp C [string (str A)] E S R)
  [prim tlstr | C] [string A] E S R                             -> (interp C [string (tlstr A)] E S R)
  [prim hdstr | C] [string A] E S R                             -> (interp C [string (hdstr A)] E S R)
  [prim read-file-as-string | C] [string A] E S R               -> (interp C [string (read-file-as-string A)] E S R)
  [prim string? | C] [string _] E S R                           -> (interp C [boolean true] E S R)
  [prim string? | C] A E S R                                    -> (interp C [boolean false] E S R)
  [prim number? | C] [number _] E S R                           -> (interp C [boolean true] E S R)
  [prim number? | C] A E S R                                    -> (interp C [boolean false] E S R)
  [prim value | C] [symbol A] E S R                             -> (interp C (value A) E S R)
  \* intern of "true"/"false" must return the BOOLEAN value, not a symbol —
     matching safe.intern (primitives.shen) and the host shen-scheme intern
     (which returns booleans for "true"/"false").  The bundled readers
     (parse-atom / shen-parse-atom) now return true/false literals directly;
     this rule is defense-in-depth for interpreted OS closures (e.g. the Shen
     reader shen.read) that intern "true"/"false" through [prim intern]. *\
  [prim intern | C] [string "true"] E S R                        -> (interp C [boolean true] E S R)
  [prim intern | C] [string "false"] E S R                       -> (interp C [boolean false] E S R)
  [prim intern | C] [string A] E S R                            -> (interp C [symbol (intern A)] E S R)
  [prim error-to-string | C] [error A] E S R                    -> (interp C [string (error-to-string A)] E S R)
  [prim simple-error | C] [string A] E S R                      -> (simple-error A)
  [prim trap-error | C] [lambda C1 E1] E S R                 -> (interp C (interp-trap-body C1 E1 S R) E S R)
  [prim = | C] A E [A1 | S] R                                   -> (interp C [boolean (= A A1)] E S R)
  [prim open | C] [string A] E [[symbol in] | S] R              -> (interp C [stream in (open A in)] E S R)
  [prim open | C] [string A] E [[symbol out] | S] R             -> (interp C [stream out (open A out)] E S R)
  [prim write-byte | C] [number A] E [[stream out A1] | S] R    -> (interp C [number (write-byte A A1)] E S R)
  [prim write-byte | C] [number A] E [A1 | S] R                 -> (interp C [number (write-byte A A1)] E S R) where (stream? A1)
  [prim cons | C] A E [A1 | S] R                                -> (interp C [cons A A1] E S R)
  [prim @p | C] A E [A1 | S] R                                  -> (interp C [cons A A1] E S R)
  [prim fst | C] [cons A _] E S R                               -> (interp C A E S R)
  [prim snd | C] [cons _ A] E S R                               -> (interp C A E S R)
  [prim gensym | C] [symbol A] E S R                            -> (interp C [symbol (fresh-var A)] E S R)
  [prim variable? | C] [symbol A] E S R                         -> (interp C [boolean (variable? A)] E S R)
  [prim variable? | C] A E S R                                  -> (interp C [boolean false] E S R)
  [prim <-address | C] [absvector A] E [[number A1] | S] R      -> (interp C (<-address A A1) E S R)

  [prim pos | C] [string A] E [[number A1] | S] R               -> (interp C [string (pos A A1)] E S R)
  [prim <= | C] [number A] E [[number A1] | S] R                -> (interp C [boolean (<= A A1)] E S R)
  [prim >= | C] [number A] E [[number A1] | S] R                -> (interp C [boolean (>= A A1)] E S R)
  [prim > | C] [number A] E [[number A1] | S] R                 -> (interp C [boolean (> A A1)] E S R)
  [prim < | C] [number A] E [[number A1] | S] R                 -> (interp C [boolean (< A A1)] E S R)
  [prim set | C] [symbol A] E [A1 | S] R                        -> (interp C (set A A1) E S R)
  [prim error? | C] [error A] E S R                             -> (interp C [boolean true] E S R)
  [prim error? | C] A E S R                                     -> (interp C [boolean false] E S R)
  [prim function? | C] [lambda _ _] E S R                      -> (interp C [boolean true] E S R)
  [prim function? | C] A E S R                                  -> (interp C [boolean false] E S R)
  [prim - | C] [number A] E [[number A1] | S] R                 -> (interp C [number (- A A1)] E S R)
  [prim * | C] [number A] E [[number A1] | S] R                 -> (interp C [number (* A A1)] E S R)
  [prim / | C] [number A] E [[number 0] | S] R                  -> (simple-error "division by zero")
  [prim / | C] [number A] E [[number A1] | S] R                 -> (interp C [number (/ A A1)] E S R)
  [prim + | C] [number A] E [[number A1] | S] R                 -> (interp C [number (+ A A1)] E S R)
  [prim address-> | C] [absvector A] E [[number A1] A2 | S] R   -> (interp C [absvector (address-> A A1 A2)] E S R)
  [] A E S R                                                    -> A
  [prim P | _] _ _ _ _                                          -> (simple-error (cn "interp: unknown prim - " (str P)))
  [Op | _] _ _ _ _                                              -> (simple-error (str Op))
  _ _ _ _ _                                                     -> (simple-error "interp: unknown expression"))

(define toplevel-interp { zinc-code --> zinc-value }
  X -> (interp X [cons] [] [] []))

(define kl->zinc { klambda --> zinc-code }
  \* Single path: full normalize/debruijn pipeline for EVERY form.
     The old primitive fast-path (zinc-c [F | Args] where (primitive? F))
     passed RAW args to zinc-c, which cannot compile a bare symbol arg
     (e.g. (value *version*)) or a nested call arg (e.g. (read-byte (stinput)))
     — zinc-c needs the debruijn-normalized [symbol X] / [function X] forms.
     The CPS closure-capture bugs that once motivated the fast-path are fixed
     (dedupe-globals / shen-kl-expr / compile-pattern / zinc-t if-branches).
     General case: full normalize/debruijn pipeline.  The two complex
     sub-expressions (kmacros / normalize-term) are explicitly let-bound
     so the host Shen compiler emits proper 2-arg applies (not curried
     partial applications) when it compiles THIS closure into the bundle.
     Crucially the (debruijn [] N) call itself must be INLINED into zinc-c
     (not let-bound to a D): let-binding the call is what triggers the
     compiler to curry it.  A curried call like ((debruijn []) N) would
     fail at runtime because the C VM does not support partial
     application. *\
  X -> (let K (kmacros X)
         (let N (normalize-term K)
           (zinc-c (debruijn [] N)))))


\* The shen-scheme BOOTSTRAP helper `set-toplevel` and its top-level
   (set-toplevel ...) alias calls moved to shen/set-toplevel.shen.
   serialize-reduced.shen / serialize-qbe.shen load that file right after
   interp.shen in the HOST sequence.  The self-hosted reduced bundle never
   loads it, so `set-toplevel` is absent from globals.csexp / QBE emission. *\


\* Load eval/load infrastructure into the host for serialization *\
(tc -)
(load "shen/toplevel.shen")
(load "shen/load.shen")
(tc +)


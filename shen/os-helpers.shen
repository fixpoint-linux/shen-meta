(tc -)

\* os-helpers.shen — type-safe helpers replacing Shen OS .kl code in the
   reduced meta-interpreter bundle.  All are compiled by our own full-arity
   shen->kl compiler, no partial application or type-unsafe constructs.
   Non-linear patterns avoided: use 'where' guards to check equality
   instead of repeating a variable in the same clause's patterns. *\

(define append
  [] Y -> Y
  [H | T] Y -> [H | (append T Y)])

(define reverse
  L -> (reverse-help L []))

(define reverse-help
  [] Acc -> Acc
  [H | T] Acc -> (reverse-help T [H | Acc]))

(define empty?
  X -> (if (= X []) true false))

(define element?
  _ [] -> false
  X [H | T] -> true where (= X H)
  X [_ | T] -> (element? X T))

\* not — used by debruijn in normalize.shen ((not (element? X Scope))).
   Previously missing from the bundle, so [global not] resolved to the bare
   symbol 'not' at runtime, apply failed, trap-error swallowed it, and
   interp-eval-all returned a false-positive `loaded` (defun never stored). *\
(define not
  true -> false
  false -> true
  _ -> (simple-error "not: expected boolean"))

(define assoc
  _ [] -> []
  K [[H V] | T] -> [H V] where (= K H)
  K [_ | T] -> (assoc K T))

\* factorial - type-safe recursive arithmetic helper (QBE Tests 1-4). *\
(define factorial
  N -> (if (= N 0) 1 (* N (factorial (- N 1)))))

\* qbe-let-test - exercises the letz (OP_LET) lowering: binds a COMPUTED value
   Y = (+ X 1) used twice (so letz is genuinely emitted, not inlined away) and
   passes (+ Y Y) to the 2-arg closure qbe-sub2: (qbe-sub2 12 10) = 2.
   Regression coverage for the Slice-3 review fix (letz must POP the stack,
   matching the C VM OP_LET and the metacircular interp, so a let-bound value
   used in a closure-argument position does not inflate the apply arg count). *\
(define qbe-sub2
  X Z -> (- X Z))
(define qbe-let-test
  X -> (qbe-sub2 (let Y (+ X 1) (+ Y Y)) 10))

(tc +)

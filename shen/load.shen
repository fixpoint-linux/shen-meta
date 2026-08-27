(tc -)
(load "shen/toplevel.shen")

\* The raw .kl OS loader family (interp-load-raw / interp-eval-all /
   interp-eval-safe / read-file-raw and the parse-exprs / parse-expr /
   parse-list / parse-list-tail / parse-list-literal / parse-atom /
   scan-atom-end raw parser) has been REMOVED — the full Shen OS (.kl
   kernel) runtime-load path is dead.  What stays here are the flat-shen
   helper primitives that shen-kl-helpers.shen's shen-parse-* family and the
   host build reuse: string prims (c-strlen / char-code / substring /
   substring-h / strlen / strlen-acc / chars->str), char predicates
   (digit-ch? / ws-ch? / ws-int? / digit-int?), number parsing
   (str->num / str->num-acc / parse-num-str), and scanner helpers
   (skip-comment / skip-ws / find-string-end / parse-string). *\

\* Host-compile dummies for c-strlen / char-code / substring.  These exist so
   the HOST shen-scheme `load` (serialize-reduced.shen line 5) can compile this
   file under tc - (undefined names would fail).  They are NEVER executed at
   runtime on the C VM: the shen-load pass (line 36) re-defines the parser with
   [prim c-strlen] / [prim char-code] / [prim substring] closures (these names
   are in primitive?), which overwrite the dummies via dedupe-globals (keeps the
   newest = shen-load'd).  Keep them delegate to host-compatible functions so
   they are type-correct even if accidentally invoked. *\
(define c-strlen Str -> (strlen-acc Str 0))
(define char-code Str N -> (string->n (pos Str N)))
(define substring Str Start Len -> (substring-h Str Start Len ""))

(define substring-h
  Str Start Len Acc ->
  (if (= Len 0)
      Acc
      (substring-h Str (+ Start 1) (- Len 1) (cn Acc (pos Str Start)))))

(define strlen
  Str -> (c-strlen Str))

\* Kept for compatibility (shen-kl-helpers / host may reference); the runtime
   hot path uses c-strlen. *\
(define strlen-acc
  Str N -> (if (string? (trap-error (pos Str N) (/. E 0)))
              (strlen-acc Str (+ N 1))
              N))

\* Kept for compatibility; O(k^2) but only used off the hot parse path. *\
(define chars->str
  [] -> ""
  [Ch | Rest] -> (cn Ch (chars->str Rest)))

\* digit-ch?: 1-char string -> bool. string->n (1 alloc) instead of string =. *\
(define digit-ch?
  Ch -> (let N (string->n Ch)
           (and (>= N 48) (<= N 57))))

\* ws-ch?: 1-char string -> bool. string->n (1 alloc) instead of 3 n->string
   allocs + 4 string = . *\
(define ws-ch?
  Ch -> (let N (string->n Ch)
           (or (= N 32) (= N 9) (= N 10) (= N 13))))

\* Integer-based predicates (hot path): use char-code, no string allocation. *\
(define ws-int?
  N -> (or (= N 32) (= N 9) (= N 10) (= N 13)))

(define digit-int?
  N -> (and (>= N 48) (<= N 57)))

(define str->num
  Str -> (str->num-acc Str 0 0 (c-strlen Str)))

(define str->num-acc
  Str Pos Acc Len ->
  (if (>= Pos Len)
      Acc
      (let D (- (char-code Str Pos) 48)
        (str->num-acc Str (+ Pos 1) (+ (* Acc 10) D) Len))))

(define parse-num-str
  Str -> (if (= (char-code Str 0) 45)   \* '-' *\
            (- 0 (str->num (tlstr Str)))
            (str->num Str)))

(define skip-comment
  Str Pos Len ->
  (if (>= Pos Len)
      Pos
      (let N (char-code Str Pos)
        (if (or (= N 10) (= N 13))
            (skip-ws Str (+ Pos 1) Len)
            (skip-comment Str (+ Pos 1) Len)))))

\* skip-ws consumes whitespace and comments. Comment:
   \ \  line comment (backslash backslash ... to end of line).  Uses char-code
   (integer compare) instead of pos (string alloc) on the per-char hot path. *\
(define skip-ws
  Str Pos Len ->
  (if (>= Pos Len)
      Pos
      (let N (char-code Str Pos)
        (if (ws-int? N)
            (skip-ws Str (+ Pos 1) Len)
            (if (= N 92)  \* backslash *\
                (let NextPos (+ Pos 1)
                  (if (>= NextPos Len)
                      Pos
                      (let N2 (char-code Str NextPos)
                        (if (= N2 92)
                            (skip-comment Str (+ Pos 2) Len)
                            (skip-ws Str NextPos Len)))))
                Pos)))))

\* find-string-end: scan to closing " (char-code 34); no escape processing
   (KLambda strings treat \ as literal).  Returns index of closing quote. *\
(define find-string-end
  Str Pos Len ->
  (if (>= Pos Len)
      (simple-error "unterminated string")
      (let N (char-code Str Pos)
        (if (= N 34)  \* double-quote *\
            Pos
            (find-string-end Str (+ Pos 1) Len)))))

\* parse-string: substring slice (O(k)) instead of char-collect + reverse +
   chars->str (O(k^2)).  Caller passes Pos AFTER the opening quote. *\
(define parse-string
  Str Pos Len ->
  (let End (find-string-end Str Pos Len)
    [(substring Str Pos (- End Pos)) (+ End 1)]))

(tc -)
(load "shen/toplevel.shen")

\* interp-load / interp-load-safe (the HOST-only read-file loaders) live in
   shen/interp-load.shen, which the bundle builders do not load.  The runtime
   self-hosting loader that stays here is interp-load-raw (read-file-raw ->
   read-file-as-string, a real primitive). *\

(define interp-load-raw
  File -> (interp-eval-all (read-file-raw File)))

(define interp-eval-all
  [] -> loaded
  [E | Rest] -> (do (interp-eval E) (interp-eval-all Rest)))

(define interp-eval-safe
  E -> (trap-error (interp-eval E) (/. X X)))

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

\* scan-atom-end: scan forward to atom delimiter, using char-code.  Returns
   EndPos.  Delimiters: ws, (, ), ", \. *\
(define scan-atom-end
  Str Pos Len ->
  (if (>= Pos Len)
      Pos
      (let N (char-code Str Pos)
        (if (or (ws-int? N)
                (= N 40)  \* ( *\
                (= N 41)  \* ) *\
                (= N 34)  \* " *\
                (= N 92)) \* \ *\
            Pos
            (scan-atom-end Str (+ Pos 1) Len)))))

\* parse-atom: substring slice + intern/number.  O(k), no char-list/reverse. *\
(define parse-atom
  Str Pos Len ->
  (let End (scan-atom-end Str Pos Len)
    (let Token (substring Str Pos (- End Pos))
      (if (= Token "")
          [(intern "") End]
          (if (or (digit-int? (char-code Token 0))
                  (and (> (c-strlen Token) 1)
                       (= (char-code Token 0) 45)   \* '-' *\
                       (digit-int? (char-code Token 1))))
              [(parse-num-str Token) End]
              (if (= Token "true")
                  [true End]
                  (if (= Token "false")
                      [false End]
                      [(intern Token) End])))))))

(define parse-list-tail
  Str Pos Len ->
  (let P (skip-ws Str Pos Len)
    (if (>= P Len)
        (simple-error "unterminated list")
        (if (= (char-code Str P) 41)  \* ) *\
            [[] (+ P 1)]
            (let Pair1 (parse-expr Str P Len)
              (let First (hd Pair1)
                (let AfterFirst (hd (tl Pair1))
                  (let Pair2 (parse-list-tail Str AfterFirst Len)
                    (let Rest (hd Pair2)
                      (let AfterRest (hd (tl Pair2))
                        [[First | Rest] AfterRest]))))))))))

(define parse-list
  Str Pos Len -> (parse-list-tail Str Pos Len))

(define parse-expr
  Str Pos Len ->
  (let P (skip-ws Str Pos Len)
    (if (>= P Len)
        (simple-error "unexpected end of input")
        (let N (char-code Str P)
          (if (= N 40)  \* ( *\
              (parse-list Str (+ P 1) Len)
              (if (= N 41)  \* ) *\
                  (simple-error "unexpected )")
                  (if (= N 34)  \* " *\
                      (parse-string Str (+ P 1) Len)
                      (parse-atom Str P Len))))))))

(define parse-exprs
  Str Pos Len ->
  (let P (skip-ws Str Pos Len)
    (if (>= P Len)
        [[] P]
        (let Pair1 (parse-expr Str P Len)
          (let Expr (hd Pair1)
            (let NewPos (hd (tl Pair1))
              (let Pair2 (parse-exprs Str NewPos Len)
                (let Rest (hd Pair2)
                  (let FinalPos (hd (tl Pair2))
                    [[Expr | Rest] FinalPos])))))))))

(define read-file-raw
  Path -> (let Str (read-file-as-string Path)
            (let Len (strlen Str)
              (hd (parse-exprs Str 0 Len)))))

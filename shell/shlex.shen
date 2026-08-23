(tc -)

\* shlex.shen - shpar-p2 U2: the shell lexer.
   Tokenises a (possibly multi-line) shell input string into a list of tokens
   plus a list of pending heredoc delimiters (when the input ends before a
   heredoc body is closed - the REPL accumulates more lines and re-lexes).
   Self-contained: the sp-* string helpers are local copies of the sh-*
   helpers in shell.shen (kept here so this file loads independently; U5 will
   retire the sh-* twins).
   Token shapes (per plan plan spec D):
     [word (list part)]            part = [lit S] | [var S Q]   (Q boolean)
     [pipe] [semi] [andand] [oror] [lparen] [rparen]
     [redir Kind Fd TargetParts]   Kind in {gt,gtgt,lt,dup}; TargetParts=(list part);
                                   TargetParts=[]  => spaced, target is the NEXT word token
     [hdoc Delim Body Strip]       Delim string, Body string (verbatim; v1 no $VAR expand),
                                   Strip boolean (<<-)
     [hstr TargetParts]            (stretch; here-string <<<)
   Rejects (via simple-error, caught by the shell's trap-error wrapper):
     backtick, $(, $((, <(, >( => "X not supported"
     bare &                          => "background & not supported in v1"
     fd-dup N>&M partial             => "bad fd-dup"
     $0-$9 $# $@ $* $$ $! $-         => "X not supported"
   $? is supported (stretch: expands to *sh-exit-code* in U4).
   Driver: sp-lex Str => [Tokens PendingDelims]. *\

\* ===== string helpers (local copies of shell.shen sh-*) ===== *\

(define sp-len
  { string --> number }
  S -> (if (= S "") 0 (+ 1 (sp-len (tlstr S)))))

(define sp-ch
  { string --> number --> string }
  S I -> (if (< I (sp-len S)) (pos S I) ""))

(define sp-at-end
  { string --> number --> boolean }
  S I -> (>= I (sp-len S)))

(define sp-is-space
  { string --> number --> boolean }
  S I -> (let C (sp-ch S I)
           (or (= C " ") (= C (n->string 9)))))

(define sp-skipws
  { string --> number --> number }
  S I -> (if (sp-is-space S I) (sp-skipws S (+ I 1)) I))

(define sp-substr
  { string --> number --> number --> string }
  S Start End -> (if (or (sp-at-end S Start)
                         (if (= End -1) false (>= Start End)))
                     ""
                     (cn (sp-ch S Start) (sp-substr S (+ Start 1) End))))

(define sp-trim
  { string --> number --> string }
  S Start -> (sp-substr S Start -1))

(define sp-find-ch
  { string --> number --> number --> number }
  S From C -> (if (sp-at-end S From)
                  -1
                  (if (= (string->n (sp-ch S From)) C)
                      From
                      (sp-find-ch S (+ From 1) C))))

\* sp-find-ch-or-len: index of first C at/after From, else Len (EOI). *\
(define sp-find-or-len
  { string --> number --> number --> number --> number }
  S From Len C -> (if (>= From Len) Len
                       (if (= (string->n (sp-ch S From)) C)
                           From
                           (sp-find-or-len S (+ From 1) Len C))))

(define sp-prefix
  { string --> string --> boolean }
  S P -> (sp-prefix-1 S P 0))

(define sp-prefix-1
  { string --> string --> number --> boolean }
  S P I -> (if (sp-at-end P I)
               true
               (if (sp-at-end S I)
                   false
                   (if (= (sp-ch S I) (sp-ch P I))
                       (sp-prefix-1 S P (+ I 1))
                       false))))

\* ===== char classes ===== *\

(define sp-digit?
  { string --> boolean }
  C -> (let N (string->n C) (and (>= N 48) (<= N 57))))

(define sp-var-start?
  { string --> boolean }
  C -> (let N (string->n C)
         (or (and (>= N 65) (<= N 90))
             (and (>= N 97) (<= N 122))
             (= C "_"))))

(define sp-var-cont?
  { string --> boolean }
  C -> (or (sp-var-start? C) (sp-digit? C)))

\* word terminator outside quotes (Depth = current paren depth so a bare ')'
   only terminates a word inside parens, matching the reference lexer). *\
(define sp-word-term?
  { string --> number --> boolean }
  C Depth -> (or (or (= C " ") (= C (n->string 9)) (= C (n->string 10)) (= C (n->string 13)))
                 (or (= C "|") (= C ";") (= C "&") (= C "("))
                 (and (= C ")") (> Depth 0))))

\* ===== variable-name readers ===== *\

(define sp-lex-varname
  { string --> number --> number --> klambda }
  S Pos Len -> (if (or (>= Pos Len) (= (sp-var-start? (sp-ch S Pos)) false))
                   ["" Pos]
                   (sp-lex-varname-1 S (+ Pos 1) Len (sp-ch S Pos))))

(define sp-lex-varname-1
  { string --> number --> number --> string --> klambda }
  S Pos Len Acc -> (if (or (>= Pos Len) (= (sp-var-cont? (sp-ch S Pos)) false))
                     [Acc Pos]
                     (sp-lex-varname-1 S (+ Pos 1) Len (cn Acc (sp-ch S Pos)))))

\* ${...} braced variable; inner must be a valid var name (guard). *\
(define sp-lex-braced
  { string --> number --> number --> klambda }
  S Pos Len -> (sp-lex-braced-1 S (+ Pos 1) Len ""))

(define sp-lex-braced-1
  { string --> number --> number --> string --> klambda }
  S Pos Len Acc -> (if (>= Pos Len)
                       (simple-error "bad ${...}: unterminated")
                       (let C (sp-ch S Pos)
                         (if (= C "}")
                             (if (= Acc "")
                                 (simple-error "bad ${...}: empty name")
                                 [Acc (+ Pos 1)])
                             (if (sp-var-cont? C)
                                 (sp-lex-braced-1 S (+ Pos 1) Len (cn Acc C))
                                 (simple-error "bad ${...}: bad name"))))))

\* classify the char after '$': returns [part NewPos] or throws.
   Q = quoted (passed in from caller, true inside dq). *\
(define sp-lex-varref
  { string --> number --> number --> boolean --> klambda }
  S Pos Len Q -> (if (>= Pos Len)
                     [[lit "$"] Pos]
                     (let C (sp-ch S Pos)
                       (if (= C "{")
                           (let Bp (sp-lex-braced S Pos Len)
                             (let Name (hd Bp)
                               (let Np (hd (tl Bp))
                                 [[var Name Q] Np])))
                           (if (= C "?")
                               [[var "?" Q] (+ Pos 1)]
                               (if (or (sp-digit? C)
                                       (or (= C "#") (= C "@") (= C "*")
                                           (= C "!") (= C "-")))
                                   (simple-error (cn C " not supported"))
                                   (if (sp-var-start? C)
                                       (let Np (sp-lex-varname S Pos Len)
                                         (let Name (hd Np)
                                           (let Np2 (hd (tl Np))
                                             [[var Name Q] Np2])))
                                       [[lit "$"] Pos])))))))

\* ===== single-quote: fully literal contents (quotes stripped) ===== *\
\* find the closing single-quote at/after Start; returns its index or -1. *\
(define sp-find-sq
  { string --> number --> number --> number }
  S Pos Len -> (if (>= Pos Len) -1
                  (if (= (sp-ch S Pos) "'") Pos
                      (sp-find-sq S (+ Pos 1) Len))))

\* ===== double-quote: \" \\ \$ escapes; \$ keeps BOTH chars; embedded
   [var Name true] parts; other backslashes stay literal (both chars). ===== *\
(define sp-lex-dq
  { string --> number --> number --> klambda --> klambda }
  S Pos Len Acc -> (if (>= Pos Len)
                       (simple-error "unterminated double quote")
                       (let C (sp-ch S Pos)
                         (if (= C (n->string 34))
                             [Acc (+ Pos 1)]
                             (if (= C (n->string 92))
                                 (let Nc (sp-ch S (+ Pos 1))
                                   (if (= Nc (n->string 34))
                                       (sp-lex-dq S (+ Pos 2) Len (cons [lit (n->string 34)] Acc))
                                       (if (= Nc (n->string 92))
                                           (sp-lex-dq S (+ Pos 2) Len (cons [lit (n->string 92)] Acc))
                                           (sp-lex-dq S (+ Pos 2) Len (cons [lit (cn (n->string 92) Nc)] Acc)))))
                                 (if (= C "$")
                                     (let Vp (sp-lex-varref S (+ Pos 1) Len true)
                                       (let Part (hd Vp)
                                         (let Np (hd (tl Vp))
                                           (sp-lex-dq S Np Len (cons Part Acc)))))
                                     (sp-lex-dq S (+ Pos 1) Len (cons [lit C] Acc))))))))

\* ===== word lexer: accumulate parts until a terminator.
   Parts are accumulated reversed; reversed on return.
   Backslash outside quotes: \$ keeps BOTH chars, \X keeps only X. *\
(define sp-lex-word
  { string --> number --> number --> number --> klambda --> klambda }
  S Pos Len Depth Acc -> (if (>= Pos Len)
                              [(reverse Acc) Pos]
                              (let C (sp-ch S Pos)
                                (if (sp-word-term? C Depth)
                                    [(reverse Acc) Pos]
                                    (if (= C "'")
                                        (let Close (sp-find-sq S (+ Pos 1) Len)
                                          (if (= Close -1)
                                              (simple-error "unterminated single quote")
                                              (let Content (sp-substr S (+ Pos 1) Close)
                                                (sp-lex-word S (+ Close 1) Len Depth (cons [lit Content] Acc)))))
                                        (if (= C (n->string 34))
                                            (let Dq (sp-lex-dq S (+ Pos 1) Len [])
                                              (let Dparts (reverse (hd Dq))
                                                (let Np (hd (tl Dq))
                                                  (if (= Dparts [])
                                                      (sp-lex-word S Np Len Depth (cons [lit ""] Acc))
                                                      (sp-lex-word S Np Len Depth (sp-prepend-list Dparts Acc))))))
                                            (if (= C (n->string 92))
                                                (let Nc (sp-ch S (+ Pos 1))
                                                  (if (= Nc "")
                                                      (sp-lex-word S (+ Pos 1) Len Depth Acc)
                                                      (if (= Nc "$")
                                                          (sp-lex-word S (+ Pos 2) Len Depth (cons [lit (cn (n->string 92) Nc)] Acc))
                                                          (sp-lex-word S (+ Pos 2) Len Depth (cons [lit Nc] Acc)))))
                                                (if (= C "$")
                                                    (let Vp (sp-lex-varref S (+ Pos 1) Len false)
                                                      (let Part (hd Vp)
                                                        (let Np (hd (tl Vp))
                                                          (sp-lex-word S Np Len Depth (cons Part Acc)))))
                                                    (sp-lex-word S (+ Pos 1) Len Depth (cons [lit C] Acc))))))))))

(define sp-prepend-list
  { klambda --> klambda --> klambda }
  [] Acc -> Acc
  [X | R] Acc -> (sp-prepend-list R (cons X Acc)))

\* ===== heredoc delimiter read (after << or <<-); Pos at first delim char.
   Returns [Delim NewPos].  Unquoted, a backslash escapes the next char into
   the delim (and marks the body literal - though v1 treats all bodies
   verbatim).  Stops at space/tab/newline/;/|/&/EOI. *\
(define sp-lex-hdoc-delim
  { string --> number --> number --> klambda }
  S Pos Len -> (if (>= Pos Len)
                   ["" Pos]
                   (let C (sp-ch S Pos)
                     (if (= C "'")
                         (let Close (sp-find-sq S (+ Pos 1) Len)
                           (if (= Close -1)
                               (simple-error "unterminated heredoc delim")
                               [(sp-substr S (+ Pos 1) Close) (+ Close 1)]))
                         (if (= C (n->string 34))
                             (sp-lex-hdoc-delim-dq S (+ Pos 1) Len "")
                             (sp-lex-hdoc-delim-raw S Pos Len ""))))))

(define sp-lex-hdoc-delim-dq
  { string --> number --> number --> string --> klambda }
  S Pos Len Acc -> (if (>= Pos Len)
                       (simple-error "unterminated heredoc delim")
                       (let C (sp-ch S Pos)
                         (if (= C (n->string 34))
                             [Acc (+ Pos 1)]
                             (sp-lex-hdoc-delim-dq S (+ Pos 1) Len (cn Acc C))))))

(define sp-lex-hdoc-delim-raw
  { string --> number --> number --> string --> klambda }
  S Pos Len Acc -> (if (>= Pos Len)
                       [Acc Pos]
                       (let C (sp-ch S Pos)
                         (if (or (or (= C " ") (= C (n->string 9)) (= C (n->string 10)) (= C (n->string 13)))
                                 (or (= C ";") (= C "|") (= C "&")))
                             [Acc Pos]
                             (if (= C (n->string 92))
                                 (let Nc (sp-ch S (+ Pos 1))
                                   (if (= Nc "")
                                       [Acc Pos]
                                       (sp-lex-hdoc-delim-raw S (+ Pos 2) Len (cn Acc Nc))))
                                 (sp-lex-hdoc-delim-raw S (+ Pos 1) Len (cn Acc C)))))))

\* strip leading TABs from a line (for <<- comparison and body). *\
(define sp-strip-tabs
  { string --> string }
  S -> (if (= S "")
          ""
          (if (= (sp-ch S 0) (n->string 9))
              (sp-strip-tabs (tlstr S))
              S)))

\* read heredoc body lines from Start until a line equals Delim (after
   optional tab-strip for <<-).  Returns [Body EndPos Pending?]:
     Pending? true  => EOI reached before the delimiter (caller appends Delim
                      to PendingDelims and uses Body="").
   Body includes a trailing newline after every line (POSIX heredoc body). *\
(define sp-read-hdoc-body
  { string --> number --> number --> string --> boolean --> klambda }
  S Start Len Delim Strip -> (if (>= Start Len)
                                ["" Len true]
                                (let Nl (sp-find-or-len S Start Len 10)
                                  (let Raw (sp-substr S Start Nl)
                                    (let Cmp (if Strip (sp-strip-tabs Raw) Raw)
                                      (if (= Cmp Delim)
                                          ["" (if (>= Nl Len) Len (+ Nl 1)) false]
                                          (let RestStart (if (>= Nl Len) Len (+ Nl 1))
                                            (let Rb (sp-read-hdoc-body S RestStart Len Delim Strip)
                                              (let Rbody (hd Rb)
                                                (let Rpend (hd (tl (tl Rb)))
                                                  (if Rpend
                                                      ["" Len true]
                                                      [(cn (if Strip (sp-strip-tabs Raw) Raw)
                                                            (cn (n->string 10) Rbody))
                                                       (hd (tl Rb)) false])))))))))))

\* ===== main lexer loop.
   State: Str Pos Len TokAcc(rev) PDAcc(rev) NBS Nl Depth.
   NBS = next-body-start (where the next heredoc body begins, after prior
        heredoc bodies on this line); -1 = none queued yet.
   Nl  = the newline ending the current command line (saved when a heredoc
        is queued on this line); -1 = none. *\
(define sp-lex-run
  { string --> number --> number --> klambda --> klambda --> number --> number --> number --> klambda }
  S Pos Len TokAcc PDAcc NBS Nl Depth ->
  (let P (sp-skipws S Pos)
    (if (>= P Len)
        [(reverse TokAcc) (reverse PDAcc)]
        (let C (sp-ch S P)
          (if (= C "#")
              (sp-lex-run S (sp-find-or-len S P Len 10) Len TokAcc PDAcc NBS Nl Depth)
              (if (= C (n->string 10))
                  (if (= Nl -1)
                      (sp-lex-run S (+ P 1) Len (cons [semi] TokAcc) PDAcc -1 -1 Depth)
                      (sp-lex-run S NBS Len (cons [semi] TokAcc) PDAcc -1 -1 Depth))
                  (if (= C ";")
                      (sp-lex-run S (+ P 1) Len (cons [semi] TokAcc) PDAcc NBS Nl Depth)
                      (if (= C "`")
                          (simple-error "backtick not supported")
                          (if (and (= C "$") (= (sp-ch S (+ P 1)) "("))
                              (if (= (sp-ch S (+ P 2)) "(")
                                  (simple-error "arithmetic substitution not supported")
                                  (simple-error "command substitution not supported"))
                              (if (and (or (= C "<") (= C ">")) (= (sp-ch S (+ P 1)) "("))
                                  (simple-error "process substitution not supported")
                                  (if (= C "&")
                                      (if (= (sp-ch S (+ P 1)) "&")
                                          (sp-lex-run S (+ P 2) Len (cons [andand] TokAcc) PDAcc NBS Nl Depth)
                                          (simple-error "background & not supported in v1"))
                                      (if (= C "|")
                                          (if (= (sp-ch S (+ P 1)) "|")
                                              (sp-lex-run S (+ P 2) Len (cons [oror] TokAcc) PDAcc NBS Nl Depth)
                                              (sp-lex-run S (+ P 1) Len (cons [pipe] TokAcc) PDAcc NBS Nl Depth))
                                          (if (= C "(")
                                              (sp-lex-run S (+ P 1) Len (cons [lparen] TokAcc) PDAcc NBS Nl (+ Depth 1))
                                              (if (= C ")")
                                                  (if (= Depth 0)
                                                      (simple-error "unexpected )")
                                                      (sp-lex-run S (+ P 1) Len (cons [rparen] TokAcc) PDAcc NBS Nl (- Depth 1)))
                                                  (if (sp-fd-dup? S P Len)
                                                      (let Fd (sp-num (sp-ch S P))
                                                        (let Tg (sp-num (sp-ch S (+ P 3)))
                                                          (if (and (< (+ P 4) Len) (sp-fd-dup-tail? (sp-ch S (+ P 4))))
                                                              (simple-error "bad fd-dup")
                                                              (sp-lex-run S (+ P 4) Len
                                                                          (cons [redir dup Fd [[lit (sp-ch S (+ P 3))]]] TokAcc)
                                                                          PDAcc NBS Nl Depth))))
                                                      (if (and (= C "<") (= (sp-ch S (+ P 1)) "<") (= (sp-ch S (+ P 2)) "<"))
                                                          (sp-lex-hstring S P Len TokAcc PDAcc NBS Nl Depth)
                                                          (if (and (= C "<") (= (sp-ch S (+ P 1)) "<") (= (sp-ch S (+ P 2)) "-"))
                                                              (sp-lex-heredoc S (+ P 3) Len TokAcc PDAcc NBS Nl Depth true)
                                                              (if (and (= C "<") (= (sp-ch S (+ P 1)) "<"))
                                                                  (sp-lex-heredoc S (+ P 2) Len TokAcc PDAcc NBS Nl Depth false)
                                                                  (if (and (or (= C "1") (= C "2")) (= (sp-ch S (+ P 1)) ">") (= (sp-ch S (+ P 2)) ">"))
                                                                      (sp-lex-redir S (+ P 3) Len gtgt (sp-num C) TokAcc PDAcc NBS Nl Depth)
                                                                      (if (and (= C ">") (= (sp-ch S (+ P 1)) ">"))
                                                                          (sp-lex-redir S (+ P 2) Len gtgt 1 TokAcc PDAcc NBS Nl Depth)
                                                                          (if (and (or (= C "1") (= C "2")) (= (sp-ch S (+ P 1)) ">"))
                                                                              (sp-lex-redir S (+ P 2) Len gt (sp-num C) TokAcc PDAcc NBS Nl Depth)
                                                                              (if (and (= C ">") (= (sp-ch S (+ P 1)) "&"))
                                                                                  (simple-error "bad redirect (use N>&M)")
                                                                                  (if (= C ">")
                                                                                      (sp-lex-redir S (+ P 1) Len gt 1 TokAcc PDAcc NBS Nl Depth)
                                                                                      (if (= C "<")
                                                                                          (sp-lex-redir S (+ P 1) Len lt 0 TokAcc PDAcc NBS Nl Depth)
                                                                                          (sp-lex-word-token S P Len TokAcc PDAcc NBS Nl Depth)))))))))))))))))))))))))

\* fd-dup at P: char P in {1,2}, P+1 '>', P+2 '&', P+3 in {1,2}. *\
(define sp-fd-dup?
  { string --> number --> number --> boolean }
  S P Len -> (if (>= (+ P 3) Len)
                 false
                 (let A (sp-ch S P) (let B (sp-ch S (+ P 1)) (let Cc (sp-ch S (+ P 2)) (let D (sp-ch S (+ P 3))
                   (and (or (= A "1") (= A "2"))
                        (= B ">") (= Cc "&")
                        (or (= D "1") (= D "2")))))))))

\* a non-terminator char at the char after N>&M => partial fd-dup => reject. *\
(define sp-fd-dup-tail?
  { string --> boolean }
  C -> (= (or (or (= C " ") (= C (n->string 9)) (= C (n->string 10)) (= C (n->string 13)))
                (or (= C "|") (= C ";") (= C "&") (= C "(") (= C ")"))
                (= C "")) false))

(define sp-num
  { string --> number }
  C -> (- (string->n C) 48))

\* a redirect with operator already consumed; read glued or spaced target.
   Pos = first char after the operator. *\
(define sp-lex-redir
  { string --> number --> number --> symbol --> number --> klambda --> klambda --> number --> number --> number --> klambda }
  S Pos Len Kind Fd TokAcc PDAcc NBS Nl Depth ->
  (if (>= Pos Len)
      (sp-lex-run S Pos Len (cons [redir Kind Fd []] TokAcc) PDAcc NBS Nl Depth)
      (let C (sp-ch S Pos)
        (if (sp-redir-spaced? C)
            (sp-lex-run S Pos Len (cons [redir Kind Fd []] TokAcc) PDAcc NBS Nl Depth)
            (let Wp (sp-lex-word S Pos Len Depth [])
              (let Parts (hd Wp)
                (let Np (hd (tl Wp))
                  (sp-lex-run S Np Len (cons [redir Kind Fd Parts] TokAcc) PDAcc NBS Nl Depth))))))))

\* after a redirect operator, these chars mean the target is SPACED (next word). *\
(define sp-redir-spaced?
  { string --> boolean }
  C -> (or (or (= C " ") (= C (n->string 9)) (= C (n->string 10)) (= C (n->string 13)))
           (or (= C "|") (= C ";") (= C "&") (= C "(") (= C ")"))
           (or (= C "<") (= C ">") (= C "#") (= C "`"))))

\* here-string  <<<  (stretch): read a quote-aware target word to EOL/newline. *\
(define sp-lex-hstring
  { string --> number --> number --> klambda --> klambda --> number --> number --> number --> klambda }
  S Pos Len TokAcc PDAcc NBS Nl Depth ->
  (let P (sp-skipws S (+ Pos 3))
    (if (>= P Len)
        (sp-lex-run S P Len (cons [hstr []] TokAcc) PDAcc NBS Nl Depth)
        (let Wp (sp-lex-word S P Len Depth [])
          (let Parts (hd Wp)
            (let Np (hd (tl Wp))
              (sp-lex-run S Np Len (cons [hstr Parts] TokAcc) PDAcc NBS Nl Depth)))))))

\* heredoc at Pos (first delim char).  Reads the delimiter, then scans ahead to
   the newline ending this command line and reads the body (advancing NBS past
   it).  Lexing of the rest of the current command line resumes at Pos. *\
(define sp-lex-heredoc
  { string --> number --> number --> klambda --> klambda --> number --> number --> number --> boolean --> klambda }
  S Pos Len TokAcc PDAcc NBS Nl Depth Strip ->
  (let P (sp-skipws S Pos)
    (let Dp (sp-lex-hdoc-delim S P Len)
      (let Delim (hd Dp)
        (let DEnd (hd (tl Dp))
          (let ThisNl (if (= Nl -1) (sp-find-or-len S DEnd Len 10) Nl)
            (let BodyStart (if (= NBS -1) (+ ThisNl 1) NBS)
              (let Bb (sp-read-hdoc-body S BodyStart Len Delim Strip)
                (let Body (hd Bb)
                  (let BEnd (hd (tl Bb))
                    (let Pend (hd (tl (tl Bb)))
                      (if Pend
                          (sp-lex-run S DEnd Len (cons [hdoc Delim Body Strip] TokAcc)
                                      (cons Delim PDAcc) Len ThisNl Depth)
                          (sp-lex-run S DEnd Len (cons [hdoc Delim Body Strip] TokAcc)
                                      PDAcc BEnd ThisNl Depth)))))))))))))

\* a word token at P (token position).  Empty words are dropped only if the
   scan produced no parts; a quoted-empty word yields [lit ""] and is kept. *\
(define sp-lex-word-token
  { string --> number --> number --> klambda --> klambda --> number --> number --> number --> klambda }
  S Pos Len TokAcc PDAcc NBS Nl Depth ->
  (let Wp (sp-lex-word S Pos Len Depth [])
    (let Parts (hd Wp)
      (let Np (hd (tl Wp))
        (if (= Parts [])
            (sp-lex-run S (+ Pos 1) Len TokAcc PDAcc NBS Nl Depth)
            (sp-lex-run S Np Len (cons [word Parts] TokAcc) PDAcc NBS Nl Depth))))))

\* ===== driver ===== *\

(define sp-lex
  { string --> klambda }
  Str -> (sp-lex-run Str 0 (sp-len Str) [] [] -1 -1 0))

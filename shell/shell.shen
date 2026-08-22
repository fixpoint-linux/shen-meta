(tc -)

(define sh-prompt
  { --> string }
  -> (cn (getcwd 0) "> "))

(define sh-len
  { string --> number }
  S -> (if (= S "") 0 (+ 1 (sh-len (tlstr S)))))

(define sh-ch
  { string --> number --> string }
  S I -> (if (< I (sh-len S)) (pos S I) ""))

(define sh-at-end
  { string --> number --> boolean }
  S I -> (>= I (sh-len S)))

(define sh-is-space
  { string --> number --> boolean }
  S I -> (let C (sh-ch S I)
           (or (= C " ") (= C "\t") (= C "\n") (= C "\r"))))

(define sh-skipws
  { string --> number --> number }
  S I -> (if (sh-is-space S I) (sh-skipws S (+ I 1)) I))

(define sh-substr
  { string --> number --> number --> string }
  S Start End -> (if (or (sh-at-end S Start)
                         (if (= End -1) false (>= Start End)))
                     ""
                     (cn (sh-ch S Start) (sh-substr S (+ Start 1) End))))

(define sh-trim
  { string --> number --> string }
  S Start -> (sh-substr S Start -1))

(define sh-find-ch
  { string --> number --> number --> number }
  S From C -> (if (sh-at-end S From)
                  -1
                  (if (= (string->n (sh-ch S From)) C)
                      From
                      (sh-find-ch S (+ From 1) C))))

(define sh-prefix
  { string --> string --> boolean }
  S P -> (sh-prefix-1 S P 0))

(define sh-prefix-1
  { string --> string --> number --> boolean }
  S P I -> (if (sh-at-end P I)
               true
               (if (sh-at-end S I)
                   false
                   (if (= (sh-ch S I) (sh-ch P I))
                       (sh-prefix-1 S P (+ I 1))
                       false))))

(define sh-cd
  { string --> string }
  S -> (let I (sh-skipws S 3)
         (if (cd (sh-trim S I)) "" "cd failed")))

(define sh-echo
  { string --> string }
  S -> (sh-trim S (sh-skipws S 5)))

(define sh-pwd
  { --> string }
  -> (str (getcwd 0)))

(define sh-token
  { string --> number --> string }
  S Start -> (let Sp (sh-find-ch S Start 32)
               (if (= Sp -1) (sh-trim S Start) (sh-substr S Start Sp))))

(define sh-setenv
  { string --> number --> string }
  S Start -> (let I (sh-find-ch S Start 61)
               (if (= I -1)
                   (let Sp (sh-find-ch S Start 32)
                     (if (= Sp -1)
                         "usage: setenv NAME VALUE or NAME=VALUE"
                         (if (setenv (sh-token S Start) (sh-trim S (+ Sp 1)))
                             "" "setenv failed")))
                   (if (setenv (sh-token S Start) (sh-trim S (+ I 1)))
                       "" "setenv failed"))))

(define sh-run-command
  { string --> string }
  Cmd -> (let Res (exec-command Cmd)
           (let Exit (hd Res)
             (let Out (hd (tl Res))
               (if (= Exit 0) (str Out) (cn "exit " (str Exit)))))))

(define sh-run-pipe
  { (list string) --> string }
  Stages -> (let Res (shell-pipe Stages)
              (let Exit (hd Res)
                (let Out (hd (tl Res))
                  (if (= Exit 0) (str Out) (cn "exit " (str Exit)))))))

(define sh-split-pipe
  { string --> (list string) }
  S -> (sh-split-pipe-1 S 0 nil "" false (n->string 34)))

(define sh-split-pipe-1
  { string --> number --> (list string) --> string --> boolean --> string --> (list string) }
  S I Acc Cur InQuote Q -> (if (sh-at-end S I)
                              (sh-append-stage Acc Cur)
                              (let C (sh-ch S I)
                                (if InQuote
                                    (if (= C Q)
                                        (sh-split-pipe-1 S (+ I 1) Acc (cn Cur C) false Q)
                                        (sh-split-pipe-1 S (+ I 1) Acc (cn Cur C) true Q))
                                    (if (= C Q)
                                        (sh-split-pipe-1 S (+ I 1) Acc (cn Cur C) true Q)
                                        (if (= C "|")
                                            (sh-split-pipe-1 S (+ I 1) (sh-append-stage Acc Cur) "" false Q)
                                            (sh-split-pipe-1 S (+ I 1) Acc (cn Cur C) false Q)))))))

(define sh-append-stage
  { (list string) --> string --> (list string) }
  Acc Cur -> (if (= Acc nil)
                  (cons Cur nil)
                  (cons (hd Acc) (sh-append-stage (tl Acc) Cur))))

(define sh-tag-stages
  { (list string) --> (list string) }
  S -> (if (= S nil) nil (cons (sh-trim (hd S) (sh-skipws (hd S) 0)) (sh-tag-stages (tl S)))))

(define sh-run-external
  { string --> string }
  S -> (let I (sh-skipws S 0)
         (let Line (sh-trim S I)
           (let PipeI (sh-find-ch Line 0 124)
             (if (= PipeI -1)
                 (sh-run-command Line)
                 (sh-run-pipe (sh-tag-stages (sh-split-pipe Line))))))))

(define sh-builtin
  { string --> string }
  S -> (let I (sh-skipws S 0)
         (let Cmd (sh-ch S I)
           (if (= Cmd "c")
               (if (sh-prefix S "cd ") (sh-cd S) (sh-run-external S))
               (if (= Cmd "p")
                   (if (sh-prefix S "pwd") (sh-pwd) (sh-run-external S))
                   (if (= Cmd "s")
                       (if (sh-prefix S "setenv ") (sh-setenv S 7) (sh-run-external S))
                       (if (= Cmd "e")
                           (if (sh-prefix S "exit")
                               (if (set *sh-exit* true) "exit" "exit")
                               (if (sh-prefix S "echo ")
                                   (sh-echo S)
                                   (if (sh-prefix S "export ") (sh-setenv S 7) (sh-run-external S))))
                           (sh-run-external S))))))))

(define shell-eval-line
  { string --> string }
  S -> (trap-error (sh-builtin S) (lambda E (cn "error: " (str E)))))

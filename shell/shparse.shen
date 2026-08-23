(tc -)

\* shparse.shen - shpar-p2 U3: the shell parser (recursive descent).
   Consumes the lexer result [Tokens PendingDelims] (sp-lex in shlex.shen)
   and produces an AST:
     Program  = (list Chain)     Chain = [op Pipeline]  op in {seq,and,or}
     Pipeline = (list Cmd)       Cmd   = [Argv Redirs Sub]
     Argv     = (list word)      word  = (list part)          (unexpanded)
     Redirs   = (list RNode)     RNode = [redir Kind Fd TargetParts]
                                           | [hdoc Delim Body Strip]
                                           | [hstr TargetParts]
     Sub      = [] plain | nested Program (subshell; Argv empty then)
   Ported from the reference parser (_parse_and_or / _parse_pipeline):
   consecutive chain operators collapse with LAST-wins; a trailing operator
   with nothing after it is dropped; empty commands are skipped; a subshell
   CAN be piped ((a) | b) and can absorb trailing redirections ((a) > f).
   A spaced redirect ([redir Kind Fd []]) takes its target from the NEXT
   word token; a glued one carries TargetParts already.
   Driver: sp-parse LexResult => [ok Program] | [pending Delims]; syntax
   errors throw simple-error (caught by the shell's trap-error wrapper).
   Depends on shlex.shen (sp-prepend-list; loads into the same namespace). *\
\* NOTE: chain op symbols are produced with intern because bare and/or are
   KLambda macros and must never appear as raw list-literal elements. *\
\* Lowercase atoms in list literals/patterns are SYMBOL CONSTANTS;
   uppercase are variables (Shen convention) - same as shlex.shen. *\

\* ===== token classification ===== *\

\* does this token TAG end the current command? *\
(define sp-cmd-term?
  { klambda --> boolean }
  Tag -> (or (= Tag pipe)
             (or (= Tag semi)
                 (or (= Tag andand)
                     (or (= Tag oror) (= Tag rparen))))))

(define sp-chain-op?
  { klambda --> boolean }
  Tag -> (or (= Tag semi) (or (= Tag andand) (= Tag oror))))

\* is the next token a [pipe]? *\
(define sp-next-pipe?
  { klambda --> boolean }
  Tokens -> (if (= Tokens [])
                false
                (= (hd (hd Tokens)) pipe)))

\* a command with no argv, no redirs and no subshell = "no command". *\
(define sp-cmd-empty?
  { klambda --> boolean }
  Cmd -> (and (= (hd Cmd) [])
              (and (= (hd (tl Cmd)) [])
                   (= (hd (tl (tl Cmd))) []))))

\* ===== redirect token consumption ===== *\

\* consume a [redir Kind Fd Parts] token: if Parts = [] (spaced target)
   the NEXT word token supplies the target parts.  Returns [Token Rest]. *\
(define sp-take-redir
  { klambda --> klambda }
  Tokens ->
    (let H (hd Tokens)
      (let Kind (hd (tl H))
        (let Fd (hd (tl (tl H)))
          (let Parts (hd (tl (tl (tl H))))
            (if (= Parts [])
                (let Next (tl Tokens)
                  (if (= Next [])
                      (simple-error "redirect missing target")
                      (if (= (hd (hd Next)) word)
                          [[redir Kind Fd (hd (tl (hd Next)))] (tl Next)]
                          (simple-error "redirect missing target"))))
                [[redir Kind Fd Parts] (tl Tokens)]))))))

\* consume an [hstr Parts] token (same spaced-target rule). *\
(define sp-take-hstr
  { klambda --> klambda }
  Tokens ->
    (let H (hd Tokens)
      (let Parts (hd (tl H))
        (if (= Parts [])
            (let Next (tl Tokens)
              (if (= Next [])
                  (simple-error "here-string missing target")
                  (if (= (hd (hd Next)) word)
                      [[hstr (hd (tl (hd Next)))] (tl Next)]
                      (simple-error "here-string missing target"))))
            [H (tl Tokens)]))))

\* ===== command ===== *\

\* parse one command -> [Cmd Rest].  Cmd = [Argv Redirs Sub]; an all-empty
   Cmd means "no command here" and consumes nothing. *\
(define sp-parse-command
  { klambda --> klambda }
  Tokens ->
    (if (= Tokens [])
        [[[] [] []] Tokens]
        (if (= (hd (hd Tokens)) lparen)
            (sp-parse-sub-cmd Tokens)
            (sp-parse-cmd-words Tokens [] []))))

\* collect word tokens into Argv and redirect tokens into Redirs. *\
(define sp-parse-cmd-words
  { klambda --> klambda --> klambda --> klambda }
  Tokens ArgvAcc RedirAcc ->
    (if (= Tokens [])
        [[(reverse ArgvAcc) (reverse RedirAcc) []] Tokens]
        (let H (hd Tokens)
          (let Tag (hd H)
            (if (sp-cmd-term? Tag)
                [[(reverse ArgvAcc) (reverse RedirAcc) []] Tokens]
                (if (= Tag word)
                    (sp-parse-cmd-words (tl Tokens)
                                        (cons (hd (tl H)) ArgvAcc)
                                        RedirAcc)
                    (if (= Tag redir)
                        (let Rd (sp-take-redir Tokens)
                          (sp-parse-cmd-words (hd (tl Rd))
                                              ArgvAcc
                                              (cons (hd Rd) RedirAcc)))
                        (if (= Tag hdoc)
                            (sp-parse-cmd-words (tl Tokens)
                                                ArgvAcc
                                                (cons H RedirAcc))
                            (if (= Tag hstr)
                                (let Hs (sp-take-hstr Tokens)
                                  (sp-parse-cmd-words (hd (tl Hs))
                                                      ArgvAcc
                                                      (cons (hd Hs) RedirAcc)))
                                (simple-error "unexpected token in command"))))))))))

\* lparen at command position: collect tokens to the matching rparen, parse
   them as a sub-program, then absorb trailing redirections. *\
(define sp-parse-sub-cmd
  { klambda --> klambda }
  Tokens ->
    (let Sc (sp-collect-sub (tl Tokens) 1 [])
      (let Inner (hd Sc)
        (let Rest (hd (tl Sc))
          (sp-parse-cmd-redirs Rest [] (sp-parse-loop Inner []))))))

\* collect tokens until the rparen matching an already-consumed lparen
   (Depth starts at 1).  Returns [InnerTokens RestAfterRparen]. *\
(define sp-collect-sub
  { klambda --> number --> klambda --> klambda }
  Tokens Depth Acc ->
    (if (= Tokens [])
        (simple-error "unmatched (")
        (let H (hd Tokens)
          (let Tag (hd H)
            (if (= Tag lparen)
                (sp-collect-sub (tl Tokens) (+ Depth 1) (cons H Acc))
                (if (= Tag rparen)
                    (if (= Depth 1)
                        [(reverse Acc) (tl Tokens)]
                        (sp-collect-sub (tl Tokens) (- Depth 1) (cons H Acc)))
                    (sp-collect-sub (tl Tokens) Depth (cons H Acc))))))))

\* after a subshell only redirections may follow. *\
(define sp-parse-cmd-redirs
  { klambda --> klambda --> klambda --> klambda }
  Tokens RedirAcc Sub ->
    (if (= Tokens [])
        [[[] (reverse RedirAcc) Sub] Tokens]
        (let H (hd Tokens)
          (let Tag (hd H)
            (if (sp-cmd-term? Tag)
                [[[] (reverse RedirAcc) Sub] Tokens]
                (if (= Tag redir)
                    (let Rd (sp-take-redir Tokens)
                      (sp-parse-cmd-redirs (hd (tl Rd))
                                           (cons (hd Rd) RedirAcc)
                                           Sub))
                    (if (= Tag hdoc)
                        (sp-parse-cmd-redirs (tl Tokens) (cons H RedirAcc) Sub)
                        (if (= Tag hstr)
                            (let Hs (sp-take-hstr Tokens)
                              (sp-parse-cmd-redirs (hd (tl Hs))
                                                   (cons (hd Hs) RedirAcc)
                                                   Sub))
                            (simple-error "unexpected token after subshell")))))))))

\* ===== pipeline ===== *\

\* parse a pipeline (commands separated by [pipe]) -> [Pipeline Rest].
   Empty commands around a pipe are skipped; nothing is consumed when no
   command is found at all. *\
(define sp-parse-pipeline
  { klambda --> klambda }
  Tokens -> (sp-parse-pipeline-1 Tokens []))

(define sp-parse-pipeline-1
  { klambda --> klambda --> klambda }
  Tokens CmdAcc ->
    (let Cm (sp-parse-command Tokens)
      (let Cmd (hd Cm)
        (let Rest (hd (tl Cm))
          (if (sp-cmd-empty? Cmd)
              (if (sp-next-pipe? Rest)
                  (sp-parse-pipeline-1 (tl Rest) CmdAcc)
                  [(reverse CmdAcc) Tokens])
              (if (sp-next-pipe? Rest)
                  (sp-parse-pipeline-1 (tl Rest) (cons Cmd CmdAcc))
                  [(reverse (cons Cmd CmdAcc)) Rest]))))))

\* ===== program (chains) ===== *\

\* parse a whole program: pipelines joined by ; / && / ||.  The op says how
   THIS chain combines with the previous one; the first chain is seq.
   Stops at end of tokens or at a stray rparen (subshell caller handles). *\
(define sp-parse-loop
  { klambda --> klambda --> klambda }
  Tokens Chains ->
    (if (= Tokens [])
        (reverse Chains)
        (if (= (hd (hd Tokens)) rparen)
            (reverse Chains)
            (let Pr (sp-parse-pipeline Tokens)
              (let Pipeline (hd Pr)
                (let Rest (hd (tl Pr))
                  (if (= Pipeline [])
                      (sp-parse-opstep Tokens Chains)
                      (sp-parse-opstep Rest
                                       (cons [(intern "seq") Pipeline]
                                             Chains)))))))))

\* Tokens start with a chain operator (or we are done).  Consecutive
   operators collapse with LAST-wins; a trailing operator with nothing
   after it (end or rparen) is dropped. *\
(define sp-parse-opstep
  { klambda --> klambda --> klambda }
  Tokens Chains ->
    (if (= Tokens [])
        (reverse Chains)
        (if (= (hd (hd Tokens)) rparen)
            (reverse Chains)
            (let Sk (sp-skip-ops Tokens)
              (let Op (hd Sk)
                (let After (hd (tl Sk))
                  (if (= Op false)
                      (simple-error "expected ; && || or end of command")
                      (if (= After [])
                          (reverse Chains)
                          (if (= (hd (hd After)) rparen)
                              (reverse Chains)
                              (let Pr (sp-parse-pipeline After)
                                (let Pipeline (hd Pr)
                                  (let Rest (hd (tl Pr))
                                    (if (= Pipeline [])
                                        (simple-error "empty command after operator")
                                        (sp-parse-opstep Rest
                                                         (cons [Op Pipeline]
                                                               Chains)))))))))))))))

\* consume consecutive chain operators, LAST-wins; returns [Op Rest] with
   Op = false when the head is not a chain operator. *\
(define sp-skip-ops
  { klambda --> klambda }
  Tokens -> (sp-skip-ops-1 Tokens false))

(define sp-skip-ops-1
  { klambda --> klambda --> klambda }
  Tokens LastOp ->
    (if (= Tokens [])
        [LastOp Tokens]
        (let Tag (hd (hd Tokens))
          (if (sp-chain-op? Tag)
              (sp-skip-ops-1 (tl Tokens)
                             (if (= Tag semi)
                                 (intern "seq")
                                 (if (= Tag andand)
                                     (intern "and")
                                     (intern "or"))))
              [LastOp Tokens]))))

\* ===== driver ===== *\

(define sp-parse
  { klambda --> klambda }
  [Tokens Pending] ->
    (if (= Pending [])
        [ok (sp-parse-loop Tokens [])]
        [pending Pending]))

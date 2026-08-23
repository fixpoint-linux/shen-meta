(tc -)

\* shell.shen - shpar-p2 U5: the shell driver.
   Boots AFTER shlex.shen / shparse.shen / shexpand.shen (shensh.c boot list,
   dependency order - the HM sig table accumulates across files) and drives
   them: sp-lex -> sp-parse -> shx-plan -> C exec-plan.  There is NO /bin/sh
   anywhere: exec-plan decodes the plan tree and forks/execvp's natively
   (see the plan-runner section in vm/zincvm.c).
   Builtins kept Shen-level because they must mutate the PARENT process:
   cd, pwd, setenv/export, exit.  echo/true/false/:/cd/pwd additionally
   exist as C CHILD builtins (apply post-redirect inside forked children)
   so they behave uniformly inside pipelines and subshells.
   Heredoc protocol: when a line ends inside an unterminated heredoc the
   parser returns [pending Delims] and shell-eval-line returns the SYMBOL
   sh-continue; the shensh.c REPL then accumulates further input lines and
   re-evaluates the whole buffer until the delimiter closes.  Parsing never
   leaves Shen. *\
\* NOTE: the old /bin/sh path (sh-run-command via exec-command, sh-run-pipe
   via shell-pipe, sh-split-pipe, sh-tag-stages, sh-echo) and the sh-* string
   helpers are RETIRED - shlex.shen carries the sp-* copies. *\
\* NOTE: chain-op symbols etc are lowercase CONSTANTS; never place bare
   and/or/append (KLambda macros) in list literals - use intern. *\

(define sh-prompt
  { --> string }
  -> (cn (getcwd 0) "> "))

\* first whitespace-delimited token of S at Start (setenv NAME parsing). *\
(define sh-token
  { string --> number --> string }
  S Start -> (let Sp (sp-find-ch S Start 32)
               (if (= Sp -1) (sp-trim S Start) (sp-substr S Start Sp))))

(define sh-cd
  { string --> string }
  S -> (let I (sp-skipws S 3)
         (if (cd (sp-trim S I)) "" "cd failed")))

(define sh-pwd
  { --> string }
  -> (getcwd 0))

\* setenv NAME VALUE  /  setenv NAME=VALUE  /  export NAME=VALUE. *\
(define sh-setenv
  { string --> number --> string }
  S Start -> (let I (sp-find-ch S Start 61)
               (if (= I -1)
                   (let Sp (sp-find-ch S Start 32)
                     (if (= Sp -1)
                         "usage: setenv NAME VALUE or NAME=VALUE"
                         (if (setenv (sh-token S Start) (sp-trim S (+ Sp 1)))
                             "" "setenv failed")))
                   (if (setenv (sp-substr S Start I) (sp-trim S (+ I 1)))
                       "" "setenv failed"))))

\* Display string for a finished program: the captured stdout when the
   program produced any; else the captured stderr when it produced any
   (so e.g. ENOENT messages are visible); else "exit N" on failure, ""
   on success.  (Plan D-U5 says stdout / "exit N"; surfacing stderr when
   stdout is empty is an intentional improvement - a shell shows error
   text.)  Values are the TAGGED exec-plan result elements; = and str
   operate on them transparently at interp level. *\
(define sh-display
  { number --> string --> string --> string }
  Exit Out Err ->
    (if (= Out "")
        (if (= Err "")
            (if (= Exit 0) "" (cn "exit " (str Exit)))
            Err)
        Out))

\* Run an expanded plan tree: exec-plan returns the tagged
   [exit stdout stderr]; *sh-exit-code* records the exit for $?. *\
(define sh-run-plan
  { klambda --> klambda }
  Plan -> (let Res (exec-plan Plan)
            (let Exit (hd Res)
              (let Out (hd (tl Res))
                (let Err (hd (tl (tl Res)))
                  (let Ign (set *sh-exit-code* Exit)
                    (sh-display Exit Out Err)))))))

\* [ok Ast] -> run the expanded plan;  [pending Delims] -> symbol
   sh-continue (the shensh.c REPL accumulates more input and re-evals). *\
(define sh-run-parsed
  { klambda --> klambda }
  [ok Ast] -> (sh-run-plan (shx-plan Ast))
  [pending Delims] -> sh-continue)

\* lex -> parse -> expand -> exec-plan for every non-builtin line.
   Lexer/parser rejects (backtick, $(), bare &, ...) throw simple-error,
   caught by shell-eval-line's trap-error wrapper. *\
(define sh-exec-line
  { string --> klambda }
  S -> (sh-run-parsed (sp-parse (sp-lex S))))

\* Shen-level builtins (parent-process effects): cd / pwd / setenv /
   export / exit.  Everything else - including echo, true, false, : -
   goes through exec-plan (child builtins + external commands). *\
(define sh-builtin
  { string --> klambda }
  S -> (let Ws (sp-skipws S 0)
         (let Cmd (sh-token S Ws)
           (if (= Cmd "cd")
               (sh-cd S)
               (if (= Cmd "pwd")
                   (sh-pwd)
                   (if (= Cmd "setenv")
                       (sh-setenv S 7)
                       (if (= Cmd "export")
                           (sh-setenv S 7)
                           (if (= Cmd "exit")
                               (if (set *sh-exit* true) exit exit)
                               (sh-exec-line S)))))))))

(define shell-eval-line
  { string --> klambda }
  S -> (trap-error (sh-builtin S) (lambda E (cn "error: " (error-to-string E)))))

(tc -)

\* shexpand.shen - shpar-p2 U4: $VAR expansion + field splitting + plan build.
   shx-word   : word (list part) -> (list string) argv fields.
                lit -> append; quoted var -> append whole value (no split);
                unquoted var -> field split on space/tab/newline: chars
                before the first ws close the current field, middle segments
                become their own fields, the trailing segment continues the
                current field; a word that never opened a field (only
                unquoted vars, all empty) produces NO fields (removed).
   shx-redir  : redirect target, expanded with NO field split; any
                field-split whitespace in the result is an
                'ambiguous redirect' (simple-error).
   shx-plan   : AST -> exec-plan plan tree.  The tree is RAW (plain
                strings / numbers / interned symbols) - the metacircular
                interp auto-tags primitive results (U1 finding); NEVER
                hand-tag.  Plan encoding (decode_redir/decode_cmd in
                zig/src/vm/execplan.zig): Chain [op Pipeline] op in {seq,and,or};
                Cmd [Argv Redirs Sub] with Sub = [] plain | nested plan;
                Redir [op fd target] with op in {in,out,append,dup,hdoc,
                hstr} (gt->out, gtgt->append, lt->in), fd 0 for in/hdoc/
                hstr and 1|2 for out/append/dup, dup target = NUMBER 1|2.
   $VAR reads getenv ('' when unset); $? reads *sh-exit-code* (stretch,
   '0' when unbound).  The one-char specials $0-$9 $# $@ $* $$ $! $- are
   positional parameters (see the block below).  Depends on shlex.shen
   (sp-* helpers). *\

\* ===== variable values ===== *\

\* ===== positional parameters (v1 semantics) =====

   Boot globals set by shensh.c BEFORE the shell sources load (namespace-1
   values table, read via `value`):  *sh-argv0* (string, $0), *sh-posargs*
   (list of strings, $1..$9), *sh-flags* (string, $-).  An unbound global
   evaluates to its SYMBOL (value does not throw), so discriminate by type
   and fall back to honest defaults.
   $0      = how the shell was invoked: argv[0] for the interactive REPL;
             in -c mode the first operand after the command string, else
             argv[0] (bash convention).
   $1..$9  = positional args: interactive REPL has none; shensh -c 'cmd'
             NAME a b -> $1=a $2=b (only the first 9; ${10} is NOT
             supported - it lexes but resolves as an ordinary name).
   $#      = arg count (decimal string).
   $*      = args joined with single spaces; unquoted $* then field-splits
             (POSIX join-then-split), quoted "$*" is ONE field.
   $@      = unquoted: same joined+split value as $* (v1 tractable;
             diverges from POSIX only when an arg itself contains ws);
             quoted "$@" = SEPARATE fields, one per arg (see shx-at-fold).
   $$      = the shell's live PID via the getpid C prim.
   $!      = "" - v1 has no background jobs; a shell that never
             backgrounded anything has no last-background PID (matches
             bash, where $! with no jobs ever run expands empty).
   $-      = option flags: "i" for the interactive REPL, "c" in -c mode -
             the only two states shensh actually has (no h/B: there is no
             hashall toggle and no brace expansion). *\
(define shx-posargs
  { --> klambda }
  -> (let V (trap-error (value *sh-posargs*) (lambda E []))
       (if (cons? V) V [])))

(define shx-argv0
  { --> string }
  -> (let V (trap-error (value *sh-argv0*) (lambda E "shensh"))
       (if (string? V) V "shensh")))

(define shx-flags
  { --> string }
  -> (let V (trap-error (value *sh-flags*) (lambda E ""))
       (if (string? V) V "")))

\* count of positional args. *\
(define shx-posargs-count
  { --> number }
  -> (shx-count (shx-posargs) 0))

(define shx-count
  { klambda --> number --> number }
  L N -> (if (= L []) N (shx-count (tl L) (+ N 1))))

\* $N for N in 1..9 (caller checks); 1-based, "" past the end. *\
(define shx-posarg
  { string --> string }
  N -> (shx-nth (shx-posargs) (- (string->n N) 48)))

(define shx-nth
  { klambda --> number --> string }
  L I -> (if (= L [])
             ""
             (if (= I 1)
                 (hd L)
                 (shx-nth (tl L) (- I 1)))))

\* $@/$* as a scalar: args joined with single spaces. *\
(define shx-posjoin
  { --> string }
  -> (shx-join-sp (shx-posargs) ""))

(define shx-join-sp
  { klambda --> string --> string }
  L Acc -> (if (= L [])
               Acc
               (if (= Acc "")
                   (shx-join-sp (tl L) (hd L))
                   (shx-join-sp (tl L) (cn (cn Acc " ") (hd L))))))

\* fold QUOTED "$@" (POSIX 2.5.2 separate fields): with args A1..An and
   current state [Cur Open], A1 joins Cur (opening the field), A2..A(n-1)
   become standalone fields, An stays open as the new Cur.  One arg
   behaves exactly like a normal quoted variable; ZERO args leave the
   state untouched (a word that is only an empty "$@" makes no field).
   -> [Cur Open EmitFields] like shx-uv. *\
(define shx-at-fold
  { klambda --> string --> boolean --> klambda }
  Args Cur Open ->
    (if (= Args [])
        [Cur Open []]
        (shx-at-args Args (cn Cur (hd Args)))))

(define shx-at-args
  { klambda --> string --> klambda }
  Args Acc ->
    (if (= (tl Args) [])
        [Acc true []]
        (let More (shx-at-args (tl Args) (hd (tl Args)))
          (let NewCur (hd More)
            (let NewOpen (hd (tl More))
              (let Mids (hd (tl (tl More)))
                [NewCur NewOpen (cons Acc Mids)]))))))

(define shx-var-value
  { string --> string }
  Name -> (if (= Name "?")
              (shx-exit-code)
              (if (= Name "0")
                  (shx-argv0)
                  (if (shx-posnum? Name)
                      (shx-posarg Name)
                      (if (= Name "#")
                          (str (shx-posargs-count))
                          (if (or (= Name "@") (= Name "*"))
                              (shx-posjoin)
                              (if (= Name "$")
                                  (str (getpid 0))
                                  (if (= Name "!")
                                      ""
                                      (if (= Name "-")
                                          (shx-flags)
                                          (getenv Name))))))))))

\* a single-char digit 1-9 (positional parameter index).  Length-checked:
   ${10} must NOT resolve as $1. *\
(define shx-posnum?
  { string --> boolean }
  C -> (if (= (sp-len C) 1)
          (let N (string->n C) (and (>= N 49) (<= N 57)))
          false))

\* $? reads *sh-exit-code* (stretch).  An unbound global evaluates to the
   SYMBOL *sh-exit-code* (value does not throw), so discriminate by type:
   number -> decimal string, string -> as-is, anything else (unbound) -> 0. *\
(define shx-exit-code
  { --> string }
  -> (let V (trap-error (value *sh-exit-code*) (lambda E "0"))
       (if (string? V)
           V
           (if (number? V) (str V) "0"))))

\* ===== field splitting ===== *\

\* field-split whitespace: space, tab, newline. *\
(define shx-ws?
  { string --> boolean }
  C -> (or (= C " ") (or (= C (n->string 9)) (= C (n->string 10)))))

\* index of the first ws char in V at/after I, else -1. *\
(define shx-scan-ws
  { string --> number --> number }
  V I -> (if (sp-at-end V I)
             -1
             (if (shx-ws? (sp-ch V I))
                 I
                 (shx-scan-ws V (+ I 1)))))

\* walk Tail (which begins with ws): complete segments are emitted as
   fields; a trailing segment (no ws after it) is returned still open.
   -> [Fields LastSeg LastOpen] *\
(define shx-tail
  { string --> klambda }
  T -> (shx-tail-skip T 0 []))

(define shx-tail-skip
  { string --> number --> klambda --> klambda }
  T I Fields ->
    (if (sp-at-end T I)
        [(reverse Fields) "" false]
        (if (shx-ws? (sp-ch T I))
            (shx-tail-skip T (+ I 1) Fields)
            (shx-tail-seg T (+ I 1) (sp-ch T I) Fields))))

(define shx-tail-seg
  { string --> number --> string --> klambda --> klambda }
  T I Seg Fields ->
    (if (sp-at-end T I)
        [(reverse Fields) Seg true]
        (if (shx-ws? (sp-ch T I))
            (shx-tail-skip T (+ I 1) (cons Seg Fields))
            (shx-tail-seg T (+ I 1) (cn Seg (sp-ch T I)) Fields))))

\* fold an UNQUOTED variable value into the field state -> [Cur Open Emit].
   No ws in Val: append (an empty value opens nothing).  Else: the chars
   before the first ws close the current field (if it is open or non-empty),
   middle segments are emitted, and the trailing segment stays open. *\
(define shx-uv
  { string --> string --> boolean --> klambda }
  Val Cur Open ->
    (let W (shx-scan-ws Val 0)
      (if (= W -1)
          [(cn Cur Val) (if (= Val "") Open true) []]
          (let Pre (sp-substr Val 0 W)
            (let Tail (sp-trim Val W)
              (let Cur1 (if (= Pre "") Cur (cn Cur Pre))
                (let Emit0 (if (if (= Pre "") Open true) [Cur1] [])
                  (let Tl (shx-tail Tail)
                    (let Mids (hd Tl)
                      (let Last (hd (tl Tl))
                        (let LastOpen (hd (tl (tl Tl)))
                          [Last LastOpen (shx-append Emit0 Mids)])))))))))))

(define shx-append
  { klambda --> klambda --> klambda }
  [] B -> B
  [X | R] B -> (cons X (shx-append R B)))

\* ===== word expansion ===== *\

\* expand ONE word (list of parts) -> its argv fields. *\
(define shx-word
  { klambda --> klambda }
  Parts -> (shx-word-1 Parts "" false []))

(define shx-word-1
  { klambda --> string --> boolean --> klambda --> klambda }
  Parts Cur Open Fields ->
    (if (= Parts [])
        (if Open
            (reverse (cons Cur Fields))
            (reverse Fields))
        (let P (hd Parts)
          (if (= (hd P) lit)
              (shx-word-1 (tl Parts) (cn Cur (hd (tl P))) true Fields)
              (let Name (hd (tl P))
                (if (and (= Name "@") (hd (tl (tl P))))
                    (let At (shx-at-fold (shx-posargs) Cur Open)
                      (shx-word-1 (tl Parts)
                                  (hd At)
                                  (hd (tl At))
                                  (sp-prepend-list (hd (tl (tl At))) Fields)))
                    (let Val (shx-var-value Name)
                      (if (hd (tl (tl P)))
                          (shx-word-1 (tl Parts) (cn Cur Val) true Fields)
                          (let Uv (shx-uv Val Cur Open)
                            (shx-word-1 (tl Parts)
                                        (hd Uv)
                                        (hd (tl Uv))
                                        (sp-prepend-list (hd (tl (tl Uv)))
                                                         Fields)))))))))))

\* ===== redirect target expansion ===== *\

(define shx-redir
  { klambda --> string }
  Parts -> (let S (shx-redir-1 Parts "")
             (if (shx-has-ws S)
                 (simple-error "ambiguous redirect")
                 S)))

(define shx-redir-1
  { klambda --> string --> string }
  Parts Acc ->
    (if (= Parts [])
        Acc
        (let P (hd Parts)
          (if (= (hd P) lit)
              (shx-redir-1 (tl Parts) (cn Acc (hd (tl P))))
              (shx-redir-1 (tl Parts)
                           (cn Acc (shx-var-value (hd (tl P)))))))))

(define shx-has-ws
  { string --> boolean }
  S -> (shx-has-ws-1 S 0))

(define shx-has-ws-1
  { string --> number --> boolean }
  S I -> (if (sp-at-end S I)
             false
             (if (shx-ws? (sp-ch S I))
                 true
                 (shx-has-ws-1 S (+ I 1)))))

\* ===== AST -> plan tree ===== *\

(define shx-plan
  { klambda --> klambda }
  Ast -> (shx-prog Ast))

(define shx-prog
  { klambda --> klambda }
  Ast -> (if (= Ast [])
             []
             (cons (shx-chain (hd Ast)) (shx-prog (tl Ast)))))

(define shx-chain
  { klambda --> klambda }
  Chain -> [(hd Chain) (shx-pipe (hd (tl Chain)))])

(define shx-pipe
  { klambda --> klambda }
  Pipe -> (if (= Pipe [])
              []
              (cons (shx-cmd (hd Pipe)) (shx-pipe (tl Pipe)))))

\* Sub = [] plain | nested Program; shx-prog [] = [] keeps that. *\
(define shx-cmd
  { klambda --> klambda }
  Cmd -> [(shx-argv (hd Cmd))
          (shx-redirs (hd (tl Cmd)))
          (shx-prog (hd (tl (tl Cmd))))])

\* NOTE: shx-append (order-preserving), NOT sp-prepend-list - the latter
   REVERSES its first argument, which scrambled multi-field words. *\
(define shx-argv
  { klambda --> klambda }
  Argv -> (if (= Argv [])
              []
              (shx-append (shx-word (hd Argv)) (shx-argv (tl Argv)))))

(define shx-redirs
  { klambda --> klambda }
  Redirs -> (if (= Redirs [])
                []
                (cons (shx-redir-node (hd Redirs))
                      (shx-redirs (tl Redirs)))))

\* [redir Kind Fd Parts] -> [op Fd Target]; [hdoc D B S] -> [hdoc 0 B];
   [hstr Parts] -> [hstr 0 Target]. *\
(define shx-redir-node
  { klambda --> klambda }
  Rd -> (if (= (hd Rd) redir)
            [(shx-redir-op (hd (tl Rd)))
             (hd (tl (tl Rd)))
             (shx-redir-target (hd (tl Rd))
                               (shx-redir (hd (tl (tl (tl Rd))))))]
            (if (= (hd Rd) hdoc)
                [(intern "hdoc") 0 (hd (tl (tl Rd)))]
                [(intern "hstr") 0 (shx-redir (hd (tl Rd)))])))

(define shx-redir-op
  { klambda --> klambda }
  Kind -> (if (= Kind gt)
              (intern "out")
              (if (= Kind gtgt)
                  (intern "append")
                  (if (= Kind lt)
                      (intern "in")
                      (intern "dup")))))

\* the dup target must be the NUMBER 1|2 (decode_redir requires it);
   Target is klambda so the number branches unify with the passthrough. *\
(define shx-redir-target
  { klambda --> klambda --> klambda }
  Kind Target -> (if (= Kind dup)
                     (if (= Target "1")
                         1
                         (if (= Target "2")
                             2
                             (simple-error "bad fd-dup target")))
                     Target))

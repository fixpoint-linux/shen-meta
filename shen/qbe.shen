(tc -)
\* =============================================================================
   qbe.shen - QBE backend for the resolved ZINC bytecode (Slice 3).

   lower : symbol --> klambda --> (list symbol) --> string
     Name  Body  ClosureSet

   Body is the RESOLVED closure body (compile-zinc output, a flat list of
   instructions with ABSOLUTE jmp/jmpf targets and labels stripped).  It is
   the C1 inside the `[cur C1]` wrapper that nat->csexp serialises.

   The lowering is a stack->SSA transform over the pointer-ABI runtime
   (vm/qbe_shims.c): every ZINC temp is a `l` = Value* into a per-frame
   `alloc8 40` slot.  `access`/`let`/`endlet`/`grab` are pure compile-time
   Env-list manipulations (no QBE emitted); only literals, prims, calls,
   branches and phi emit instructions.

   CFG recovery: leaders = {0} + jmp/jmpf targets + post-terminator/fall-through.
   Blocks are processed in increasing start order (all ZINC jumps are forward -
   loops are recursion, `if`/`cond` produce forward jumps only).  At a join the
   compile-time (Stk, Env) slots are reconciled with QBE phi nodes.

   Env de Bruijn convention (matches lookup_env, zincvm.c): Env list head =
   index 0 = the NEWEST binding.  A k-arg closure's entry Env is
   [%a{k-1} ... %a0] (access 0 = rightmost arg), because apply builds
   env = captured ++ [leftmost .. rightmost] and lookup_env(n)=env[len-1-n].
   ============================================================================= *\

\* -------------------------- mutable lowering state -------------------------- *\
(set qbe-temp-count 0)   \* next %tN index (Value* temps, `l`) *\
(set qbe-wcount 0)       \* next %cN index (word temps, `w`) *\
(set qbe-data-count 0)   \* next $dN data literal index *\
(set qbe-datas [])       \* [ [name content] ... ] collected data defs *\
(set qbe-lines [])       \* current block's emitted lines (reversed) *\
(set qbe-block-lines []) \* [ [start lines-reversed] ... ] (reversed) *\
(set qbe-allocs [])
(set qbe-temp-names [])  \* bare %tN names of the alloc8 40 slots (for per-frame GC rooting) *\
(set qbe-free-slots [])   \* L1: dead alloc8 40 slot names available for liveness reuse *\
(set qbe-pending-copies []) \* L1: [[Dst Src] ...] phi copy_value pairs for the merge in progress *\
(set qbe-merge-blocked [])  \* L1: names live at any predecessor exit of the merge in progress *\
(set qbe-wm-temp "")     \* function-entry gc_root_watermark() temp name (read at ret sites) *\
(set qbe-zero-tmp false)
(set qbe-zero-init "")
(set qbe-preds [])       \* [ [target pred state] ... ] CFG edges *\
(set qbe-cur-tag-count 0) \* next cur-body tag (GLOBAL, monotonic) *\
(set qbe-extra-fns [])     \* cur-body fn strings (per closure) *\
(set qbe-trap-shims [])    \* [[BodyTag HandlerTag Ncap] ...] trap shim registrations *\

\* Shen does NOT interpret \\n/\\\" escapes in string literals (they are
   literal 2-char sequences), so real newline / double-quote chars must be
   built from ASCII codes via n->string. *\
(set qbe-nl (n->string 10))   \* newline *\
(set qbe-dq (n->string 34))   \* double-quote *\

\* -------------------------- tiny string/list helpers -------------------------- *\

(define qbe-join { (list string) --> string }
  [] -> ""
  [S] -> S
  [S | R] -> (cn S (qbe-join R)))

(define qbe-strlen { string --> number }
  "" -> 0
  S -> (+ 1 (qbe-strlen (tlstr S))))

(define qbe-nth0 { number --> (list A) --> A }
  0 [H | _] -> H
  N [_ | T] -> (qbe-nth0 (- N 1) T)
  N L -> (simple-error (cn (cn "qbe: list index out of range: " (str N)) (cn " in " (str L)))))

(define qbe-env-ref { number --> (list A) --> A }
  N Env -> (qbe-nth0 N Env))

\* access N: resolve the enclosing env's slot N (de Bruijn, 0 = newest), OR —
   if N is past the env's end — emit a fresh number-0 slot and return its temp.
   This mirrors lookup_env (zincvm.c:2150), which returns a VAL_NUMBER 0 sentinel
   for out-of-bounds access instead of erroring; many bundled closures rely on
   that sentinel (pattern-matching / cond code reads past its bindings). *\
(define qbe-env-access { number --> (list string) --> (list zinc-value) --> string }
  N Env Stk -> (if (>= N (length Env))
               (let Z (qbe-slot Stk Env)
                 (do (qbe-emit (qbe-call "val_number_into" [(cn "l " Z) "l 0"]))
                     Z))
               (qbe-env-ref N Env)))

\* -------------------------- name mangling -------------------------- *\

\* Map a symbol's printed name to a valid C identifier (shared char mapping
   with vm/qbe-prims.list).  Exact special-case table for the arithmetic ops,
   then a char scan handling ->, <-, ?, ., @, !, -. *\
(define qbe-ident { string --> string }
  "+" -> "plus"   "-" -> "minus"  "*" -> "mul"  "/" -> "div"
  "=" -> "eq"     ">" -> "gt"     "<" -> "lt"   ">=" -> "ge"  "<=" -> "le"
  S -> (qbe-ident-h S ""))

(define qbe-ident-h { string --> string --> string }
  "" Acc -> Acc
  S Acc -> (qbe-ident-h (tlstr (tlstr S)) (cn Acc "_to_")) where (and (> (qbe-strlen S) 1) (= "->" (cn (hdstr S) (hdstr (tlstr S)))))
  S Acc -> (qbe-ident-h (tlstr (tlstr S)) (cn Acc "_from_")) where (and (> (qbe-strlen S) 1) (= "<-" (cn (hdstr S) (hdstr (tlstr S)))))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "p")) where (= "?" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc ".")) where (= "." (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "at")) where (= "@" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "bang")) where (= "!" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "_")) where (= "-" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "eq")) where (= "=" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "plus")) where (= "+" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "mul")) where (= "*" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "div")) where (= "/" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "lt")) where (= "<" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "gt")) where (= ">" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc "pct")) where (= "%" (hdstr S))
  S Acc -> (qbe-ident-h (tlstr S) (cn Acc (hdstr S))))

(define qbe-clo-name { symbol --> string }
  Name -> (let M (cn "clo_" (qbe-ident (str Name)))
           (if (> (qbe-strlen M) 30)
               (qbe-short-clo M)
               M)))

\* ----------------------------------------------------------------------------
   QBE identifier-length guard.  QBE's lexer (vendor/qbe, NString=32) rejects
   identifiers longer than 31 chars, INCLUDING the leading `$` on a global
   symbol (so the mangled `clo_...` name must be <=30 chars).  The readable
   mangle above is injective (distinct closure names -> distinct identifiers,
   since `.` and `-` map to different chars) but some closure names (long
   tc-hm / shen.* aliases) mangle past 30.  For those we keep the first 21
   chars of the mangle and append a "_" + 8-hex FNV-style hash of the FULL
   mangle, giving a unique 30-char identifier (`$` -> 31 total).  Only the
   readable form is used for the (short) differential driver names, which stay
   unchanged.
   ---------------------------------------------------------------------------- *\
(define qbe-take { number --> string --> string }
  0 _ -> ""
  N S -> (cn (hdstr S) (qbe-take (- N 1) (tlstr S))))

(define qbe-hash { string --> number }
  S -> (qbe-hash-h S 5381))
(define qbe-hash-h { string --> number --> number }
  "" H -> H
  S H -> (qbe-hash-h (tlstr S) (mod (+ (* H 33) (string->n (hdstr S))) 4294967296)))

(define qbe-hex { number --> string }
  N -> (qbe-hex-h N ""))
(define qbe-hex-h { number --> string --> string }
  N Acc -> (let D (qbe-hex-digit (mod N 16))
             (if (< N 16) (cn D Acc) (qbe-hex-h (div N 16) (cn D Acc)))))
(define qbe-hex-digit { number --> string }
  N -> (if (< N 10) (str N) (n->string (+ 87 N))))

(define qbe-pad-left { number --> string --> string --> string }
  N P S -> (if (>= (qbe-strlen S) N) S (qbe-pad-left N P (cn P S))))

(define qbe-hex8 { number --> string }
  N -> (qbe-pad-left 8 "0" (qbe-hex N)))

(define qbe-short-clo { string --> string }
  M -> (cn (qbe-take 21 M) (cn "_" (qbe-hex8 (qbe-hash M)))))

\* -------------------------- flat->nested conversion -------------------------- *\

\* The resolved klambda (compile-zinc output) is a FLAT atom stream: each
   opcode is a symbol, and operand opcodes (access/global/jmpf/jmp/number/
   string/symbol/boolean/prim) are immediately followed by their operand atom.
   qbe-nest converts it to the nested [op operand] form the rest of the lowerer
   consumes.  `cur` (deferred to Slice 5) is rejected. *\
(define qbe-nest { klambda --> (list zinc-code) }
  [] -> []
  [grab | C] -> [grab | (qbe-nest C)]
  [pushmark | C] -> [pushmark | (qbe-nest C)]
  [apply | C] -> [apply | (qbe-nest C)]
  [appterm | C] -> [appterm | (qbe-nest C)]
  [return | C] -> [return | (qbe-nest C)]
  [letz | C] -> [letz | (qbe-nest C)]
  [endlet | C] -> [endlet | (qbe-nest C)]
  [access N | C] -> [[access N] | (qbe-nest C)]
  [global G | C] -> [[global G] | (qbe-nest C)]
  [jmpf L | C] -> [[jmpf L] | (qbe-nest C)]
  [jmp L | C] -> [[jmp L] | (qbe-nest C)]
  [number N | C] -> [[number N] | (qbe-nest C)]
  [string S | C] -> [[string S] | (qbe-nest C)]
  [symbol S | C] -> [[symbol S] | (qbe-nest C)]
  [boolean B | C] -> [[boolean B] | (qbe-nest C)]
  [prim P | C] -> [[prim P] | (qbe-nest C)]
  [cur C1 | C] -> [[cur (qbe-nest C1)] | (qbe-nest C)]
  [X | _] -> (simple-error (cn "qbe-nest: unknown op " (str X))))

\* ----------------------------------------------------------------------------
   Defunctionalized trap-error peephole.

   Every `cur` site in the reduced bundle is an adjacent
   `[cur C1] [cur C2] [prim trap-error]` triple (handler+body).  We rewrite it
   to a single `[trap C1 C2]` instruction, which qbe-step compiles to a direct
   native call into a generated per-pair C shim (setjmp/longjmp) that runs the
   two cur bodies natively as `$b_<tag>` functions.  A `cur` NOT immediately
   followed by `cur` + `trap-error` is a dynamic closure use we cannot compile
   (defensive simple-error; the reduced bundle has none).  Recurses into nested
   cur bodies / trap pairs so nested trap-error lowers too.
   ---------------------------------------------------------------------------- *\
(define qbe-pair-traps { (list zinc-code) --> (list zinc-code) }
  [] -> []
  [[cur C1] [cur C2] [prim trap-error] | R] ->
    [[trap (qbe-pair-traps C1) (qbe-pair-traps C2)] | (qbe-pair-traps R)]
  [[cur _] | _] -> (simple-error "qbe: cur not in a cur/cur/trap-error pair")
  [I | R] -> [I | (qbe-pair-traps R)])

\* Collapsing a cur/cur/trap-error triple (3 flat instructions) into one
   [trap] instruction shifts every later absolute jmpf/jmp target by -2.
   qbe-renumber rebuilds the old->new instruction index map and rewrites the
   targets.  Recurses into nested [trap C1 C2] so nested cur bodies renumber
   at their own level (identity for the bundle's cur bodies, which have no
   nested cur). *\
(define qbe-renumber { (list zinc-code) --> (list zinc-code) }
  Code -> (qbe-renumber-h Code (qbe-renumber-map Code 0 0)))

(define qbe-renumber-map { (list zinc-code) --> number --> number --> (list (list number number)) }
  [] _ _ -> []
  [[trap _ _] | R] J K -> [[J K] [(+ J 1) K] [(+ J 2) K] | (qbe-renumber-map R (+ J 3) (+ K 1))]
  [_ | R] J K -> [[J K] | (qbe-renumber-map R (+ J 1) (+ K 1))])

(define qbe-renumber-h { (list zinc-code) --> (list (list number number)) --> (list zinc-code) }
  [] _ -> []
  [[trap C1 C2] | R] Map -> [[trap (qbe-renumber C1) (qbe-renumber C2)] | (qbe-renumber-h R Map)]
  [[jmpf L] | R] Map -> [[jmpf (qbe-renum-lookup L Map)] | (qbe-renumber-h R Map)]
  [[jmp L] | R] Map -> [[jmp (qbe-renum-lookup L Map)] | (qbe-renumber-h R Map)]
  [I | R] Map -> [I | (qbe-renumber-h R Map)])

(define qbe-renum-lookup { number --> (list (list number number)) --> number }
  L Map -> (let P (assoc L Map)
             (if (empty? P)
                 (simple-error (cn "qbe: renumber: jump target out of range " (str L)))
                 (hd (tl P)))))

\* -------------------------- prim info -------------------------- *\

(define qbe-prim? { symbol --> boolean }
  P -> (not (empty? (assoc P (value qbe-prim-info)))))

(define qbe-prim-mangled { symbol --> string }
  P -> (str (hd (tl (assoc P (value qbe-prim-info))))))

(define qbe-prim-arity { symbol --> number }
  P -> (hd (tl (tl (assoc P (value qbe-prim-info))))))

\* -------------------------- emit machinery -------------------------- *\

(define qbe-emit { string --> string }
  Line -> (do (set qbe-lines (cons Line (value qbe-lines))) Line))

(define qbe-fresh { --> string }
  -> (let N (value qbe-temp-count)
       (do (set qbe-temp-count (+ N 1))
           (cn "%t" (str N)))))

(define qbe-c-fresh { --> string }
  -> (let N (value qbe-wcount)
       (do (set qbe-wcount (+ N 1))
           (cn "%c" (str N)))))

\* Allocate a 40-byte Value slot, return its temp name.  L1 liveness reuse: a
   name is recycled from qbe-free-slots only when it is dead on BOTH the
   current abstract stack (Stk) and the current abstract environment (Env) —
   a name still in Env stays reachable through a later access N, so reusing
   it would silently clobber the let-bound value it still names. *\
(define qbe-slot { (list zinc-value) --> (list zinc-value) --> string }
  Stk Env -> (let Pick (qbe-pick-free Stk Env (value qbe-free-slots))
               (if (= Pick "")
                   (qbe-slot-fresh)
                   (do (set qbe-free-slots (qbe-remove-one Pick (value qbe-free-slots)))
                       Pick))))

\* Fresh (never-reused) alloc8 40 slot — also used for phi-copy destinations. *\
(define qbe-slot-fresh { --> string }
  -> (let T (qbe-fresh)
       (do (set qbe-allocs (cons (qbe-join [T " =l alloc8 40"]) (value qbe-allocs)))
           (set qbe-temp-names (cons T (value qbe-temp-names)))
           T)))

\* First free slot name dead on Stk and Env; "" when none is reusable. *\
(define qbe-pick-free { (list zinc-value) --> (list zinc-value) --> (list string) --> string }
  _ _ [] -> ""
  Stk Env [C | R] -> (qbe-pick-free Stk Env R) where (element? C Stk)
  Stk Env [C | R] -> (qbe-pick-free Stk Env R) where (element? C Env)
  _ _ [C | _] -> C)

\* Remove the first occurrence of X from L (free-list entries may duplicate). *\
(define qbe-remove-one { string --> (list string) --> (list string) }
  _ [] -> []
  X [X | R] -> R
  X [H | R] -> [H | (qbe-remove-one X R)])

\* Return a consumed slot name to the free pool.  Only real alloc8 40 slots
   (members of qbe-temp-names) are recyclable — phi pointer temps and params
   %a0..%aN / %out are not.  Names still in Env are skipped: they remain
   reachable via access N. *\
(define qbe-free-name { zinc-value --> (list zinc-value) --> symbol }
  Name Env -> skip where (element? Name Env)
  Name _ -> (set qbe-free-slots (cons Name (value qbe-free-slots))) where (element? Name (value qbe-temp-names))
  _ _ -> skip)

(define qbe-free-names { (list zinc-value) --> (list zinc-value) --> symbol }
  [] _ -> skip
  [N | R] Env -> (do (qbe-free-name N Env) (qbe-free-names R Env)))

\* Free every temp of a frame-exit state (appterm/return blocks record no CFG
   successors, so their whole abstract Stk+Env is dead on that path; phi
   merges never reference these names).  The Env guard is bypassed — the
   bindings die with the frame — but qbe-free-name's qbe-temp-names check
   still skips params %a0..%aN/%out and [clo _]/[prim _] zinc-values.
   Compile-time sound: the pool is shared across all blocks of the function,
   and a later pick in a sibling block only writes the slot on ITS runtime
   path, never on this one. *\
(define qbe-free-exit-state { (list zinc-value) --> (list zinc-value) --> symbol }
  Stk Env -> (qbe-free-names (append Stk Env) []))

\* Flatten a list of lists (for the merge blocked-set). *\
(define qbe-concat { (list (list A)) --> (list A) }
  [] -> []
  [L | R] -> (append L (qbe-concat R)))

\* Register a string/symbol data literal, return its $dN label. *\
(define qbe-data { string --> string }
  Content -> (let N (value qbe-data-count)
               (do (set qbe-data-count (+ N 1))
                   (set qbe-datas (cons [(cn "$d" (str N)) Content] (value qbe-datas)))
                   (cn "$d" (str N)))))

(define qbe-string-lit { string --> string }
  S -> (qbe-data S))

(define qbe-symbol-lit { symbol --> string }
  S -> (qbe-data (str S)))

\* Join already-typed call arguments ("l %t", "w 1", "l 42", ...) with ", ". *\
(define qbe-args-str { (list string) --> string }
  [] -> ""
  [A] -> A
  [A | R] -> (qbe-join [A ", " (qbe-args-str R)]))

\* Wrap bare Value* temp names as `l %t` call args. *\
(define qbe-l-args { (list string) --> (list string) }
  [] -> []
  [T | R] -> [(cn "l " T) | (qbe-l-args R)])

(define qbe-call { string --> (list string) --> string }
  F Args -> (qbe-join ["call $" F "(" (qbe-args-str Args) ")"]))

\* -------------------------- CFG recovery -------------------------- *\

(define qbe-index { klambda --> number --> (list (list number zinc-code)) }
  [] _ -> []
  [I | C] N -> [[N I] | (qbe-index C (+ N 1))])

(define qbe-terminator? { zinc-code --> boolean }
  [jmp _] -> true
  [jmpf _] -> true
  return -> true
  appterm -> true
  _ -> false)

(define qbe-leaders { (list (list number zinc-code)) --> (list number) }
  Indexed -> (qbe-sort-unique (qbe-leaders-h Indexed [0])))

(define qbe-leaders-h { (list (list number zinc-code)) --> (list number) --> (list number) }
  [] Acc -> Acc
  [[N [jmp L]] | R] Acc -> (qbe-leaders-h R (cons (+ N 1) (cons L Acc)))
  [[N [jmpf L]] | R] Acc -> (qbe-leaders-h R (cons (+ N 1) (cons L Acc)))
  [[N return] | R] Acc -> (qbe-leaders-h R (cons (+ N 1) Acc))
  [[N appterm] | R] Acc -> (qbe-leaders-h R (cons (+ N 1) Acc))
  [[_ _] | R] Acc -> (qbe-leaders-h R Acc))

(define qbe-insert-num { number --> (list number) --> (list number) }
  N [] -> [N]
  N [H | T] -> [N H | T] where (< N H)
  N [H | T] -> [H | (qbe-insert-num N T)] where (> N H)
  N L -> L)

(define qbe-sort-unique { (list number) --> (list number) }
  [] -> []
  [H | T] -> (qbe-insert-num H (qbe-sort-unique T)))

(define qbe-slice { (list (list number zinc-code)) --> number --> number --> (list (list number zinc-code)) }
  Indexed Start End -> (qbe-slice-h Indexed Start End []))

(define qbe-slice-h { (list (list number zinc-code)) --> number --> number --> (list (list number zinc-code)) --> (list (list number zinc-code)) }
  [] _ _ Acc -> (reverse Acc)
  [[N I] | R] Start End Acc -> (qbe-slice-h R Start End (cons [N I] Acc)) where (and (>= N Start) (< N End))
  [_ | R] Start End Acc -> (qbe-slice-h R Start End Acc))

(define qbe-make-blocks { (list (list number zinc-code)) --> (list number) --> number --> (list (list number (list (list number zinc-code)))) }
  Indexed [L1 L2 | R] Total -> (cons [L1 (qbe-slice Indexed L1 L2)] (qbe-make-blocks Indexed [L2 | R] Total))
  Indexed [L] Total -> (if (< L Total) [[L (qbe-slice Indexed L Total)]] [])
  _ [] _ -> [])

(define qbe-last-instr { (list (list number zinc-code)) --> zinc-code }
  [[_ I]] -> I
  [[_ _] | R] -> (qbe-last-instr R)
  [] -> (simple-error (cn "qbe: empty block in " (str (value qbe-cur-name)))))

(define qbe-block-end { (list (list number zinc-code)) --> number }
  [[N _]] -> (+ N 1)
  [[_ _] | R] -> (qbe-block-end R))

\* -------------------------- arity / entry env -------------------------- *\

\* Arity = leading grabs + 1 (matches interp's zinc-arity). *\
(define qbe-arity { klambda --> number }
  [grab | C] -> (+ 1 (qbe-arity C))
  _ -> 1)

(define qbe-arg-temps { number --> (list string) }
  N -> (qbe-arg-temps-h N []))

(define qbe-arg-temps-h { number --> (list string) --> (list string) }
  N Acc -> (qbe-arg-temps-h (- N 1) (cons (cn "%a" (str (- N 1))) Acc)) where (> N 0)
  _ Acc -> Acc)

\* Entry Env: [%a{k-1} ... %a0] - access 0 = rightmost arg. *\
(define qbe-env0 { (list string) --> (list string) }
  Args -> (reverse Args))

\* -------------------------- stack helpers -------------------------- *\

(define qbe-pop { (list A) --> (list A) }
  [H | T] -> [H T]
  _ -> (simple-error "qbe: pop empty stack"))

\* Pop K entries (top-first), return [args remaining]. *\
(define qbe-pop-k { number --> (list A) --> (list (list A)) }
  0 Stk -> [[] Stk]
  K [H | T] -> (let R (qbe-pop-k (- K 1) T)
                 [[H | (hd R)] | (tl R)])
  _ _ -> (simple-error "qbe: stack underflow"))

\* -------------------------- state accessors -------------------------- *\

(define qbe-stk { (list zinc-value) --> (list zinc-value) } S -> (hd S))
(define qbe-env { (list zinc-value) --> (list zinc-value) } S -> (hd (tl S)))
(define qbe-marks { (list zinc-value) --> (list number) } S -> (hd (tl (tl S))))

\* -------------------------- per-opcode step -------------------------- *\

(define qbe-step { number --> zinc-code --> (list zinc-value) --> (list symbol) --> (list zinc-value) }
  _ grab [Stk Env Marks] _ -> [Stk Env Marks]
  _ letz [Stk Env Marks] _ -> [(tl Stk) [(hd Stk) | Env] Marks]
  _ endlet [Stk Env Marks] _ -> [Stk Env Marks] where (empty? Env)
  _ endlet [Stk Env Marks] _ -> (do (qbe-free-name (hd Env) (tl Env)) [Stk (tl Env) Marks])
  _ [access N] [Stk Env Marks] _ -> [[(qbe-env-access N Env Stk) | Stk] Env Marks]
  _ [number N] [Stk Env Marks] _ ->
    (let Out (qbe-slot Stk Env)
      (do (qbe-emit (qbe-call "val_number_into" [(cn "l " Out) (cn "l " (str N))]))
          [[Out | Stk] Env Marks]))
  _ [string S] [Stk Env Marks] _ ->
    (let Out (qbe-slot Stk Env)
      (let D (qbe-string-lit S)
        (do (qbe-emit (qbe-call "val_string_into" [(cn "l " Out) (cn "l " D) (cn "l " (str (qbe-strlen S)))]))
            [[Out | Stk] Env Marks])))
  _ [symbol S] [Stk Env Marks] _ ->
    (let Out (qbe-slot Stk Env)
      (let D (qbe-symbol-lit S)
        (do (qbe-emit (qbe-call "val_symbol_into" [(cn "l " Out) (cn "l " D)]))
            [[Out | Stk] Env Marks])))
  _ [boolean B] [Stk Env Marks] _ ->
    (let Out (qbe-slot Stk Env)
      (do (qbe-emit (qbe-call "val_boolean_into" [(cn "l " Out) (cn "w " (if (= B true) "1" "0"))]))
          [[Out | Stk] Env Marks]))
  _ [prim P] [Stk Env Marks] _ ->
    (let K (qbe-prim-arity P)
      (let R (qbe-pop-k K Stk)
        (do (qbe-free-names (hd R) Env)
          (let Out (qbe-slot Stk Env)
            (do (qbe-emit (qbe-call (cn "prim_" (qbe-prim-mangled P)) (cons (cn "l " Out) (qbe-l-args (hd R)))))
                [[Out | (hd (tl R))] Env Marks])))))
  _ [global G] [Stk Env Marks] ClosureSet ->
    (if (qbe-prim? G)
        [[[prim G] | Stk] Env Marks]
        (if (element? G ClosureSet)
            [[[clo G] | Stk] Env Marks]
            (let Out (qbe-slot Stk Env)
              (let D (qbe-symbol-lit (str G))
                (do (qbe-emit (qbe-call "global_get_into" [(cn "l " Out) (cn "l " D)]))
                    [[Out | Stk] Env Marks])))))
  _ pushmark [Stk Env Marks] _ -> [Stk Env [(length Stk) | Marks]]
  _ apply [Stk Env Marks] ClosureSet ->
    (let R (qbe-pop-k (- (length (tl Stk)) (hd Marks)) (tl Stk))
      (do (qbe-free-names (hd R) Env)
          (qbe-free-name (hd Stk) Env)
          (let Out (qbe-slot Stk Env)
            (do (qbe-emit (qbe-do-call (hd Stk) Out (hd R) ClosureSet))
                [[Out | (hd (tl R))] Env (tl Marks)]))))
  _ appterm [Stk Env Marks] ClosureSet ->
    (let R (qbe-pop-k (- (length (tl Stk)) (hd Marks)) (tl Stk))
      (do (qbe-emit (qbe-do-tail (hd Stk) (hd R) ClosureSet))
          (qbe-emit (qbe-call "gc_root_pop_to" [(cn "l " (value qbe-wm-temp))]))
          (qbe-emit "ret")
          (qbe-free-exit-state Stk Env)
          [(hd (tl R)) Env (tl Marks)]))
  _ return [Stk Env Marks] _ ->
    (do (qbe-emit (qbe-call "copy_value" ["l %out" (cn "l " (hd Stk))]))
        (qbe-emit (qbe-call "gc_root_pop_to" [(cn "l " (value qbe-wm-temp))]))
        (qbe-emit "ret")
        (qbe-free-exit-state Stk Env)
        [Stk Env Marks])
  _ [jmp L] State _ ->
    (do (qbe-emit (qbe-join ["jmp @b" (str L)]))
        State)
  N [jmpf L] [Stk Env Marks] _ ->
    (let Cond (hd Stk)
      (let C (qbe-c-fresh)
        (do (qbe-emit (qbe-join [C " =w call $is_false(" (cn "l " Cond) ")"]))
            (qbe-emit (qbe-join ["jnz " C ", @b" (str L) ", @b" (str (+ N 1))]))
            (qbe-free-name Cond Env)
            [(tl Stk) Env Marks])))
  _ [trap C1 C2] [Stk Env Marks] ClosureSet ->
    \* C1 = HANDLER (first cur), C2 = BODY (second cur): trap-error pops the
       body first (top = second cur) and the handler below (first cur). *\
    (let Ncap (qbe-max2 (qbe-max-access C1) (qbe-max-access C2))
      (let TB (qbe-fresh-tag)
        (let TH (qbe-fresh-tag)
          (let Caps (qbe-trap-caps Ncap Env Stk)
            (let FnH (qbe-lower-cur TH C1 Ncap ClosureSet)
              (let FnB (qbe-lower-cur TB C2 Ncap ClosureSet)
                (let Out (qbe-slot Stk Env)
                  (do
                    (set qbe-extra-fns (cons FnB (cons FnH (value qbe-extra-fns))))
                    \* [body_tag handler_tag Ncap]: the C shim runs b_TB (body)
                       with nil and b_TH (handler) with the caught error. *\
                    (set qbe-trap-shims (cons [TB TH Ncap] (value qbe-trap-shims)))
                    (qbe-emit (qbe-call (qbe-trap-shim-name TB TH)
                                        (cons (cn "l " Out) (qbe-l-args Caps))))
                    [[Out | Stk] Env Marks]))))))))
  _ [Op | _] _ _ -> (simple-error (cn "qbe: unsupported op " (str Op)))
  _ X _ _ -> (simple-error (cn "qbe: unknown instruction " (str X))))

\* Direct-call for apply (non-tail): result into fresh %out slot. *\
(define qbe-do-call { zinc-value --> string --> (list zinc-value) --> (list symbol) --> string }
  [clo G] Out Args _ -> (qbe-call (qbe-clo-name G) (cons (cn "l " Out) (qbe-l-args Args)))
  [prim P] Out Args _ -> (qbe-call (cn "prim_" (qbe-prim-mangled P)) (cons (cn "l " Out) (qbe-l-args Args)))
  _ _ _ _ -> (simple-error "qbe: dynamic apply not supported"))

\* Tail-call for appterm: result goes to the current function's %out. *\
(define qbe-do-tail { zinc-value --> (list zinc-value) --> (list symbol) --> string }
  [clo G] Args _ -> (qbe-call (qbe-clo-name G) (cons "l %out" (qbe-l-args Args)))
  [prim P] Args _ -> (qbe-call (cn "prim_" (qbe-prim-mangled P)) (cons "l %out" (qbe-l-args Args)))
  _ _ _ -> (simple-error "qbe: dynamic appterm not supported"))

\* -------------------------- CFG edge recording -------------------------- *\

(define qbe-record-pred { number --> number --> (list zinc-value) --> symbol }
  Target Pred State -> (set qbe-preds (cons [Target Pred State] (value qbe-preds))))

(define qbe-record-succs { number --> (list (list number zinc-code)) --> (list zinc-value) --> symbol }
  Start Instrs Out ->
    (let Last (qbe-last-instr Instrs)
      (qbe-record-succs2 Start Instrs Out Last)))

(define qbe-record-succs2 { number --> (list (list number zinc-code)) --> (list zinc-value) --> zinc-code --> symbol }
  _ _ _ return -> skip
  _ _ _ appterm -> skip
  Start _ Out [jmp L] -> (qbe-record-pred L Start Out)
  Start Instrs Out [jmpf L] -> (do (qbe-record-pred L Start Out)
                                   (qbe-record-pred (qbe-block-end Instrs) Start Out))
  Start Instrs Out _ -> (qbe-record-pred (qbe-block-end Instrs) Start Out))

\* -------------------------- phi reconciliation -------------------------- *\

(define qbe-preds-of { number --> (list (list number (list zinc-value))) }
  L -> (qbe-preds-of-h L (value qbe-preds) []))

(define qbe-preds-of-h { number --> (list (list number (list zinc-value))) --> (list (list number (list zinc-value))) --> (list (list number (list zinc-value))) }
  _ [] Acc -> Acc
  L [[T P S] | R] Acc -> (qbe-preds-of-h L R (cons [P S] Acc)) where (= L T)
  L [_ | R] Acc -> (qbe-preds-of-h L R Acc))

(define qbe-pred-starts { (list (list number (list zinc-value))) --> (list number) }
  [] -> []
  [[P _] | R] -> [P | (qbe-pred-starts R)])

(define qbe-pred-stks { (list (list number (list zinc-value))) --> (list (list zinc-value)) }
  [] -> []
  [[_ S] | R] -> [(qbe-stk S) | (qbe-pred-stks R)])

(define qbe-pred-envs { (list (list number (list zinc-value))) --> (list (list zinc-value)) }
  [] -> []
  [[_ S] | R] -> [(qbe-env S) | (qbe-pred-envs R)])

(define qbe-merge { (list (list number (list zinc-value))) --> (list zinc-value) }
  Preds -> (let Starts (qbe-pred-starts Preds)
             (let Stks (qbe-pred-stks Preds)
               (let Envs (qbe-pred-envs Preds)
                 (do (set qbe-merge-blocked (append (qbe-concat Stks) (qbe-concat Envs)))
                   (let Stk (qbe-reconcile (qbe-pred-stks Preds) Starts)
                     (let Env (qbe-reconcile (qbe-pred-envs Preds) Starts)
                       (let Marks (qbe-marks (hd (tl (hd Preds))))
                         (do (qbe-copy-lines (reverse (value qbe-pending-copies)))
                           (set qbe-pending-copies [])
                           [Stk Env Marks])))))))))

\* qbe-max-length: the longest predecessor slot-list length, so the reconcile
   iterates over the LONGEST pred (every real slot gets a phi) and shorter preds
   get the number-0 sentinel via qbe-col. *\
(define qbe-max-length { (list (list zinc-value)) --> number }
  [] -> 0
  [S | R] -> (qbe-max2 (length S) (qbe-max-length R)))

\* qbe-zero: the function-local number-0 sentinel temp.  Lazy: allocated on first
   use, defined in block 0 (alloc8 40 + val_number_into) so it dominates every
   phi predecessor.  Memoized per function (one %zero for all missing slots). *\
(define qbe-zero { --> string }
  -> (if (= (value qbe-zero-tmp) false)
         (let T (qbe-fresh)
           (do (set qbe-allocs (cons (qbe-join [T " =l alloc8 40"]) (value qbe-allocs)))
               (set qbe-temp-names (cons T (value qbe-temp-names)))
               (set qbe-zero-init (qbe-call "val_number_into" [(cn "l " T) "l 0"]))
               (set qbe-zero-tmp T)
               T))
         (value qbe-zero-tmp)))

(define qbe-reconcile { (list (list zinc-value)) --> (list number) --> (list zinc-value) }
  Slots Starts -> (qbe-reconcile-h Slots Starts 0 (qbe-max-length Slots)))

(define qbe-reconcile-h { (list (list zinc-value)) --> (list number) --> number --> number --> (list zinc-value) }
  Slots Starts J Max -> [] where (= J Max)
  Slots Starts J Max -> [(qbe-slot-phi Slots Starts J) | (qbe-reconcile-h Slots Starts (+ J 1) Max)])

(define qbe-col { (list (list zinc-value)) --> number --> (list zinc-value) }
  [] _ -> []
  [S | R] J -> [(if (>= J (length S)) (qbe-zero) (qbe-nth0 J S)) | (qbe-col R J)])

(define qbe-all-eq { (list zinc-value) --> boolean }
  [] -> true
  [_] -> true
  [X Y | R] -> (and (= X Y) (qbe-all-eq [Y | R])))

\* Merge one slot position across predecessors.  All-equal names need no phi.
   Otherwise a POINTER phi T is emitted and immediately copied into an
   independent rooted slot T2 (copy_value right after the phi section): T2
   owns its value from block entry on, so the phi's inputs stay recyclable
   later in the function without corrupting the merged value.  T itself is an
   unrooted pointer temp whose live range spans only the phi and the copy
   (copy_value does not allocate, so no GC can run in between).  The copy
   lines are emitted by qbe-merge AFTER both the Stk and Env phi sections
   (QBE requires all phis before regular instructions).  T2 is picked with
   the merge-blocked set (every name live at ANY predecessor exit) so it can
   never alias a live phi input or another T2 of the same merge.  Finally the
   phi INPUT names are returned to the free pool: the copy has captured their
   values, they are no longer in the merged Stk/Env (a name replaced by a phi
   cannot appear live past this join — every block on its live path carried
   it in its abstract Stk, which blocked any pick), and a later endlet
   re-frees them harmlessly if they were also Env-bound. *\
(define qbe-slot-phi { (list (list zinc-value)) --> (list number) --> number --> zinc-value }
  Slots Starts J -> (let Temps (qbe-col Slots J)
                      (if (qbe-all-eq Temps)
                          (hd Temps)
                          (let T (qbe-fresh)
                            (let T2 (qbe-slot (value qbe-merge-blocked) [])
                              (do (qbe-emit (qbe-join [T " =l phi " (qbe-phi-inputs Starts Temps)]))
                                  (set qbe-pending-copies (cons [T2 T] (value qbe-pending-copies)))
                                  (set qbe-merge-blocked (cons T2 (value qbe-merge-blocked)))
                                  (qbe-free-names Temps [])
                                  T2))))))

(define qbe-copy-lines { (list (list string string)) --> symbol }
  [] -> skip
  [[Dst Src] | R] -> (do (qbe-emit (qbe-call "copy_value" [(cn "l " Dst) (cn "l " Src)]))
                         (qbe-copy-lines R)))

(define qbe-phi-inputs { (list number) --> (list zinc-value) --> string }
  [P] [T] -> (qbe-join ["@b" (str P) " " T])
  [P | PR] [T | TR] -> (qbe-join ["@b" (str P) " " T ", " (qbe-phi-inputs PR TR)]))

\* -------------------------- block execution -------------------------- *\

(define qbe-exec { (list (list number zinc-code)) --> (list zinc-value) --> (list symbol) --> (list zinc-value) }
  [] State _ -> State
  [[N I] | R] State ClosureSet -> (qbe-exec R (qbe-step N I State ClosureSet) ClosureSet))

(define qbe-lower-blocks { (list (list number (list (list number zinc-code)))) --> (list zinc-value) --> (list symbol) --> symbol }
  [] _ _ -> done
  [[Start Instrs] | Rest] Entry0 ClosureSet ->
    (do
      (let Preds (qbe-preds-of Start)
        (if (or (= Start 0) (not (empty? Preds)))
            (do
              (set qbe-lines [])
              (let Entry (if (empty? Preds) Entry0 (qbe-merge Preds))
                (let Out (qbe-exec Instrs Entry ClosureSet)
                  (do (qbe-record-succs Start Instrs Out)
                      (set qbe-block-lines (cons [Start (value qbe-lines)] (value qbe-block-lines)))))))
            skip))
      (qbe-lower-blocks Rest Entry0 ClosureSet)))

\* -------------------------- assembly -------------------------- *\

(define qbe-lines-str { (list string) --> string }
  [] -> ""
  [L] -> L
  [L | R] -> (cn (cn L (value qbe-nl)) (qbe-lines-str R)))

(define qbe-block-str { (list number (list string)) --> string }
  [Start Lines] -> (cn (cn "@b" (str Start)) (if (empty? Lines) "" (cn (value qbe-nl) (qbe-lines-str (reverse Lines))))))

(define qbe-blocks-str { (list (list number (list string))) --> string }
  [] -> ""
  [B] -> (qbe-block-str B)
  [B | R] -> (cn (cn (qbe-block-str B) (value qbe-nl)) (qbe-blocks-str R)))

(define qbe-fn-header { symbol --> number --> string }
  Name Arity ->
    (qbe-join ["export" (value qbe-nl) "function $" (qbe-clo-name Name) "("
               (qbe-args-str (qbe-l-args (cons "%out" (qbe-arg-temps Arity))))
               ") {" (value qbe-nl)]))

\* Per-frame GC rooting prologue lines.  qbe-temp-names holds the bare %tN names
   of every alloc8 40 slot in this function (qbe-slot / qbe-zero cons them in
   reverse-allocation order, matching qbe-allocs).  We emit, AFTER the alloc8 40
   declarations and BEFORE the body:
     (a) a `call $val_nil_into(l %tN)` per slot — alloc8 reserves UNINITIALIZED
         stack; pushing an uninitialized Value as ROOT_VALUE would let the GC
         scan a garbage tag/interior pointers and crash.  val_nil_into writes a
         non-allocating VAL_NIL Value (gc_scan_value on VAL_NIL is a no-op).
     (b) `<wm> =l call $gc_root_watermark()` — captures the shadow-stack depth
         from BEFORE this function's pushes; pop_to(wm) at exit removes exactly
         this function's pushes.  Taken between zero-init and pushes (zero-init
         does not push, so the watermark is unaffected).
     (c) a `call $gc_root_push_value(l %tN)` per slot — registers each slot as
         a ROOT_VALUE for the whole function lifetime.  Over-rooting (dead slots
         stay pushed) is SAFE: gc_scan_value on a nil Value is a no-op, and on a
         live Value evacuates its interior pointers idempotently.
   The qbe-zero sentinel's val_number_into (qbe-zero-init) runs AFTER the
   per-frame val_nil_into, overwriting that slot's nil with number 0 (last
   write wins; the slot is rooted throughout).  Phi temps are NOT pushed
   (they alias existing alloc slots); params %out/%aN are NOT pushed
   (caller-rooted).  Using pop_to(wm) (not paired pops) at function exit
   makes the trap-error longjmp path automatically balanced — the trap shims
   already do pop_to(wm) on both paths, which composes correctly with the
   per-frame pushes done by the cur bodies they run. *\
(define qbe-nil-lines { (list string) --> (list string) }
  [] -> []
  [T | R] -> [(qbe-call "val_nil_into" [(cn "l " T)]) | (qbe-nil-lines R)])

(define qbe-push-lines { (list string) --> (list string) }
  [] -> []
  [T | R] -> [(qbe-call "gc_root_push_value" [(cn "l " T)]) | (qbe-push-lines R)])

(define qbe-wm-line { --> string }
  -> (cn (value qbe-wm-temp) " =l call $gc_root_watermark()"))

(define qbe-inject-allocs { (list (list number (list string))) --> (list (list number (list string))) }
  [] -> []
  [[0 Lines] | R] ->
    [[0 (append Lines
              (append (qbe-push-lines (value qbe-temp-names))
                (append [(qbe-wm-line)]
                  (append (if (= (value qbe-zero-init) "") [] [(value qbe-zero-init)])
                    (append (qbe-nil-lines (value qbe-temp-names))
                      (value qbe-allocs))))))] | R]
  [B | R] -> [B | (qbe-inject-allocs R)])

(define qbe-fn-string { symbol --> number --> string }
  Name Arity ->
    (qbe-join [(qbe-fn-header Name Arity)
               (qbe-blocks-str (qbe-inject-allocs (reverse (value qbe-block-lines))))
               (value qbe-nl) "}" (value qbe-nl)]))

\* Render the accumulated data literals as QBE `data` definitions. *\
(define qbe-datas-str { (list (list string string)) --> string }
  [] -> ""
  [[N Content] | R] -> (qbe-join ["data " N " = { b " (value qbe-dq) Content (value qbe-dq) ", b 0 }" (value qbe-nl) (qbe-datas-str R)]))

\* -------------------------- cur / trap-error defunctionalization -------------------------- *\

\* Max access index in a (nested) code list; recurses into nested [trap C1 C2]. *\
(define qbe-max-access { (list zinc-code) --> number }
  [] -> 0
  [[access N] | R] -> (qbe-max2 N (qbe-max-access R))
  [[trap C1 C2] | R] -> (qbe-max2 (qbe-max-access C1) (qbe-max2 (qbe-max-access C2) (qbe-max-access R)))
  [_ | R] -> (qbe-max-access R))

(define qbe-max2 { number --> number --> number }
  A B -> A where (>= A B)
  _ B -> B)

\* Fresh tag for a cur body (global, monotonic — unique $b_<tag> per body). *\
(define qbe-fresh-tag { --> number }
  -> (let N (value qbe-cur-tag-count)
       (do (set qbe-cur-tag-count (+ N 1)) N)))

\* cur-body param names: %a0 (trap arg) then %cap_0 ... %cap_{Ncap-1}. *\
(define qbe-cur-cap-params { number --> (list string) }
  N -> (qbe-cur-cap-params-h N 0))
(define qbe-cur-cap-params-h { number --> number --> (list string) }
  N J -> [] where (>= J N)
  N J -> [(cn "%cap_" (str J)) | (qbe-cur-cap-params-h N (+ J 1))])

(define qbe-cur-params { number --> (list string) }
  Ncap -> (cons "%a0" (qbe-cur-cap-params Ncap)))

\* Entry Env for a cur body: [%a0 %cap_0 ... %cap_{Ncap-1}] (newest-first).
   access 0 = %a0 (trap arg), access N = %cap_{N-1} = enclosing P access (N-1).
   This mirrors the C VM: body env = captured ++ [nil], lookup_env(0)=nil. *\
(define qbe-cur-env0 { number --> (list string) }
  Ncap -> (qbe-cur-params Ncap))

\* cur-body function header + assembly (reuses the shared block machinery). *\
(define qbe-cur-fn-header { number --> number --> string }
  Tag Ncap ->
    (qbe-join ["export" (value qbe-nl) "function $b_" (str Tag) "("
               (qbe-args-str (qbe-l-args (cons "%out" (qbe-cur-params Ncap))))
               ") {" (value qbe-nl)]))

(define qbe-cur-fn-string { number --> number --> string }
  Tag Ncap ->
    (qbe-join [(qbe-cur-fn-header Tag Ncap)
               (qbe-blocks-str (qbe-inject-allocs (reverse (value qbe-block-lines))))
               (value qbe-nl) "}" (value qbe-nl)]))

\* Save / restore the parent closure's mutable lowering state around a cur-body
   lowering, so the parent's CFG/temps/data continue untouched afterwards. *\
(define qbe-cur-save { --> (list (list symbol zinc-value)) }
  -> [[temp-count (value qbe-temp-count)]
      [wcount (value qbe-wcount)]
      [datas (value qbe-datas)]
      [preds (value qbe-preds)]
      [allocs (value qbe-allocs)]
      [temp-names (value qbe-temp-names)]
      [free-slots (value qbe-free-slots)]
      [pending-copies (value qbe-pending-copies)]
      [merge-blocked (value qbe-merge-blocked)]
      [wm-temp (value qbe-wm-temp)]
      [zero-tmp (value qbe-zero-tmp)]
      [zero-init (value qbe-zero-init)]
      [block-lines (value qbe-block-lines)]
      [lines (value qbe-lines)]])

(define qbe-cur-get { symbol --> (list (list symbol zinc-value)) --> zinc-value }
  Key Saved -> (let P (assoc Key Saved)
                 (if (empty? P) (simple-error "qbe: state save/restore mismatch") (hd (tl P)))))

(define qbe-cur-restore { (list (list symbol zinc-value)) --> symbol }
  Saved -> (do
    (set qbe-temp-count (qbe-cur-get temp-count Saved))
    (set qbe-wcount (qbe-cur-get wcount Saved))
    (set qbe-datas (qbe-cur-get datas Saved))
    (set qbe-preds (qbe-cur-get preds Saved))
    (set qbe-allocs (qbe-cur-get allocs Saved))
    (set qbe-temp-names (qbe-cur-get temp-names Saved))
    (set qbe-free-slots (qbe-cur-get free-slots Saved))
    (set qbe-pending-copies (qbe-cur-get pending-copies Saved))
    (set qbe-merge-blocked (qbe-cur-get merge-blocked Saved))
    (set qbe-wm-temp (qbe-cur-get wm-temp Saved))
    (set qbe-zero-tmp (qbe-cur-get zero-tmp Saved))
    (set qbe-zero-init (qbe-cur-get zero-init Saved))
    (set qbe-block-lines (qbe-cur-get block-lines Saved))
    (set qbe-lines (qbe-cur-get lines Saved))
    done))

\* Lower one cur body (nested code) to `function $b_<Tag>` capturing the
   enclosing closure's accesses 0..Ncap-1 as %cap_0..%cap_{Ncap-1}. *\
(define qbe-lower-cur { number --> (list zinc-code) --> number --> (list symbol) --> string }
  Tag Nested Ncap ClosureSet ->
    (let Saved (qbe-cur-save)
      (do
        (set qbe-temp-count 0)
        (set qbe-wcount 0)
        (set qbe-datas [])
        (set qbe-preds [])
        (set qbe-allocs [])
        (set qbe-temp-names [])
        (set qbe-free-slots [])
        (set qbe-pending-copies [])
        (set qbe-merge-blocked [])
        (set qbe-wm-temp (qbe-fresh))
        (set qbe-zero-tmp false)
        (set qbe-zero-init "")
        (set qbe-block-lines [])
        (set qbe-lines [])
        (let Env0 (qbe-cur-env0 Ncap)
          (let Indexed (qbe-index Nested 0)
            (let Total (length Indexed)
              (let Blocks (qbe-make-blocks Indexed (qbe-leaders Indexed) Total)
                (let Fn (do (qbe-lower-blocks Blocks [[] Env0 []] ClosureSet)
                             (qbe-cur-fn-string Tag Ncap))
                  (let ChildDatas (value qbe-datas)
                    (do (qbe-cur-restore Saved)
                        (set qbe-datas (append ChildDatas (value qbe-datas)))
                        Fn))))))))))

\* cap_j for the shim call: the enclosing closure's access j, or a fresh 0 slot
   if j is past the enclosing env (mirrors lookup_env's OOB number-0 sentinel). *\
(define qbe-trap-cap { number --> (list string) --> (list zinc-value) --> string }
  J Env Stk -> (qbe-env-access J Env Stk))

(define qbe-trap-caps { number --> (list string) --> (list zinc-value) --> (list string) }
  N Env Stk -> (qbe-trap-caps-h N 0 Env Stk))
(define qbe-trap-caps-h { number --> number --> (list string) --> (list zinc-value) --> (list string) }
  N J Env Stk -> [] where (>= J N)
  N J Env Stk -> [(qbe-trap-cap J Env Stk) | (qbe-trap-caps-h N (+ J 1) Env Stk)])

(define qbe-trap-shim-name { number --> number --> string }
  T1 T2 -> (cn "trap_" (cn (str T1) (cn "_" (str T2)))))

\* -------------------------- top-level lower -------------------------- *\

(define lower { symbol --> klambda --> (list symbol) --> string }
  Name Body ClosureSet ->
    (do
      (set qbe-temp-count 0)
      (set qbe-wcount 0)
      \* qbe-data-count is GLOBAL (unique $dN labels across all closures);
         only the per-closure qbe-datas list is reset here. *\
      (set qbe-datas [])
      (set qbe-preds [])
      (set qbe-allocs [])
      (set qbe-temp-names [])
      (set qbe-free-slots [])
      (set qbe-pending-copies [])
      (set qbe-merge-blocked [])
      (set qbe-wm-temp (qbe-fresh))
      (set qbe-zero-tmp false)
      (set qbe-zero-init "")
      (set qbe-block-lines [])
      (set qbe-lines [])
      (set qbe-extra-fns [])
      (set qbe-trap-shims [])
      (set qbe-cur-name Name)
      (let Arity (qbe-arity Body)
        (let Nested (qbe-renumber (qbe-pair-traps (qbe-nest Body)))
          (let Env0 (qbe-env0 (qbe-arg-temps Arity))
            (let Indexed (qbe-index Nested 0)
              (let Total (length Indexed)
                (let Blocks (qbe-make-blocks Indexed (qbe-leaders Indexed) Total)
                  (do (qbe-lower-blocks Blocks [[] Env0 []] ClosureSet)
                      (qbe-fn-string Name Arity))))))))))

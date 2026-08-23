\* =============================================================================
   set-toplevel.shen - the shen-scheme BOOTSTRAP helper and its call site.

   `set-toplevel` compiles a host KLambda value X (via the host `ps`
   primitive) through our full pipeline into a ZINC closure and installs it in
   global-table under N.  The top-level `(set-toplevel N X)` calls below
   register the bare-name -> safe-wrapper / interpreter aliases that the HOST
   shen-scheme needs while compiling the source files into the bundle.

   This file is loaded ONLY by the host build (serialize-reduced.shen,
   immediately after interp.shen).  The SELF-HOSTED reduced
   bundle (shen-load path, runs on the C VM) never loads it: interp-eval skips
   non-defun forms anyway, nothing references [global set-toplevel] at runtime,
   and the reduced bundle's aliases are pre-computed statically (see
   serialize-reduced.shen's safe-alias-pairs block).  Keeping this bootstrap
   helper OUT of the reduced bundle means it never appears in globals.csexp,
   and the host-only `ps` dynamic-apply it contains need not be lowered.
   ============================================================================= *\

(tc -)

\* The define originally lived in interp.shen (after normalize-term).  It uses
   toplevel-interp / zinc-c / debruijn / normalize-term / kmacros /
   defun->lambda, all defined in interp.shen — hence this file must be loaded
   AFTER interp.shen in the host sequence. *\
(define set-toplevel { symbol --> symbol --> symbol }
  N X -> (do
    (set global-table (cons [N (toplevel-interp (zinc-c (debruijn [] (normalize-term (kmacros (defun->lambda (ps X)))))))] (value global-table)))
    N))

(optimise +)

(load "shen/primitives.shen")

(set-toplevel number? safe.number?)
(set-toplevel symbol? safe.symbol?)
(set-toplevel string? safe.string?)
(set-toplevel boolean? safe.boolean?)
(set-toplevel cons? safe.cons?)
(set-toplevel simple-error safe.simple-error)
(set-toplevel get-time safe.get-time)
(set-toplevel close safe.close)
(set-toplevel read-byte safe.read-byte)
(set-toplevel tl safe.tl)
(set-toplevel hd safe.hd)
(set-toplevel absvector safe.absvector)
(set-toplevel n->string safe.n->string)
(set-toplevel string->n safe.string->n)
(set-toplevel str safe.str)
(set-toplevel tlstr safe.tlstr)
(set-toplevel value interp-value)
(set-toplevel intern safe.intern)
(set-toplevel error-to-string safe.error-to-string)
(set-toplevel trap-error safe.trap-error)
(set-toplevel = safe.=)
(set-toplevel open safe.open)
(set-toplevel write-byte safe.write-byte)
(set-toplevel cons safe.cons)
(set-toplevel fst safe.fst)
(set-toplevel snd safe.snd)
(set-toplevel emptylist safe.emptylist)
(set-toplevel hdstr safe.hdstr)
(set-toplevel read-file-as-string safe.read-file-as-string)
(set-toplevel <-address safe.<-address)
(set-toplevel cn safe.cn)
(set-toplevel pos safe.pos)
(set-toplevel <= safe.<=)
(set-toplevel >= safe.>=)
(set-toplevel < safe.<)
(set-toplevel > safe.>)
(set-toplevel set interp-set)
(set-toplevel - safe.-)
(set-toplevel * safe.*)
(set-toplevel / safe./)
(set-toplevel + safe.+)
(set-toplevel address-> safe.address->)
(set-toplevel eval-kl safe.eval-kl)
(set-toplevel extract-kl extract-kl)
(set-toplevel kl->zinc kl->zinc)
(set-toplevel toplevel-interp toplevel-interp)

\* Bundle compiler dependencies: kl->zinc calls zinc-c → zinc-t, map-zinc-c,
  debruijn → map-debruijn, normalize-term → normalize → normalize-name →
  normalize-names → flatten-%%app, kmacros → map-kmacros, plus
  atomic?, primitive?, fold-append, intersperse.  Without these in
  global-table, bundled closures that use them will fail at runtime.

  id must be bundled BEFORE normalize-term — normalize-term's source
  contains (function id), and when set-toplevel executes the compiled
  bytecode via toplevel-interp → interp, interp resolves global id
  via lookup-global which checks global-table. *\
(set-toplevel id id)
(set-toplevel zinc-c zinc-c)
(set-toplevel zinc-t zinc-t)
(set-toplevel map-zinc-c map-zinc-c)
(set-toplevel zinc-c-args zinc-c-args)
(set-toplevel zinc-c-tail zinc-c-tail)
(set-toplevel zinc-t-tail zinc-t-tail)
(set-toplevel kmacros kmacros)
(set-toplevel map-kmacros map-kmacros)
(set-toplevel normalize-term normalize-term)
(set-toplevel normalize normalize)
(set-toplevel normalize-name normalize-name)
(set-toplevel normalize-names normalize-names)
(set-toplevel flatten-%%app flatten-%%app)
(set-toplevel atomic? atomic?)
(set-toplevel debruijn debruijn)
(set-toplevel map-debruijn map-debruijn)
(set-toplevel intersperse intersperse)
(set-toplevel fold-append fold-append)
(set-toplevel index_h index_h)
(set-toplevel idx idx)
(set-toplevel primitive? primitive?)
(set-toplevel instruction-keyword? instruction-keyword?)

\* Bundle the meta-circular interpreter and its helpers.
   Without interp in global-table, toplevel-interp's bytecode
   falls through to val_prim("interp") — hence the "[prim interp]"
   result from eval-kl.  lookup-global, lookup, and interp-jmp
   are transitive dependencies; interp's 97 rules call them via
   global lookups at runtime. *\
(set-toplevel lookup-global lookup-global)
(set-toplevel lookup lookup)
(set-toplevel interp-jmp interp-jmp)
(set-toplevel collect-apply-args collect-apply-args)
(set-toplevel zinc-arity zinc-arity)
(set-toplevel count-args count-args)
(set-toplevel element?-h element?-h)
(set-toplevel drop-grabs drop-grabs)
(set-toplevel interp-trap-body interp-trap-body)
(set-toplevel interp-apply-handler interp-apply-handler)
(set-toplevel interp interp)

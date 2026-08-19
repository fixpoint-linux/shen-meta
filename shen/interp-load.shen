\* =============================================================================
   interp-load.shen - the HOST-ONLY Shen-source loaders and their definitions.

   `interp-load` and `interp-load-safe` load a file of Shen source through the
   meta-interpreter: they call the HOST primitive `read-file` (which reads a
   file AND parses it into s-expressions).  `read-file` is NOT available on the
   C VM nor the QBE backend — the runtime has only `read-file-as-string`
   (zincvm.c) — so these two closures cannot run on either native target.  They
   are shen-scheme HOST-build/bootstrap loaders only.

   This file is intentionally NOT loaded by the bundle builders
   (serialize-reduced.shen / serialize-qbe.shen / serialize.shen).  The
   self-hosted reduced bundle loads files at runtime via `interp-load-raw` ->
   `read-file-raw` -> `read-file-as-string` (a real primitive), which stays in
   load.shen.  Keeping `interp-load`/`interp-load-safe` OUT of the bundle means
   they never appear in globals.csexp nor the QBE emission, and the QBE backend
   need not lower the host-only `read-file` dynamic-apply they contain.  (This
   mirrors the set-toplevel.shen host-only split; unlike set-toplevel, nothing
   in the host build needs these loaders, so the file is loaded by no build.)
   ============================================================================= *\

(tc -)

\* The definitions originally lived in load.shen (after toplevel.shen).  They
   use interp-eval-all (load.shen) and the host primitive `read-file`. *\
(define interp-load
  File -> (interp-eval-all (read-file File)))

(define interp-load-safe
  File -> (trap-error (interp-eval-all (read-file File))
                      (/. X X)))

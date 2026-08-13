(tc -)

\* tc-hm-runtime.shen — runtime init + driver for the bundled HM type checker.
   Top-level (set ...) forms in the stage files are skipped by shen-load
   (interp-eval only registers defun forms), so all mutable state is
   initialized here at runtime via %% set (-> [prim set] -> C values_set).

   Output is built as a Shen string and RETURNED to the C VM --tc-hm driver,
   which prints it directly.  (write-byte byte-at-a-time output is avoided:
   the safe-subset compiler miscompiles the recursive byte writer.) *\

\* Initialize all mutable global state at runtime (bundle). *\
(define tc-hm-init
  { --> symbol }
  -> (do (%% set tc-counter 0)
         (%% set tc-prim-table (tc-build-prim-table))
         (%% set tc-sig-tvar-counter 0)
         (%% set tc-sig-tvar-map [])
         (%% set tc-global-sig-table [])
         done))

\* Build the full result string for all files.  cn takes exactly 2 args;
   (n->string 10) is a real newline (Shen 41.2 does not interpret "\n"). *\
(define tc-all-results-str
  { (list (list string (list tc-result))) --> string }
  [] -> ""
  [[File Results] | Rest] ->
    (cn (cn "=== " (cn File (n->string 10)))
        (cn (print-tc-results Results)
            (tc-all-results-str Rest))))

\* Nullary driver entry for C VM --tc-hm.  Returns the full result string. *\
(define run-tc-hm-all
  { --> string }
  -> (do (tc-hm-init)
         (tc-all-results-str (tc-hm-all))))

\* Nullary driver entry for C VM --tc-hm-self.  Runs the checker on its own
   7 source files in dependency order (types -> w -> prims -> patterns ->
   sig -> hm -> runtime), so tc-global-sig-table accumulates and cross-file
   calls resolve.  Returns the full result string.

   TRUST BOUNDARY: this proves the checker is SELF-CONSISTENT — each define's
   body respects its declared sig under the checker's own rules.  It does NOT
   prove the sigs are semantically correct (hand-written axioms), nor that the
   checker's permissiveness (klambda-top, opaque-cons, fresh-tvar-for-cons) is
   sound.  The sigs remain the trust root. *\
(define run-tc-hm-self
  { --> string }
  -> (do (tc-hm-init)
         (tc-all-results-str (tc-hm-files
                               ["shen/tc-hm-types.shen"
                                "shen/tc-hm-w.shen"
                                "shen/tc-hm-prims.shen"
                                "shen/tc-hm-patterns.shen"
                                "shen/tc-hm-sig.shen"
                                "shen/tc-hm.shen"
                                "shen/tc-hm-runtime.shen"]))))

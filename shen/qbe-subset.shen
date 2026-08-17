\* =============================================================================
   qbe-subset.shen - QBE STATIC/DYNAMIC CLOSURE PARTITION

   This is the trusted static/dynamic closure partition for the REDUCED bundle
   (globals.csexp). It drives Slice 3's QBE lowerer.

   After Part 3 of the first-order plan, the compiler FRONT-END
   (normalize / normalize-name / normalize-names / debruijn / zinc-c-tail /
   zinc-t-tail / kl->zinc) is FIRST-ORDER ONLY:

     * normalize.shen's source-level CPS continuations were rewritten to
       DIRECT style (no K : (klambda --> klambda) threaded through /. lambdas).
     * serialize-reduced.shen now dedupes global-table BEFORE
       shen.add-prefix-aliases, so the shen.* aliases resolve to our static
       full-arity closures (not the host shen-scheme higher-order ones).

   The sound verifier (tools/bundle-verify) confirms for the target subset:
       unresolved_call = 0, arity_mismatch = 0,
       first_order / top_first_order = 921 (100%),
       not_first_order_in_target = 0.

   The authoritative partition is out/first_order.csv (= top_first_order, the
   transitive roll-up over top-level closures ∪ their nested cur bodies).  It
   is the sound QBE-compilable set.  With 0 dynamic closures the manual
   exclusion list below is now EMPTY.

   NOTE (follow-up): the lowerer still defers `cur` / trap-error-with-closure
   / dynamic apply to Slice 5.  Those are NOT first-order violations — they
   are unimplemented lowerer constructs, handled by `lower` raising a
   catchable simple-error (qbe-lower-try skips them).  The sound partition is
   about call-site full-arity; the cur/trap-error gate is orthogonal and stays
   in qbe.shen's `lower`.  Wiring out/first_order.csv into serialize-qbe.shen
   as an auto-generated Shen list (so a future higher-order regression is
   caught at QBE-lowering time) is a separate follow-up.

   This file is `tc -`-safe plain data + a predicate. `element?` is a bundled
   type-safe helper available in the reduced bundle.
   ============================================================================= *\

(tc -)

\* ----------------------------------------------------------------------------
   qbe-dynamic-closures - the exclusion list.  EMPTY after Part 3: every
   closure in the reduced bundle is first-order static.  The mechanism is kept
   so Slice 5 can re-list any closure that regains a higher-order call site.
   ---------------------------------------------------------------------------- *\
(set qbe-dynamic-closures [])

\* ----------------------------------------------------------------------------
   qbe-static-closure? - the predicate the Slice 3 lowerer uses.

   Returns true for closures whose bodies are full-arity static (QBE-compilable);
   false for the dynamic closures in the exclusion list.
   ---------------------------------------------------------------------------- *\
(define qbe-static-closure?
  { symbol --> boolean }
  Name -> (not (element? Name (value qbe-dynamic-closures))))

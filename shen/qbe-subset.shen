\* =============================================================================
   qbe-subset.shen - QBE STATIC/DYNAMIC CLOSURE PARTITION

   This is the trusted static/dynamic closure partition for the REDUCED bundle
   (globals.csexp). It drives Slice 3's QBE lowerer.

   Two kinds of closure exist in the reduced bundle:

     * STATIC - full-arity, statically-proven call sites. These are the 936
       closures (of 965 total) that the QBE compiler may translate to native
       code. This includes the ENTIRE metacircular interpreter execution core
       (interp / shen.interp), which is now PROVEN full-arity static.

     * DYNAMIC - closures that contain at least one dynamic call site and MUST
       route through the dynamic fallback (@apply_dynamic) instead of native
       QBE. These are the 29 closures enumerated below.

   The 29 dynamic closures contain:
     * 49 higher-order `[access N]` callee sites (unresolved_call) - all in the
       compiler front-end: normalize / normalize-* / normalize-names /
       debruijn-* / kl->zinc / zinc-c-tail / zinc-t-tail.
     * 2 arity-mismatch sites (under-calls, deferred to dynamic fallback):
         - shen.debruijn.14.15.16.17 -> idx        (expects 2, called with 1)
         - shen.kl->zinc            -> debruijn    (expects 2, called with 1)
       Both are contained within the excluded set below (as
       shen.debruijn.14.15.16.17 and shen.kl->zinc respectively).

   IMPORTANT: the Shen package system's add-prefix-aliases step creates BOTH a
   bare name and a `shen.`-prefixed name for every unprefixed closure. These are
   DISTINCT bundle closures with DIFFERENT bytecode, so BOTH variants must be
   listed as separate entries (do NOT collapse them).

   This file is `tc -`-safe plain data + a predicate. `element?` is a bundled
   type-safe helper available in the reduced bundle.
   ============================================================================= *\

(tc -)

\* ----------------------------------------------------------------------------
   qbe-dynamic-closures - the 29-name exclusion list.

   Closures named here must route through the dynamic fallback, NOT native QBE.
   Keep bare and shen.-prefixed variants as SEPARATE entries - they are distinct
   bundle closures with different bytecode.
   ---------------------------------------------------------------------------- *\
(set qbe-dynamic-closures
     [normalize
      normalize.41
      normalize.43
      normalize.44
      normalize.45
      normalize.46.47
      normalize-name.40
      normalize-names
      normalize-names.38.39
      shen.debruijn
      shen.debruijn.14
      shen.debruijn.14.15
      shen.debruijn.14.15.16
      shen.debruijn.14.15.16.17
      shen.debruijn.14.15.16.17.18
      shen.kl->zinc
      shen.normalize
      shen.normalize.4
      shen.normalize.6
      shen.normalize.7
      shen.normalize.8
      shen.normalize.9.10
      shen.normalize-name.11
      shen.normalize-names
      shen.normalize-names.12.13
      shen.zinc-c-tail
      shen.zinc-c-tail.0
      shen.zinc-t-tail
      shen.zinc-t-tail.2])

\* ----------------------------------------------------------------------------
   qbe-static-closure? - the predicate the Slice 3 lowerer uses.

   Returns true for closures whose bodies are full-arity static (QBE-compilable);
   false for the dynamic closures in the exclusion list.
   ---------------------------------------------------------------------------- *\
(define qbe-static-closure?
  { symbol --> boolean }
  Name -> (not (element? Name (value qbe-dynamic-closures))))

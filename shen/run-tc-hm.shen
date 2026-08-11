(tc -)

\* run-tc-hm.shen — driver script for the HM type checker.
   Usage: (run-tc-hm "shen/util.shen")
   Prints per-define results.  Load this file in host shen-scheme. *\

(load "shen/tc-hm.shen")

(define run-tc-hm
  { string --> string }
  Path ->
    (let Results (tc-hm-file Path)
      (let OkCount (tc-count-ok Results)
        (let FailCount (tc-count-fail Results)
          (let Output (print-tc-results Results)
            (do (print (cn "=== " (cn Path (cn " ===\n" Output)))
                (print "\n")
                (print (cn "OK: " (cn (str OkCount) (cn "  FAIL: " (cn (str FailCount) "\n")))))
                "")))))))

(define tc-count-ok
  { (list tc-result) --> number }
  [] -> 0
  [[ok _] | Rest] -> (+ 1 (tc-count-ok Rest))
  [_ | Rest] -> (tc-count-ok Rest))

(define tc-count-fail
  { (list tc-result) --> number }
  [] -> 0
  [[fail _] | Rest] -> (+ 1 (tc-count-fail Rest))
  [_ | Rest] -> (tc-count-fail Rest))

\* ===== run-tc-hm-all: type-check all Group A files ===== *\

(define run-tc-hm-all
  { --> string }
  -> (let All (tc-hm-all)
       (tc-print-all-results All)
       ""))

(define tc-print-all-results
  { (list (list string (list tc-result))) --> (list symbol) }
  [] -> []
  [[File Results] | Rest] ->
    (do (print (cn "=== " (cn File " ===")))
        (print (print-tc-results Results))
        (print "\n")
        (tc-print-all-results Rest)))

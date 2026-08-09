(define index_h X [X | Rest] C -> C
  X [_ | Rest] C -> (index_h X Rest (+ 1 C))
  _ _ _          -> -1)

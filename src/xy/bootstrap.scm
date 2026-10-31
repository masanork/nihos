; xy user/init.scm -- edit this source in xy, then Apply & Save.
; Definitions are rebuilt together; top-level editor effects are rejected.
(define (stamp)
  (buffer/insert! "Hello from Scheme!\n"))
(command/register! "stamp" (lambda () (stamp)))

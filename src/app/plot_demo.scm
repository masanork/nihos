; 日本語 / Scheme animation
(app/resume!)
(plot/set! #:color1 #x0755aa)
(app/on-frame!
  (lambda (ticks)
    (plot/set! #:amplitude
      (+ 50 (plot/sine ticks 25)))))

; Paste into *scratch*, then Esc -> eval-buffer.
; Settings are RAM-local until a configuration loader is connected.
(view/set! #:theme 'light #:font 'gothic #:size 32
           #:direction 'horizontal #:line-gap 12)
(view/set! #:background #xfaf6ee #:foreground #x1c1c1e
           #:ruby-color #x5c4033 #:cursor-color #xcc3322)
(view/set! #:ruby-size 16 #:ruby-gap 2 #:margin-x 24 #:margin-y 24)
(view/set! #:cursor-width 2 #:status-padding 4
           #:status-background #xeae4d6 #:status-foreground #x283848
           #:linear-blend #f)

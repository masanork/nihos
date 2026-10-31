; Tic-tac-toe for the bounded xy Scheme runtime.
; Paste into the document, then Esc -> eval-buffer.
; Start with the ttt command, then move with (play 5).
; Cells 1-9, left to right, top to bottom. You are X, CPU is O.
; Board is inserted into the document after every move; the
; status row reports the result symbol of each (play n).
; Subset only: define lambda set! let if begin or quote,
; binary + - * = <, not, buffer/insert!, command/register!.
; No lists: board is nine globals (0 empty, 1 X, -1 O), and
; line sums are cached in globals to stay well under the
; 1024-tick request budget. CPU: win, block, center, corners.
(define b0 0) (define b1 0) (define b2 0)
(define b3 0) (define b4 0) (define b5 0)
(define b6 0) (define b7 0) (define b8 0)
(define s0 0) (define s1 0) (define s2 0) (define s3 0)
(define s4 0) (define s5 0) (define s6 0) (define s7 0)
(define moves 0)
(define over 0)
(define (cell-at i)
  (if (= i 0) b0 (if (= i 1) b1 (if (= i 2) b2
  (if (= i 3) b3 (if (= i 4) b4 (if (= i 5) b5
  (if (= i 6) b6 (if (= i 7) b7 b8)))))))))
(define (set-cell! i v)
  (if (= i 0) (set! b0 v) (if (= i 1) (set! b1 v)
  (if (= i 2) (set! b2 v) (if (= i 3) (set! b3 v)
  (if (= i 4) (set! b4 v) (if (= i 5) (set! b5 v)
  (if (= i 6) (set! b6 v) (if (= i 7) (set! b7 v)
  (set! b8 v))))))))))
(define (compute-sums!)
  (begin (set! s0 (+ b0 (+ b1 b2))) (set! s1 (+ b3 (+ b4 b5)))
         (set! s2 (+ b6 (+ b7 b8))) (set! s3 (+ b0 (+ b3 b6)))
         (set! s4 (+ b1 (+ b4 b7))) (set! s5 (+ b2 (+ b5 b8)))
         (set! s6 (+ b0 (+ b4 b8))) (set! s7 (+ b2 (+ b4 b6)))))
(define (any-line t)
  (if (or (= s0 t) (or (= s1 t) (or (= s2 t)
        (or (= s3 t) (or (= s4 t) (or (= s5 t)
        (or (= s6 t) (= s7 t)))))))) 1 0))
(define (winner)
  (begin (compute-sums!)
    (if (= (any-line 3) 1) 1
      (if (= (any-line -3) 1) -1 0))))
(define (empty-in i j k)
  (if (= (cell-at i) 0) i (if (= (cell-at j) 0) j k)))
; Index completing a line whose cached sum is t, else -1.
(define (scan t)
  (if (= s0 t) (empty-in 0 1 2)
  (if (= s1 t) (empty-in 3 4 5)
  (if (= s2 t) (empty-in 6 7 8)
  (if (= s3 t) (empty-in 0 3 6)
  (if (= s4 t) (empty-in 1 4 7)
  (if (= s5 t) (empty-in 2 5 8)
  (if (= s6 t) (empty-in 0 4 8)
  (if (= s7 t) (empty-in 2 4 6) -1)))))))))
(define (cpu-free-move)
  (if (= b4 0) 4 (if (= b0 0) 0 (if (= b2 0) 2
  (if (= b6 0) 6 (if (= b8 0) 8 (if (= b1 0) 1
  (if (= b3 0) 3 (if (= b5 0) 5 7)))))))))
(define (cpu-pick)
  (begin (compute-sums!)
    (let ((w (scan -2)))
      (if (< w 0)
        (let ((k (scan 2)))
          (if (< k 0) (cpu-free-move) k))
        w))))
(define (show-cell v)
  (if (= v 0) (buffer/insert! ".")
    (if (= v 1) (buffer/insert! "X") (buffer/insert! "O"))))
(define (show-row x y z)
  (begin (show-cell x) (buffer/insert! " ")
         (show-cell y) (buffer/insert! " ")
         (show-cell z) (buffer/insert! "\n")))
(define (show)
  (begin (buffer/insert! "\n") (show-row b0 b1 b2)
         (show-row b3 b4 b5) (show-row b6 b7 b8)))
(define (new-game)
  (begin (set! b0 0) (set! b1 0) (set! b2 0)
         (set! b3 0) (set! b4 0) (set! b5 0)
         (set! b6 0) (set! b7 0) (set! b8 0)
         (set! moves 0) (set! over 0) 'ready))
(define (play n)
  (if (= over 1) 'game-over
  (if (or (< n 1) (< 9 n)) 'bad-move
  (if (not (= (cell-at (- n 1)) 0)) 'occupied
  (begin (set-cell! (- n 1) 1) (set! moves (+ moves 1))
    (if (= (winner) 1)
      (begin (set! over 1) (show) 'you-win)
      (if (= moves 9)
        (begin (set! over 1) (show) 'draw)
        (begin (set-cell! (cpu-pick) -1)
               (set! moves (+ moves 1))
               (if (= (winner) -1)
                 (begin (set! over 1) (show) 'cpu-win)
                 (begin (show) 'your-turn))))))))))
(command/register! "ttt"
  (lambda () (begin (new-game) (show) 'new-game)))

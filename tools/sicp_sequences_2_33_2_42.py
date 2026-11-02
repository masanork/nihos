#!/usr/bin/env python3
"""Selected SICP sequence, matrix and queens exercise observations."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET
import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inv
import sicp_official_code as official

ACC='''(define (accumulate op initial xs) (if (null? xs) initial (op (car xs) (accumulate op initial (cdr xs)))))
(define (fold-left op initial xs) (define (iter result rest) (if (null? rest) result (iter (op result (car rest)) (cdr rest)))) (iter initial xs))'''
BASIC='''(define (my-map f xs) (accumulate (lambda (x y) (cons (f x) y)) '() xs))
(define (my-append a b) (accumulate cons b a))
(define (my-length xs) (accumulate (lambda (x n) (+ n 1)) 0 xs))'''
HORNER='''(define (horner-eval x coefficients) (accumulate (lambda (a higher) (+ a (* x higher))) 0 coefficients))'''
LEAVES='''(define (count-leaves t) (accumulate + 0 (map (lambda (x) (cond ((null? x) 0) ((pair? x) (count-leaves x)) (else 1))) t)))'''
ACC_N='''(define (accumulate-n op initial seqs) (if (null? (car seqs)) '() (cons (accumulate op initial (map car seqs)) (accumulate-n op initial (map cdr seqs)))))'''
MATRIX='''(define (dot-product v w) (accumulate + 0 (map * v w)))
(define (matrix-*-vector m v) (map (lambda (row) (dot-product row v)) m))
(define (transpose m) (accumulate-n cons '() m))
(define (matrix-*-matrix m n) (let ((columns (transpose n))) (map (lambda (row) (map (lambda (col) (dot-product row col)) columns)) m)))'''
REVERSE='''(define (reverse-right xs) (accumulate (lambda (x acc) (append acc (list x))) '() xs))
(define (reverse-left xs) (fold-left (lambda (acc x) (cons x acc)) '() xs))'''
ENUM='''(define (enumerate low high) (if (> low high) '() (cons low (enumerate (+ low 1) high))))
(define (flatmap f xs) (accumulate append '() (map f xs)))
(define (filter pred xs) (cond ((null? xs) '()) ((pred (car xs)) (cons (car xs) (filter pred (cdr xs)))) (else (filter pred (cdr xs)))))'''
PAIRS='''(define (unique-pairs n) (flatmap (lambda (i) (map (lambda (j) (list i j)) (enumerate 1 (- i 1)))) (enumerate 1 n)))'''
TRIPLES='''(define (triples n s) (filter (lambda (t) (= (+ (car t) (cadr t) (car (cdr (cdr t)))) s)) (flatmap (lambda (i) (flatmap (lambda (j) (map (lambda (k) (list i j k)) (enumerate 1 (- j 1)))) (enumerate 1 (- i 1)))) (enumerate 1 n))))'''
QUEENS='''(define (queens size)
 (define (safe? positions) (define (check rest distance) (if (null? rest) #t (and (not (= (car positions) (car rest))) (not (= (abs (- (car positions) (car rest))) distance)) (check (cdr rest) (+ distance 1))))) (check (cdr positions) 1))
 (define (queen-cols k) (if (= k 0) (list '()) (filter safe? (flatmap (lambda (rest) (map (lambda (row) (cons row rest)) (enumerate 1 size))) (queen-cols (- k 1))))))
 (queen-cols size))'''
QUEENS_FAST_COUNT = QUEENS.replace('(define (queens size)', '(define calls 0) (define (queens size)', 1).replace('(define (queen-cols k) (if', '(define (queen-cols k) (set! calls (+ calls 1)) (if', 1)
QUEENS_SLOW_COUNT = QUEENS_FAST_COUNT.replace('(flatmap (lambda (rest) (map (lambda (row) (cons row rest)) (enumerate 1 size))) (queen-cols (- k 1)))', '(flatmap (lambda (row) (map (lambda (rest) (cons row rest)) (queen-cols (- k 1)))) (enumerate 1 size))', 1)
if QUEENS_FAST_COUNT == QUEENS_SLOW_COUNT: raise ValueError('queens transformation did not apply')

def queen_count(n):
 def go(cols,diag1,diag2):
  if len(cols)==n:return 1
  row=len(cols)
  return sum(go(cols+(c,),diag1|{row-c},diag2|{row+c}) for c in range(n) if c not in cols and row-c not in diag1 and row+c not in diag2)
 return go((),set(),set())

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 add('2.33',ACC+'\n'+BASIC,"(my-map (lambda (x) (* x x)) '(1 2 3))",'(1 4 9)')
 add('2.33',ACC+'\n'+BASIC,"(my-append '(1 2) '(3 4))",'(1 2 3 4)')
 add('2.33',ACC+'\n'+BASIC,"(my-length '(a b c d))",'4')
 add('2.34',ACC+'\n'+HORNER,"(horner-eval 2 '(1 3 0 5 0 1))",'79')
 add('2.34',ACC+'\n'+HORNER,"(horner-eval 3 '(2 -1 4))",'35')
 add('2.35',ACC+'\n'+LEAVES,"(count-leaves '((1 2) (3 (4 5))))",'5')
 add('2.35',ACC+'\n'+LEAVES,"(count-leaves '())",'0')
 add('2.36',ACC+'\n'+ACC_N,"(accumulate-n + 0 '((1 2 3) (4 5 6) (7 8 9) (10 11 12)))",'(22 26 30)')
 add('2.37',ACC+'\n'+ACC_N+'\n'+MATRIX,"(matrix-*-vector '((1 2) (3 4)) '(5 6))",'(17 39)')
 add('2.37',ACC+'\n'+ACC_N+'\n'+MATRIX,"(transpose '((1 2 3) (4 5 6)))",'((1 4) (2 5) (3 6))')
 add('2.37',ACC+'\n'+ACC_N+'\n'+MATRIX,"(matrix-*-matrix '((1 2) (3 4)) '((5 6) (7 8)))",'((19 22) (43 50))')
 add('2.38',ACC,"(accumulate / 1 '(1 2 3))",'3/2')
 add('2.38',ACC,"(fold-left / 1 '(1 2 3))",'1/6')
 add('2.38',ACC,"(accumulate list '() '(1 2 3))",'(1 (2 (3 ())))')
 add('2.38',ACC,"(fold-left list '() '(1 2 3))",'(((() 1) 2) 3)')
 add('2.39',ACC+'\n'+REVERSE,"(reverse-right '(1 2 3))",'(3 2 1)')
 add('2.39',ACC+'\n'+REVERSE,"(reverse-left '(1 2 3))",'(3 2 1)')
 add('2.40',ACC+'\n'+ENUM+'\n'+PAIRS,'(unique-pairs 4)','((2 1) (3 1) (3 2) (4 1) (4 2) (4 3))')
 add('2.41',ACC+'\n'+ENUM+'\n'+TRIPLES,'(triples 5 9)','((4 3 2) (5 3 1))')
 for n in (0,1,4,8):add('2.42',ACC+'\n'+ENUM+'\n'+QUEENS,f'(length (queens {n}))',queen_count(n))
 for n in (1,2,3):
  for label,setup,count in (('ordinary',QUEENS_FAST_COUNT,n+1),('reordered',QUEENS_SLOW_COUNT,sum(n**i for i in range(n+1)))):
   add('2.43',ACC+'\n'+ENUM+'\n'+setup,f'(let* ((solutions (length (queens {n}))) (count calls)) (list solutions count))',f'({queen_count(n)} {count})')
   rows[-1]['variant']=label
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:root=ET.fromstring(t.extractfile('xml/chapter2/section2/subsection3.xml').read())
 labels={'ex:2_33','ex:horner','ex:countleaves-as-accumulation','ex:accumulate-n','ex:matrix-ops','ex:fold-right-left','ex:2_39','ex:2_40','ex:2_41','ex:8queens','ex:2_43'}
 if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch2.scm').read().decode('ascii')
 for phrase in ('(define (accumulate op initial sequence)',';; EXERCISE 2.34',';; EXERCISE 2.36',';; EXERCISE 2.37',';; EXERCISE 2.38','(define (flatmap proc seq)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Candidate finite cases only; queens n=8 is attempted against an independent exact count. Failures and drawing/proof obligations remain explicit.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

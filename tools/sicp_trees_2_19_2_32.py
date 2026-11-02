#!/usr/bin/env python3
"""Isolated finite candidates and expected gaps for SICP 2.19-2.32."""
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

CHANGE='''(define (cc amount coins) (cond ((= amount 0) 1) ((or (< amount 0) (null? coins)) 0) (else (+ (cc amount (cdr coins)) (cc (- amount (car coins)) coins)))))'''
PARITY='''(define (same-parity f . r) (define (k xs) (cond ((null? xs) '()) ((= (remainder (abs (car xs)) 2) (remainder (abs f) 2)) (cons (car xs) (k (cdr xs)))) (else (k (cdr xs))))) (cons f (k r)))'''
SQUARE_REVERSED='''(define (square x) (* x x)) (define nil '()) (define (square-list items) (define (iter things answer) (if (null? things) answer (iter (cdr things) (cons (square (car things)) answer)))) (iter items nil))'''
SQUARE_WRONG='''(define (square x) (* x x)) (define nil '()) (define (square-list items) (define (iter things answer) (if (null? things) answer (iter (cdr things) (cons answer (square (car things)))))) (iter items nil))'''
EACH='''(define seen '()) (define (for-each f xs) (if (null? xs) 'done (begin (f (car xs)) (for-each f (cdr xs)))))'''
DEEP='''(define (deep-reverse x) (if (pair? x) (append (deep-reverse (cdr x)) (list (deep-reverse (car x)))) x))'''
FRINGE='''(define (fringe x) (cond ((null? x) '()) ((pair? x) (append (fringe (car x)) (fringe (cdr x)))) (else (list x))))'''
MOBILE_COMMON='''(define (total-weight mobile) (+ (branch-weight (left-branch mobile)) (branch-weight (right-branch mobile))))
(define (branch-weight branch) (let ((structure (branch-structure branch))) (if (pair? structure) (total-weight structure) structure)))
(define (branch-balanced? branch) (let ((structure (branch-structure branch))) (if (pair? structure) (balanced? structure) #t)))
(define (balanced? mobile) (let ((left (left-branch mobile)) (right (right-branch mobile))) (and (= (* (branch-length left) (branch-weight left)) (* (branch-length right) (branch-weight right))) (branch-balanced? left) (branch-balanced? right))))'''
MOBILE_LIST='''(define (make-mobile a b) (list a b)) (define (left-branch x) (car x)) (define (right-branch x) (cadr x))
(define (make-branch n s) (list n s)) (define (branch-length b) (car b)) (define (branch-structure b) (cadr b))'''
MOBILE_PAIR='''(define (make-mobile a b) (cons a b)) (define (left-branch x) (car x)) (define (right-branch x) (cdr x))
(define (make-branch n s) (cons n s)) (define (branch-length b) (car b)) (define (branch-structure b) (cdr b))'''
SQUARE_TREE='''(define (square x) (* x x)) (define (square-tree t) (cond ((null? t) '()) ((pair? t) (cons (square-tree (car t)) (square-tree (cdr t)))) (else (square t))))'''
TREE_MAP='''(define (square x) (* x x)) (define (tree-map f t) (cond ((null? t) '()) ((pair? t) (cons (tree-map f (car t)) (tree-map f (cdr t)))) (else (f t)))) (define (square-tree tree) (tree-map square tree))'''
SUBSETS='''(define (subsets s) (if (null? s) (list '()) (let ((rest (subsets (cdr s)))) (append rest (map (lambda (x) (cons (car s) x)) rest)))))'''

def change(n,coins):
 dp=[1]+[0]*n
 for coin in coins:
  for i in range(coin,n+1):dp[i]+=dp[i-coin]
 return dp[n]

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 for n in (0,5,10,20,100):add('2.19',CHANGE,f"(cc {n} '(50 25 10 5 1))",change(n,[50,25,10,5,1]))
 add('2.20',PARITY,'(same-parity 1 2 3 4 5 6 7)','(1 3 5 7)')
 add('2.20',PARITY,'(same-parity 2 3 4 5 6 7)','(2 4 6)')
 add('2.20',PARITY,'(same-parity -1 2 3 -5)','(-1 3 -5)')
 add('2.22',SQUARE_REVERSED,"(square-list '(1 2 3 4))",'(16 9 4 1)')
 add('2.22',SQUARE_WRONG,"(square-list '(1 2 3))",'(((() . 1) . 4) . 9)')
 add('2.23',EACH,"(begin (for-each (lambda (x) (set! seen (append seen (list x)))) '(57 321 88)) seen)",'(57 321 88)')
 add('2.23',EACH,"(begin (for-each (lambda (x) (set! seen (list x))) '()) seen)",'()')
 add('2.24','',"(list 1 (list 2 (list 3 4)))",'(1 (2 (3 4)))')
 add('2.25','',"(car (cdr (car (cdr (cdr '(1 3 (5 7) 9))))))",'7')
 add('2.25','',"(car (car '((7))))",'7')
 nested = "'(1 (2 (3 (4 (5 (6 7))))))"
 for _ in range(6):nested=f'(car (cdr {nested}))'
 add('2.25','',nested,'7')
 for expr,answer in (("(append x y)",'(1 2 3 4 5 6)'),("(cons x y)",'((1 2 3) 4 5 6)'),("(list x y)",'((1 2 3) (4 5 6))')):add('2.26',"(define x '(1 2 3)) (define y '(4 5 6))",expr,answer)
 add('2.27',DEEP,"(deep-reverse '((1 2) (3 4)))",'((4 3) (2 1))')
 add('2.27',DEEP,"(deep-reverse '(1 (2 (3 4)) 5))",'(5 ((4 3) 2) 1)')
 add('2.28',FRINGE,"(fringe '((1 2) (3 4)))",'(1 2 3 4)')
 add('2.28',FRINGE,"(fringe '(((1 2) (3 4)) ((1 2) (3 4))))",'(1 2 3 4 1 2 3 4)')
 for rep in (MOBILE_LIST,MOBILE_PAIR):
  setup=rep+'\n'+MOBILE_COMMON
  add('2.29',setup,'(let ((m (make-mobile (make-branch 2 3) (make-branch 3 2)))) (list (total-weight m) (balanced? m)))','(5 #t)')
  add('2.29',setup,'(let ((m (make-mobile (make-branch 2 3) (make-branch 2 2)))) (list (total-weight m) (balanced? m)))','(5 #f)')
  add('2.29',setup,'(let* ((inner (make-mobile (make-branch 1 2) (make-branch 2 1))) (m (make-mobile (make-branch 1 inner) (make-branch 3 1)))) (list (total-weight m) (balanced? m)))','(4 #t)')
 tree="'(1 (2 (3 4) 5) (6 7))";squared='(1 (4 (9 16) 25) (36 49))'
 add('2.30',SQUARE_TREE,f'(square-tree {tree})',squared)
 add('2.31',TREE_MAP,f'(square-tree {tree})',squared)
 add('2.31',TREE_MAP,"(tree-map (lambda (x) (+ x 1)) '(1 (2 3)))",'(2 (3 4))')
 add('2.32',SUBSETS,"(subsets '())",'(())')
 add('2.32',SUBSETS,"(subsets '(1 2 3))",'(() (3) (2) (2 3) (1) (1 3) (1 2) (1 2 3))')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 required={'subsection1.xml':{'ex:2_19','ex:dotted-arglist','ex:iter-square-list','ex:for-each'},'subsection2.xml':{'ex:2_24','ex:2_25','ex:2_26','ex:2_27','ex:fringe','ex:mobile','ex:square-tree','ex:tree-map','ex:2_32'}}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for name,labels in required.items():
   root=ET.fromstring(t.extractfile('xml/chapter2/section2/'+name).read())
   if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing: '+name)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch2.scm').read().decode('ascii')
 for phrase in (';; EXERCISE 2.19',';; EXERCISE 2.22',';; EXERCISE 2.24',';; EXERCISE 2.29',';; EXERCISE 2.32','(define (subsets s)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite candidate observations. 2.22 uses the two original faulty procedures with nil defined as empty list; 2.23 uses state mutation instead of unavailable output ports. The 2.20 candidate exercises dotted formals and may fail in xy. No diagrams are graded.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

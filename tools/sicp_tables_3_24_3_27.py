#!/usr/bin/env python3
"""Finite mutable-table candidates for SICP 3.24-3.27."""
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

APPROX='''(define (same-key? a b) (< (abs (- a b)) 2))
(define (find key records) (cond ((null? records) #f) ((same-key? key (car (car records))) (car records)) (else (find key (cdr records)))))
(define (make-table) (list '*table*))
(define (put! t key value) (let ((entry (find key (cdr t)))) (if entry (set-cdr! entry value) (set-cdr! t (cons (cons key value) (cdr t)))) 'ok))
(define (get t key) (let ((entry (find key (cdr t)))) (if entry (cdr entry) 'missing)))'''
MULTI='''(define (make-node) (cons 'missing '()))
(define (find key records) (cond ((null? records) #f) ((equal? key (car (car records))) (car records)) (else (find key (cdr records)))))
(define (put! node keys value) (if (null? keys) (begin (set-car! node value) 'ok) (let ((entry (find (car keys) (cdr node)))) (if entry (put! (cdr entry) (cdr keys) value) (let ((child (make-node))) (set-cdr! node (cons (cons (car keys) child) (cdr node))) (put! child (cdr keys) value))))))
(define (get node keys) (if (null? keys) (car node) (let ((entry (find (car keys) (cdr node)))) (if entry (get (cdr entry) (cdr keys)) 'missing))))'''
BST='''(define (make-table) (cons '() '()))
(define (node key value) (cons key (cons value (cons '() '()))))
(define (key t) (car t)) (define (value t) (car (cdr t))) (define (left t) (car (cdr (cdr t)))) (define (right t) (cdr (cdr (cdr t))))
(define (set-left! t x) (set-car! (cdr (cdr t)) x)) (define (set-right! t x) (set-cdr! (cdr (cdr t)) x))
(define (insert-node t k v) (if (null? t) (node k v) (cond ((= k (key t)) (set-car! (cdr t) v) t) ((< k (key t)) (set-left! t (insert-node (left t) k v)) t) (else (set-right! t (insert-node (right t) k v)) t))))
(define (put! table k v) (set-car! table (insert-node (car table) k v)) 'ok)
(define (get-node t k) (cond ((null? t) 'missing) ((= k (key t)) (value t)) ((< k (key t)) (get-node (left t) k)) (else (get-node (right t) k))))
(define (get table k) (get-node (car table) k))'''
MEMO='''(define table '()) (define misses 0)
(define (find n xs) (cond ((null? xs) #f) ((= n (car (car xs))) (car xs)) (else (find n (cdr xs)))))
(define (memo-fib n) (let ((entry (find n table))) (if entry (cdr entry) (begin (set! misses (+ misses 1)) (let ((v (if (< n 2) n (+ (memo-fib (- n 1)) (memo-fib (- n 2)))))) (set! table (cons (cons n v) table)) v)))))'''

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 add('3.24',APPROX,"(let ((t (make-table))) (put! t 10 'a) (list (get t 11) (get t 13)))",'(a missing)')
 add('3.24',APPROX,"(let ((t (make-table))) (put! t 10 'a) (put! t 11 'b) (get t 10))",'b')
 add('3.25',MULTI,"(let ((t (make-node))) (put! t '(a b) 12) (put! t '(a c) 9) (list (get t '(a b)) (get t '(a c)) (get t '(b))))",'(12 9 missing)')
 add('3.25',MULTI,"(let ((t (make-node))) (put! t '(a) 7) (put! t '(a b) 8) (list (get t '(a)) (get t '(a b))))",'(7 8)')
 add('3.26',BST,"(let ((t (make-table))) (put! t 5 'a) (put! t 2 'b) (put! t 8 'c) (list (get t 2) (get t 5) (get t 8) (get t 4)))",'(b a c missing)')
 add('3.26',BST,"(let ((t (make-table))) (put! t 5 'a) (put! t 5 'z) (get t 5))",'z')
 for n in (0,5,10):
  a,b=0,1
  for _ in range(n):a,b=b,a+b
  add('3.27',MEMO,f'(let* ((v (memo-fib {n})) (count misses) (w (memo-fib {n}))) (list v count w))',f'({a} {n+1} {a})')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:root=ET.fromstring(t.extractfile('xml/chapter3/section3/subsection3.xml').read())
 if not {'ex:numeric-keys','ex:3_25','ex:3_26','ex:memoization'}<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch3.scm').read().decode('ascii')
 for phrase in ('(define (lookup key table)','(define (insert! key value table)','(define (make-table)',';; EXERCISE 3.27'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite independently written candidates; comparator 3.24 is a fixture, 3.26 uses an unbalanced BST, memoization counts cache misses. No performance proof, persistence, thread safety or table API standardization claim.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

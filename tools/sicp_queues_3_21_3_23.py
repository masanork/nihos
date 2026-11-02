#!/usr/bin/env python3
"""Finite queue and deque candidates for SICP 3.21-3.23."""
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

QUEUE='''(define (make-queue) (cons '() '()))
(define (front-ptr q) (car q)) (define (rear-ptr q) (cdr q))
(define (empty-queue? q) (null? (front-ptr q)))
(define (insert-queue! q item) (let ((n (cons item '()))) (if (empty-queue? q) (begin (set-car! q n) (set-cdr! q n)) (begin (set-cdr! (rear-ptr q) n) (set-cdr! q n))) q))
(define (delete-queue! q) (set-car! q (cdr (front-ptr q))) q)
(define (queue-contents q) (front-ptr q))'''
CLOSURE_QUEUE='''(define (make-queue) (let ((front '()) (rear '()))
 (define (insert! item) (let ((n (cons item '()))) (if (null? front) (begin (set! front n) (set! rear n)) (begin (set-cdr! rear n) (set! rear n))) 'ok))
 (define (delete!) (set! front (cdr front)) 'ok)
 (define (get) front)
 (lambda (message) (cond ((eq? message 'insert!) insert!) ((eq? message 'delete!) delete!) ((eq? message 'get) get) (else #f)))))'''
DEQUE='''(define (make-deque) (cons '() '()))
(define (make-node x) (cons x (cons '() '())))
(define (value n) (car n)) (define (prev n) (car (cdr n))) (define (next n) (cdr (cdr n)))
(define (set-prev! n x) (set-car! (cdr n) x)) (define (set-next! n x) (set-cdr! (cdr n) x))
(define (front-insert! d x) (let ((n (make-node x)) (f (car d))) (if (null? f) (begin (set-car! d n) (set-cdr! d n)) (begin (set-next! n f) (set-prev! f n) (set-car! d n))) 'ok))
(define (rear-insert! d x) (let ((n (make-node x)) (r (cdr d))) (if (null? r) (begin (set-car! d n) (set-cdr! d n)) (begin (set-prev! n r) (set-next! r n) (set-cdr! d n))) 'ok))
(define (front-delete! d) (let* ((f (car d)) (n (next f))) (if (null? n) (begin (set-car! d '()) (set-cdr! d '())) (begin (set-prev! n '()) (set-car! d n))) 'ok))
(define (rear-delete! d) (let* ((r (cdr d)) (p (prev r))) (if (null? p) (begin (set-car! d '()) (set-cdr! d '())) (begin (set-next! p '()) (set-cdr! d p))) 'ok))
(define (deque->list d) (define (go n) (if (null? n) '() (cons (value n) (go (next n))))) (go (car d)))
(define (deque-reverse d) (define (go n) (if (null? n) '() (cons (value n) (go (prev n))))) (go (cdr d)))'''

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 add('3.21',QUEUE,"(let ((q (make-queue))) (insert-queue! q 'a) (insert-queue! q 'b) (queue-contents q))",'(a b)')
 add('3.21',QUEUE,"(let ((q (make-queue))) (insert-queue! q 'a) (insert-queue! q 'b) (delete-queue! q) (queue-contents q))",'(b)')
 add('3.21',QUEUE,"(let ((q (make-queue))) (insert-queue! q 'a) (delete-queue! q) (insert-queue! q 'c) (queue-contents q))",'(c)')
 add('3.22',CLOSURE_QUEUE,"(let ((q (make-queue))) ((q 'insert!) 'a) ((q 'insert!) 'b) ((q 'get)))",'(a b)')
 add('3.22',CLOSURE_QUEUE,"(let ((q (make-queue))) ((q 'insert!) 'a) ((q 'insert!) 'b) ((q 'delete!)) ((q 'get)))",'(b)')
 add('3.22',CLOSURE_QUEUE,"(let ((q (make-queue))) ((q 'insert!) 'a) ((q 'delete!)) ((q 'insert!) 'c) ((q 'get)))",'(c)')
 add('3.23',DEQUE,"(let ((d (make-deque))) (front-insert! d 'b) (front-insert! d 'a) (rear-insert! d 'c) (list (deque->list d) (deque-reverse d)))",'((a b c) (c b a))')
 add('3.23',DEQUE,"(let ((d (make-deque))) (front-insert! d 'b) (front-insert! d 'a) (rear-insert! d 'c) (front-delete! d) (list (deque->list d) (deque-reverse d)))",'((b c) (c b))')
 add('3.23',DEQUE,"(let ((d (make-deque))) (front-insert! d 'b) (front-insert! d 'a) (rear-insert! d 'c) (rear-delete! d) (front-delete! d) (list (deque->list d) (deque-reverse d)))",'((b) (b))')
 add('3.23',DEQUE,"(let ((d (make-deque))) (rear-insert! d 'a) (rear-delete! d) (front-insert! d 'b) (list (deque->list d) (deque-reverse d)))",'((b) (b))')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:root=ET.fromstring(t.extractfile('xml/chapter3/section3/subsection2.xml').read())
 if not {'ex:3_21','ex:3_22','ex:deque'}<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch3.scm').read().decode('ascii')
 for phrase in ('(define (make-queue)','(define (insert-queue! queue item)','(define (delete-queue! queue)',';; EXERCISE 3.21'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite independently written queue/deque candidates. 3.21 observes queue contents instead of printing because output ports are unavailable. Empty-deletion errors and concurrency are not tested.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

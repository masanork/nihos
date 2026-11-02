#!/usr/bin/env python3
"""SICP 3.12-3.20: sharing, mutation and bounded cycle observations."""
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

LAST='''(define (last-pair x) (if (null? (cdr x)) x (last-pair (cdr x))))'''
APPEND='''(define (append! x y) (set-cdr! (last-pair x) y) x)'''
CYCLE='''(define (make-cycle x) (set-cdr! (last-pair x) x) x)'''
MYSTERY='''(define (mystery x) (define (loop x y) (if (null? x) y (let ((temp (cdr x))) (set-cdr! x y) (loop temp x)))) (loop x '()))'''
WOW='''(define (set-to-wow! x) (set-car! (car x) 'wow) x)'''
NAIVE='''(define (count-pairs x) (if (not (pair? x)) 0 (+ (count-pairs (car x)) (count-pairs (cdr x)) 1)))'''
COUNT='''(define (count-pairs x) (let ((seen '())) (define (walk x) (cond ((not (pair? x)) 0) ((memq x seen) 0) (else (set! seen (cons x seen)) (+ 1 (walk (car x)) (walk (cdr x)))))) (walk x)))'''
VISITED='''(define (cycle? xs) (define (iter p seen) (cond ((not (pair? p)) #f) ((memq p seen) #t) (else (iter (cdr p) (cons p seen))))) (iter xs '()))'''
FLOYD='''(define (cycle? xs) (define (iter slow fast) (if (or (not (pair? fast)) (not (pair? (cdr fast)))) #f (let ((a (cdr slow)) (b (cdr (cdr fast)))) (if (eq? a b) #t (iter a b))))) (iter xs xs))'''
PROCEDURAL='''(define (cons x y) (define (set-x! v) (set! x v)) (define (set-y! v) (set! y v)) (lambda (m) (cond ((eq? m 'car) x) ((eq? m 'cdr) y) ((eq? m 'set-car!) set-x!) ((eq? m 'set-cdr!) set-y!))))
(define (car z) (z 'car)) (define (cdr z) (z 'cdr)) (define (set-car! z v) ((z 'set-car!) v)) (define (set-cdr! z v) ((z 'set-cdr!) v))'''

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 add('3.12',LAST+'\n'+APPEND,"(let* ((x (list 'a 'b)) (y (list 'c 'd)) (z (append x y))) (list z (cdr x)))",'((a b c d) (b))')
 add('3.12',LAST+'\n'+APPEND,"(let* ((x (list 'a 'b)) (y (list 'c 'd)) (w (append! x y))) (list w (cdr x)))",'((a b c d) (b c d))')
 add('3.13',LAST+'\n'+CYCLE,"(let ((z (make-cycle (list 'a 'b 'c)))) (eq? (cdr (cdr (cdr z))) z))",'#t')
 add('3.13',LAST+'\n'+CYCLE,"(let ((z (make-cycle (list 'a 'b 'c)))) (list? z))",'#f')
 add('3.14',MYSTERY,"(let* ((v (list 'a 'b 'c 'd)) (w (mystery v))) (list w v))",'((d c b a) (a))')
 add('3.14',MYSTERY,"(mystery '())",'()')
 add('3.15',WOW,"(let* ((x (list 'a 'b)) (z1 (cons x x)) (z2 (cons (list 'a 'b) (list 'a 'b)))) (set-to-wow! z1) (set-to-wow! z2) (list z1 z2))",'(((wow b) wow b) ((wow b) a b))')
 add('3.16',NAIVE,"(let* ((a (list 'x)) (b (cons a a)) (c (cons b b))) (count-pairs c))",'7')
 add('3.16',NAIVE,"(let* ((a (list 'x)) (b (cons a a)) (c (cons b '()))) (count-pairs c))",'4')
 add('3.16',NAIVE,"(count-pairs (list 'a 'b 'c))",'3')
 add('3.17',COUNT,"(let* ((a (list 'x)) (b (cons a a)) (c (cons b b))) (count-pairs c))",'3')
 add('3.17',COUNT,"(let ((a (list 'x))) (set-cdr! a a) (count-pairs a))",'1')
 add('3.17',COUNT,"(count-pairs (list 'a 'b 'c))",'3')
 for ex,detector in (('3.18',VISITED),('3.19',FLOYD)):
  add(ex,detector,"(cycle? (list 'a 'b 'c))",'#f')
  add(ex,detector,"(let ((a (list 'x))) (set-cdr! a a) (cycle? a))",'#t')
  add(ex,detector,"(let* ((a (list 'a 'b 'c)) (b (cdr a))) (set-cdr! (cdr b) b) (cycle? a))",'#t')
  add(ex,detector,"(cycle? (cons 'a 'b))",'#f')
 add('3.20',PROCEDURAL,"(let* ((x (cons 1 2)) (z (cons x x))) (set-car! (cdr z) 17) (car x))",'17')
 add('3.20',PROCEDURAL,"(let ((x (cons 1 2))) (set-cdr! x 9) (cdr x))",'9')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:root=ET.fromstring(t.extractfile('xml/chapter3/section3/subsection1.xml').read())
 labels={'ex:append','ex:make-cycle','ex:mystery','ex:3_15','ex:count-pairs','ex:count-pairs2','ex:find-cycle','ex:3_19','ex:cons-with-assignment'}
 if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch3.scm').read().decode('ascii')
 for phrase in (';; EXERCISE 3.12','(define (append! x y)',';; EXERCISE 3.13','(define (make-cycle x)',';; EXERCISE 3.14','(define (mystery x)',';; EXERCISE 3.16','(define (count-pairs x)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite isolated sharing/cycle observations. Code is a candidate except where following the printed textbook procedures; diagrams, unbounded behavior and literal mutation are not graded.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

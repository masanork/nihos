#!/usr/bin/env python3
"""Finite event-driven circuit fixtures for SICP 3.28-3.31."""
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

SIM='''(define now 0) (define agenda '())
(define (insert-event e xs) (cond ((null? xs) (list e)) ((< (car e) (car (car xs))) (cons e xs)) (else (cons (car xs) (insert-event e (cdr xs))))))
(define (after-delay d f) (set! agenda (insert-event (cons (+ now d) f) agenda)))
(define (propagate) (if (null? agenda) 'done (let ((e (car agenda))) (set! agenda (cdr agenda)) (set! now (car e)) ((cdr e)) (propagate))))
(define (call-each fs) (if (null? fs) 'done (begin ((car fs)) (call-each (cdr fs)))))
(define (make-wire) (let ((signal 0) (actions '()))
 (define (set!signal v) (if (= v signal) 'done (begin (set! signal v) (call-each actions))))
 (define (accept f) (set! actions (cons f actions)) (f))
 (lambda (m) (cond ((eq? m 'get) signal) ((eq? m 'set) set!signal) ((eq? m 'on) accept) (else #f)))))
(define (get w) (w 'get)) (define (set w x) ((w 'set) x)) (define (on w f) ((w 'on) f))
(define (inv a out) (define (action) (let ((v (if (= (get a) 0) 1 0))) (after-delay 2 (lambda () (set out v))))) (on a action))
(define (and-gate a b out) (define (action) (let ((v (if (and (= (get a) 1) (= (get b) 1)) 1 0))) (after-delay 3 (lambda () (set out v))))) (on a action) (on b action))'''
DIRECT='''(define (or-gate a b out) (define (action) (let ((v (if (or (= (get a) 1) (= (get b) 1)) 1 0))) (after-delay 5 (lambda () (set out v))))) (on a action) (on b action))'''
DEMORGAN='''(define (or-gate a b out) (let ((na (make-wire)) (nb (make-wire)) (both (make-wire))) (inv a na) (inv b nb) (and-gate na nb both) (inv both out)))'''
ADDERS='''(define (half-adder a b sum carry) (let ((d (make-wire)) (e (make-wire))) (or-gate a b d) (and-gate a b carry) (inv carry e) (and-gate d e sum)))
(define (full-adder a b cin sum cout) (let ((s (make-wire)) (c1 (make-wire)) (c2 (make-wire))) (half-adder b cin s c1) (half-adder a s sum c2) (or-gate c1 c2 cout)))
(define (ripple as bs ss cin cout) (if (null? (cdr as)) (full-adder (car as) (car bs) cin (car ss) cout) (let ((next (make-wire))) (full-adder (car as) (car bs) cin (car ss) next) (ripple (cdr as) (cdr bs) (cdr ss) next cout))))'''
NO_INITIAL=SIM.replace('(define (accept f) (set! actions (cons f actions)) (f))','(define (accept f) (set! actions (cons f actions)))',1)
LIFO=SIM.replace('((< (car e) (car (car xs)))', '((<= (car e) (car (car xs)))', 1)
if LIFO==SIM:raise ValueError('event ordering fixture unchanged')

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected),sequential_setup=True))
 for ex,gate in (('3.28',DIRECT),('3.29',DEMORGAN)):
  for a,b in ((0,0),(0,1),(1,0),(1,1)):
   expr=f'(let ((a (make-wire)) (b (make-wire)) (out (make-wire))) (or-gate a b out) (set a {a}) (set b {b}) (propagate) (get out))'
   add(ex,SIM+'\n'+gate,expr,int(bool(a or b)))
 add('3.28',SIM+'\n'+DIRECT,'(let ((a (make-wire)) (b (make-wire)) (o (make-wire))) (or-gate a b o) (propagate) (let ((start now)) (set a 1) (propagate) (- now start)))','5')
 add('3.29',SIM+'\n'+DEMORGAN,'(let ((a (make-wire)) (b (make-wire)) (o (make-wire))) (or-gate a b o) (propagate) (let ((start now)) (set a 1) (propagate) (- now start)))','7')
 for a,b in ((0,0),(1,1),(1,3),(3,3)):
  expr=f'''(let ((a0 (make-wire)) (a1 (make-wire)) (b0 (make-wire)) (b1 (make-wire)) (s0 (make-wire)) (s1 (make-wire)) (cin (make-wire)) (cout (make-wire))) (ripple (list a0 a1) (list b0 b1) (list s0 s1) cin cout) (set a0 {a%2}) (set a1 {a//2}) (set b0 {b%2}) (set b1 {b//2}) (propagate) (list (get s0) (get s1) (get cout)))'''
  result=a+b;add('3.30',SIM+'\n'+DIRECT+'\n'+ADDERS,expr,f'({result%2} {(result//2)%2} {(result//4)%2})')
 add('3.31',SIM,'(let ((a (make-wire)) (o (make-wire))) (inv a o) (propagate) (get o))','1')
 add('3.31',NO_INITIAL,'(let ((a (make-wire)) (o (make-wire))) (inv a o) (propagate) (get o))','0')
 trace='(let ((a (make-wire)) (b (make-wire)) (o (make-wire)) (seen \'())) (and-gate a b o) (on o (lambda () (set! seen (append seen (list (get o)))))) (set b 1) (propagate) (set! seen \'()) (after-delay 1 (lambda () (set a 1))) (after-delay 1 (lambda () (set b 0))) (propagate) seen)'
 add('3.32',SIM,trace,'(1 0)')
 add('3.32',LIFO,trace,'()')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:root=ET.fromstring(t.extractfile('xml/chapter3/section3/subsection4.xml').read())
 if not {'ex:3_28','ex:3_29','ex:ripple-carry','ex:accept-action','ex:agenda-list'}<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch3.scm').read().decode('ascii')
 for phrase in ('(define (inverter input output)','(define (and-gate a1 a2 output)','(define (make-wire)','(define (after-delay delay action)',';; EXERCISE 3.31'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='A small independently written event-driven fixture; not the original simulator or hardware timing. 3.31 compares immediate action invocation with its omission.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

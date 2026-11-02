#!/usr/bin/env python3
"""Finite stateful candidates for SICP 3.1-3.7; no proof or I/O claims."""
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

ACCUM='''(define (make-accumulator n) (lambda (x) (set! n (+ n x)) n))'''
MONITOR='''(define (make-monitored f) (let ((n 0)) (lambda (x) (cond ((eq? x 'how-many-calls?) n) ((eq? x 'reset-count) (set! n 0) n) (else (set! n (+ n 1)) (f x))))))'''
ACCOUNT='''(define (make-account balance password)
 (define (withdraw amount) (if (>= balance amount) (begin (set! balance (- balance amount)) balance) "Insufficient funds"))
 (define (deposit amount) (set! balance (+ balance amount)) balance)
 (define (dispatch key operation) (if (eq? key password) (cond ((eq? operation 'withdraw) withdraw) ((eq? operation 'deposit) deposit) (else (lambda (x) 'unknown-operation))) (lambda (x) "Incorrect password"))) dispatch)'''
LOCKED='''(define (make-account balance password)
 (define failures 0)
 (define (call-the-cops amount) 'cops)
 (define (withdraw amount) (if (>= balance amount) (begin (set! balance (- balance amount)) balance) "Insufficient funds"))
 (define (deposit amount) (set! balance (+ balance amount)) balance)
 (define (dispatch key operation) (if (eq? key password) (begin (set! failures 0) (cond ((eq? operation 'withdraw) withdraw) ((eq? operation 'deposit) deposit) (else (lambda (x) 'unknown-operation)))) (begin (set! failures (+ failures 1)) (if (> failures 7) call-the-cops (lambda (x) "Incorrect password"))))) dispatch)'''
RAND='''(define (rand-update x) (remainder (+ (* 17 x) 43) 97))
(define rand (let ((x 7)) (lambda (message) (cond ((eq? message 'generate) (set! x (rand-update x)) x) ((eq? message 'reset) (lambda (seed) (set! x seed) x)) (else 'unknown-message)))))'''
JOINT='''(define (make-joint account old-password new-password) (lambda (password operation) (if (eq? password new-password) (account old-password operation) (account password operation))))'''

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=expected))
 add('3.1',ACCUM,"(let* ((a (make-accumulator 5)) (x (a 10)) (y (a 10))) (list x y))",'(15 25)')
 add('3.1',ACCUM,"(let* ((a (make-accumulator 2)) (b (make-accumulator 100)) (x (a 3)) (y (b 4)) (z (a -2))) (list x y z))",'(5 104 3)')
 add('3.2',MONITOR,"(let* ((s (make-monitored (lambda (x) (* x x)))) (a (s 10)) (b (s 3)) (c (s 'how-many-calls?))) (list a b c))",'(100 9 2)')
 add('3.2',MONITOR,"(let* ((s (make-monitored (lambda (x) (+ x 1)))) (a (s 5)) (reset (s 'reset-count)) (b (s 2)) (count (s 'how-many-calls?))) (list a reset b count))",'(6 0 3 1)')
 add('3.3',ACCOUNT,"(let* ((a (make-account 100 'secret-password)) (x ((a 'secret-password 'withdraw) 40)) (y ((a 'bad 'deposit) 50)) (z ((a 'secret-password 'deposit) 10))) (list x y z))",'(60 "Incorrect password" 70)')
 add('3.3',ACCOUNT,"(let* ((a (make-account 20 'p)) (x ((a 'p 'withdraw) 30)) (y ((a 'p 'deposit) 1))) (list x y))",'("Insufficient funds" 21)')
 wrong=' '.join("((a 'bad 'withdraw) 1)" for _ in range(7))
 add('3.4',LOCKED,f"(let ((a (make-account 100 'p))) {wrong} ((a 'bad 'withdraw) 1))",'cops')
 add('3.4',LOCKED,f"(let* ((a (make-account 100 'p)) (x (begin {wrong} ((a 'p 'deposit) 0))) (y ((a 'bad 'withdraw) 1))) (list x y))",'(100 "Incorrect password")')
 # The deterministic update function is a test fixture, not a quality claim about random numbers.
 add('3.6',RAND,"(let* ((a (rand 'generate)) (b (rand 'generate)) (r ((rand 'reset) 7)) (c (rand 'generate)) (d (rand 'generate))) (list a b r c d))",'(65 81 7 65 81)')
 add('3.6',RAND,"(let* ((r ((rand 'reset) 0)) (a (rand 'generate)) (b (rand 'generate))) (list r a b))",'(0 43 95)')
 add('3.7',ACCOUNT+'\n'+JOINT,"(let* ((a (make-account 100 'old)) (j (make-joint a 'old 'new)) (x ((j 'new 'withdraw) 40)) (y ((a 'old 'deposit) 10)) (z ((j 'new 'withdraw) 5))) (list x y z))",'(60 70 65)')
 add('3.7',ACCOUNT+'\n'+JOINT,"(let* ((a (make-account 10 'old)) (j (make-joint a 'old 'new)) (x ((j 'bad 'withdraw) 4)) (y ((a 'old 'deposit) 0))) (list x y))",'("Incorrect password" 10)')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 required={'subsection1.xml':{'ex:make-accumulator','ex:make-monitored','ex:password-protection','ex:3_4'},'subsection2.xml':{'ex:random-with-reset'},'subsection3.xml':{'ex:3_7'}}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for name,labels in required.items():
   root=ET.fromstring(t.extractfile('xml/chapter3/section1/'+name).read())
   if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing: '+name)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch3.scm').read().decode('ascii')
 for phrase in (';; EXERCISE 3.1',';; EXERCISE 3.2',';; EXERCISE 3.3','(define (make-account balance)','(define random-init 7)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite session observations only. Candidates are independently written. Monitor uses a square procedure because sqrt is not yet available; rand uses an explicit deterministic fixture.'
 return result

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

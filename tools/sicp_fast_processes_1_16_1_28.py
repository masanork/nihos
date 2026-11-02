#!/usr/bin/env python3
"""Finite process tests for selected SICP 1.16-1.28 exercises."""
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

FAST_EXP='''(define (fast-exp b n) (define (iter b n a) (cond ((= n 0) a) ((even? n) (iter (* b b) (quotient n 2) a)) (else (iter b (- n 1) (* a b))))) (iter b n 1))'''
MUL_REC='''(define (double x) (+ x x)) (define (halve x) (quotient x 2))
(define (fast-mul a b) (cond ((= b 0) 0) ((even? b) (double (fast-mul a (halve b)))) (else (+ a (fast-mul a (- b 1))))))'''
MUL_ITER='''(define (double x) (+ x x)) (define (halve x) (quotient x 2))
(define (fast-mul a b) (define (iter a b total) (cond ((= b 0) total) ((even? b) (iter (double a) (halve b) total)) (else (iter a (- b 1) (+ total a))))) (iter a b 0))'''
FIB='''(define (fib n) (define (fib-iter a b p q count) (cond ((= count 0) b) ((even? count) (fib-iter a b (+ (* p p) (* q q)) (+ (* 2 p q) (* q q)) (quotient count 2))) (else (fib-iter (+ (* b q) (* a q) (* a p)) (+ (* b p) (* a q)) p q (- count 1))))) (fib-iter 1 0 0 1 n))'''
DIVISOR='''(define (smallest-divisor n) (define (find-divisor d) (cond ((> (* d d) n) n) ((= (remainder n d) 0) d) (else (find-divisor (+ d 1))))) (find-divisor 2))'''
ODD_DIVISOR='''(define (smallest-divisor n) (define (next d) (if (= d 2) 3 (+ d 2))) (define (find-divisor d) (cond ((> (* d d) n) n) ((= (remainder n d) 0) d) (else (find-divisor (next d))))) (find-divisor 2))'''
FERMAT='''(define (expmod base exp m) (cond ((= exp 0) 1) ((even? exp) (let ((x (expmod base (quotient exp 2) m))) (remainder (* x x) m))) (else (remainder (* base (expmod base (- exp 1) m)) m))))
(define (fermat? a n) (= (expmod a n n) a))'''
FERMAT_ITER='''(define (expmod base exp m) (define (iter b e a) (cond ((= e 0) a) ((even? e) (iter (remainder (* b b) m) (quotient e 2) a)) (else (iter b (- e 1) (remainder (* a b) m))))) (iter base exp 1))
(define (fermat? a n) (= (expmod a n n) a))'''
MILLER='''(define (expmod base exp m) (cond ((= exp 0) 1) ((even? exp) (let* ((x (expmod base (quotient exp 2) m)) (s (remainder (* x x) m))) (if (and (= s 1) (not (= x 1)) (not (= x (- m 1)))) 0 s))) (else (remainder (* base (expmod base (- exp 1) m)) m))))
(define (passes? a n) (= (expmod a (- n 1) n) 1))'''

def fib(n):
 a,b=0,1
 for _ in range(n):a,b=b,a+b
 return a

def smallest(n):
 for d in range(2,n):
  if n%d==0:return d
 return n

def strong_witness_passes(a,n):
 d=n-1;s=0
 while d%2==0:d//=2;s+=1
 x=pow(a,d,n)
 if x in (1,n-1):return True
 for _ in range(s-1):
  x=x*x%n
  if x==n-1:return True
 return False

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 for b,n in ((2,0),(2,10),(-2,5),(3,7),(1,20)):add('1.16',FAST_EXP,f'(fast-exp {b} {n})',b**n)
 for exercise,setup in (('1.17',MUL_REC),('1.18',MUL_ITER)):
  for a,b in ((0,0),(7,1),(7,13),(-4,17),(25,32)):add(exercise,setup,f'(fast-mul {a} {b})',a*b)
 for n in (0,1,2,10,20,30,40):add('1.19',FIB,f'(fib {n})',fib(n))
 for exercise,setup in (('1.21',DIVISOR),('1.23',ODD_DIVISOR)):
  for n in (199,1999,19999,121,561):add(exercise,setup,f'(smallest-divisor {n})',smallest(n))
 for n in (561,1105,1729,2465,2821,6601):
  for a in (2,3,10):
   for variant,setup in (('recursive',FERMAT),('iterative',FERMAT_ITER)):
    add('1.27',setup,f'(fermat? {a} {n})','#t' if pow(a,n,n)==a%n else '#f')
    rows[-1]['variant']=variant
 for n,a in ((7,2),(13,2),(9,2),(15,2),(21,2),(561,2),(561,50)):
  add('1.28',MILLER,f'(passes? {a} {n})','#t' if strong_witness_passes(a,n) else '#f')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 required={'subsection4.xml':{'ex:iter-expon-pro','ex:add-expon','ex:it-pro-mult-int','ex:1_19'},'subsection6.xml':{'ex:use-smallest-divisor','ex:better-smallest-divisor','ex:1_27','ex:miller-rabin'}}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for name,labels in required.items():
   root=ET.fromstring(t.extractfile('xml/chapter1/section2/'+name).read())
   if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing: '+name)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch1.scm').read().decode('ascii')
 for phrase in (';;;SECTION 1.2.4',';;EXERCISE 1.17',';;EXERCISE 1.19',';;;SECTION 1.2.6','(define (expmod base exp m)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite input observations only; all candidate procedures are independently written. Fermat and Miller-Rabin cases test selected bases, not all bases or proof obligations.'
 return result

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

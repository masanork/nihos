#!/usr/bin/env python3
"""Finite SICP 1.29-1.46 higher-order numerical candidates."""
import argparse
from fractions import Fraction
import hashlib
import io
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET
import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inv
import sicp_official_code as official

SUM='''(define (inc x) (+ x 1)) (define (cube x) (* x x x))
(define (sum term a next b) (if (> a b) 0 (+ (term a) (sum term (next a) next b))))'''
SIMPSON='''(define (simpson f a b n) (let ((h (/ (- b a) n))) (define (term k) (* (cond ((or (= k 0) (= k n)) 1) ((even? k) 2) (else 4)) (f (+ a (* k h))))) (* (/ h 3) (sum term 0 inc n))))'''
SUM_ITER='''(define (sum term a next b) (define (iter x result) (if (> x b) result (iter (next x) (+ result (term x))))) (iter a 0))'''
PRODUCT='''(define (product term a next b) (define (iter x result) (if (> x b) result (iter (next x) (* result (term x))))) (iter a 1))'''
ACCUM='''(define (accumulate combine null-value term a next b) (if (> a b) null-value (combine (term a) (accumulate combine null-value term (next a) next b))))'''
FILTERED='''(define (filtered-accumulate pred combine null-value term a next b) (if (> a b) null-value (combine (if (pred a) (term a) null-value) (filtered-accumulate pred combine null-value term (next a) next b))))'''
CF='''(define (cont-frac n d k) (define (iter i) (if (> i k) 0 (/ (n i) (+ (d i) (iter (+ i 1)))))) (iter 1))
(define (cont-frac-iter n d k) (define (iter i acc) (if (= i 0) acc (iter (- i 1) (/ (n i) (+ (d i) acc))))) (iter k 0))'''
TAN='''(define (tan-cf x k) (define (iter i) (if (> i k) 0 (/ (if (= i 1) x (- (* x x))) (+ (- (* 2 i) 1) (iter (+ i 1)))))) (iter 1))'''
HIGH='''(define (double f) (lambda (x) (f (f x))))
(define (compose f g) (lambda (x) (f (g x))))
(define (repeated f n) (if (= n 0) (lambda (x) x) (compose f (repeated f (- n 1)))))'''
SMOOTH='''(define dx 1) (define (smooth f) (lambda (x) (/ (+ (f (- x dx)) (f x) (f (+ x dx))) 3)))'''
IMPROVE='''(define (iterative-improve good? improve) (lambda (guess) (if (good? guess) guess ((iterative-improve good? improve) (improve guess)))))'''
FIXED='''(define (fixed-point f guess) (let ((next (f guess))) (if (< (abs (- next guess)) 0.00001) next (fixed-point f next))))'''
NROOT='''(define (average-damp f) (lambda (x) (/ (+ x (f x)) 2)))
(define (nth-root x n count) (fixed-point ((repeated average-damp count) (lambda (y) (/ x (expt y (- n 1))))) 1.0))'''

def rat(x):
 x=Fraction(x);return str(x.numerator) if x.denominator==1 else f'{x.numerator}/{x.denominator}'
def cf(numerators,denominators):
 value=Fraction(0)
 for n,d in reversed(list(zip(numerators,denominators))):value=Fraction(n)/(d+value)
 return value

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected)))
 for n in (2,4,6,10):add('1.29',SUM+'\n'+SIMPSON,f'(simpson cube 0 1 {n})','1/4')
 for expr,expect in (("(sum (lambda (x) (* x x)) 1 inc 5)",'55'),("(sum (lambda (x) x) 1 inc 50)",'1275')):add('1.30',SUM+'\n'+SUM_ITER,expr,expect)
 for n,expect in ((0,1),(5,120),(8,40320)):add('1.31',SUM+'\n'+PRODUCT,f'(product (lambda (x) x) 1 inc {n})',expect)
 add('1.32',SUM+'\n'+ACCUM,'(accumulate + 0 (lambda (x) (* x x)) 1 inc 5)','55')
 add('1.32',SUM+'\n'+ACCUM,'(accumulate * 1 (lambda (x) x) 1 inc 5)','120')
 add('1.33',SUM+'\n'+FILTERED,'(filtered-accumulate odd? + 0 (lambda (x) (* x x)) 1 inc 9)','165')
 add('1.33',SUM+'\n'+FILTERED,'(filtered-accumulate (lambda (x) (= (gcd x 10) 1)) * 1 (lambda (x) x) 1 inc 10)','189')
 add('1.35',FIXED,'(let ((v (fixed-point (lambda (x) (+ 1 (/ 1 x))) 1.0))) (and (> v 1.618) (< v 1.619)))','#t')
 for n in (1,3,5,8):
  for proc in ('cont-frac','cont-frac-iter'):add('1.37',CF,f'({proc} (lambda (i) 1) (lambda (i) 1) {n})',rat(cf([1]*n,[1]*n)))
 for n in (3,5,8):
  ds=[2*((i+1)//3) if i%3==2 else 1 for i in range(1,n+1)]
  add('1.38',CF,f'(+ 2 (cont-frac (lambda (i) 1) (lambda (i) (if (= (remainder i 3) 2) (* 2 (quotient (+ i 1) 3)) 1)) {n}))',rat(2+cf([1]*n,ds)))
 for n in (1,2,3):add('1.39',TAN,f'(tan-cf 1 {n})',rat(cf([1]+[-1]*(n-1),[2*i-1 for i in range(1,n+1)])))
 add('1.40','(define (cubic a b c) (lambda (x) (+ (* x x x) (* a x x) (* b x) c)))','((cubic 1 2 3) 2)','19')
 add('1.41',HIGH,'(((double (double double)) (lambda (x) (+ x 1))) 5)','21')
 add('1.42',HIGH,'((compose (lambda (x) (* x x)) (lambda (x) (+ x 1))) 5)','36')
 add('1.43',HIGH,'((repeated (lambda (x) (* x x)) 2) 5)','625')
 add('1.43',HIGH,'((repeated (lambda (x) (+ x 1)) 5) 0)','5')
 add('1.44',HIGH+'\n'+SMOOTH,'((smooth (lambda (x) (* x x))) 3)','29/3')
 add('1.44',HIGH+'\n'+SMOOTH,'(((repeated smooth 2) (lambda (x) (* x x))) 3)','31/3')
 add('1.45',HIGH+'\n'+FIXED+'\n'+NROOT,'(let ((r (nth-root 16 4 2))) (< (abs (- r 2.0)) 0.001))','#t')
 add('1.45',HIGH+'\n'+FIXED+'\n'+NROOT,'(let ((r (nth-root 27 3 1))) (< (abs (- r 3.0)) 0.001))','#t')
 add('1.46',IMPROVE,'((iterative-improve (lambda (x) (= x 5)) (lambda (x) (+ x 1))) 0)','5')
 add('1.46',IMPROVE,'(let ((r ((iterative-improve (lambda (g) (< (abs (- (* g g) 4.0)) 0.001)) (lambda (g) (/ (+ g (/ 4.0 g)) 2.0))) 1.0))) (< (abs (- (* r r) 4.0)) 0.001))','#t')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 required={'subsection1.xml':{'ex:1_29','ex:1_30','ex:product','ex:accumulate','ex:filtered-accumulate'},'subsection3.xml':{'ex:1_35','ex:continued-fractions','ex:1_38','ex:1_39'},'subsection4.xml':{'ex:1_40','ex:1_41','ex:compose','ex:repeated','ex:1_44','ex:nth-roots','ex:1_46'}}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for name,labels in required.items():
   root=ET.fromstring(t.extractfile('xml/chapter1/section3/'+name).read())
   if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing: '+name)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch1.scm').read().decode('ascii')
 for phrase in (';;;SECTION 1.3.1','(define (sum term a next b)','(define (fixed-point f first-guess)',';;EXERCISE 1.41'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite independently written candidates; exact Fraction oracles for rational results and tolerance checks for inexact roots. No timing, full proofs, or all-input claims.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

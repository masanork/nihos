#!/usr/bin/env python3
"""Executable slices of the remaining chapter-1 exercises, with caveats."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET
import sicp_abstraction_2_2_2_14 as runner
import sicp_fast_processes_1_16_1_28 as fast
import sicp_exercise_inventory as inv
import sicp_official_code as official

FIB='''(define (fib n) (define (iter a b n) (if (= n 0) b (iter (+ a b) a (- n 1)))) (iter 1 0 n))'''
TREE='''(define calls 0) (define max-depth 0)
(define (first-denomination k) (cond ((= k 1) 1) ((= k 2) 5) ((= k 3) 10) ((= k 4) 25) (else 50)))
(define (cc amount k depth) (set! calls (+ calls 1)) (if (> depth max-depth) (set! max-depth depth) 0) (cond ((= amount 0) 1) ((or (< amount 0) (= k 0)) 0) (else (+ (cc amount (- k 1) (+ depth 1)) (cc (- amount (first-denomination k)) k (+ depth 1))))))'''
SINE='''(define count 0) (define (p x) (set! count (+ count 1)) (- (* 3 x) (* 4 x x x)))
(define (sine angle) (if (not (> (abs angle) 0.1)) angle (p (sine (/ angle 3.0)))))'''
GCD='''(define calls 0) (define (remc a b) (set! calls (+ calls 1)) (remainder a b))
(define (app-gcd a b) (if (= b 0) a (app-gcd b (remc a b))))
(define (normal-gcd a b) (if (= (b) 0) (a) (normal-gcd b (lambda () (remc (a) (b))))))'''
PRIME_COUNT='''(define divisions 0)
(define (smallest-divisor n) (define (find d) (set! divisions (+ divisions 1)) (cond ((> (* d d) n) n) ((= (remainder n d) 0) d) (else (find (+ d 1))))) (find 2))
(define (prime? n) (= n (smallest-divisor n)))'''
FAST_PRIME=fast.FERMAT_ITER+'''\n(define (fast-prime? n bases) (if (null? bases) #t (and (fermat? (car bases) n) (fast-prime? n (cdr bases)))))'''
BAD_EXP='''(define calls 0) (define (bad-expmod b n m) (set! calls (+ calls 1)) (cond ((= n 0) 1) ((even? n) (remainder (* (bad-expmod b (quotient n 2) m) (bad-expmod b (quotient n 2) m)) m)) (else (remainder (* b (bad-expmod b (- n 1) m)) m))))'''
LOG_FIXTURE='''(define (ln x) (define (series z) (define (iter power total k) (if (= k 15) (* 2.0 total) (iter (* power z z) (+ total (/ power (+ (* 2 k) 1))) (+ k 1)))) (iter z 0.0 0))
 (define (reduce y count) (if (> y 2.0) (reduce (/ y 2.0) (+ count 1)) (+ (* count 0.6931471805599453) (series (/ (- y 1.0) (+ y 1.0)))))) (reduce x 0))
(define visits 0)
(define (fixed-point f first) (define (iter guess) (set! visits (+ visits 1)) (let ((next (f guess))) (if (< (abs (- guess next)) 0.00001) next (iter next)))) (iter first))
(define (f x) (/ (ln 1000.0) (ln x)))
(define (average-damp f) (lambda (x) (/ (+ x (f x)) 2.0)))'''

def tree_stats(amount,k=5):
 den=(0,1,5,10,25,50);calls=0;maximum=0
 def cc(a,k,d):
  nonlocal calls,maximum
  calls+=1;maximum=max(maximum,d)
  if a==0:return 1
  if a<0 or k==0:return 0
  return cc(a,k-1,d+1)+cc(a-den[k],k,d+1)
 value=cc(amount,k,0);return value,calls,maximum

def trial_steps(n):
 d=2;count=0
 while True:
  count+=1
  if d*d>n or n%d==0:return count
  d+=1

def bad_stats(base,n,m):
 count=0
 def go(n):
  nonlocal count
  count+=1
  if n==0:return 1
  if n%2==0:return go(n//2)*go(n//2)%m
  return base*go(n-1)%m
 return go(n),count

def cases():
 rows=[]
 def add(ex,setup,expr,expected,**kw):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=str(expected),**kw))
 for n in (0,5,10):
  a,b=0,1
  for _ in range(n):a,b=b,a+b
  add('1.13',FIB,f'(and (= (fib {n}) {a}) (= (round (/ (- (expt 1.618033988749895 {n}) (expt -0.618033988749895 {n})) 2.23606797749979)) {a}))','#t')
 for n in (0,5,11):
  value,calls,depth=tree_stats(n);add('1.14',TREE,f'(let* ((v (cc {n} 5 0)) (c calls) (d max-depth)) (list v c d))',f'({value} {calls} {depth})')
 add('1.15',SINE,'(begin (sine 12.15) count)','5')
 add('1.15',SINE,'(let ((v (sine 12.15))) (< (abs (+ v 0.4)) 0.06))','#t')
 add('1.20',GCD,'(let* ((v (app-gcd 206 40)) (c calls)) (list v c))','(2 4)')
 add('1.20',GCD,'(let* ((v (normal-gcd (lambda () 206) (lambda () 40))) (c calls)) (list v c))','(2 18)')
 for n in (1009,1013,1019):add('1.22',PRIME_COUNT,f'(let* ((v (prime? {n})) (c divisions)) (list v c))',f'(#t {trial_steps(n)})')
 for n in (1009,1001,561):
  bases=(2,3,5);result=all(pow(a,n,n)==a%n for a in bases)
  add('1.24',FAST_PRIME,f"(fast-prime? {n} '(2 3 5))",'#t' if result else '#f')
 add('1.25',fast.FERMAT_ITER,'(expmod 2 40 101)',pow(2,40,101))
 add('1.25','', '(remainder (expt 2 40) 101)',pow(2,40,101))
 for n in (8,16):
  val,count=bad_stats(2,n,17);add('1.26',BAD_EXP,f'(let* ((v (bad-expmod 2 {n} 17)) (c calls)) (list v c))',f'({val} {count})')
 add('1.34','(define (f g) (g 2))','(f (lambda (x) (* x x)))','4')
 add('1.34','(define (f g) (g 2))','(f f)','error:Type',expected_error='Type',reference_error_contains='non procedure application')
 add('1.36',LOG_FIXTURE,'(let ((v (fixed-point (average-damp f) 2.0))) (< (abs (- v 4.5555)) 0.001))','#t')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 required={'section2/subsection2.xml':{'ex:fib-proof'},'section2/subsection3.xml':{'ex:1_14','ex:1_15'},'section2/subsection5.xml':{'ex:gcd-process'},'section2/subsection6.xml':{'ex:search-for-primes','ex:mod-timed-prime-test','ex:Alyssas-expmod','ex:louis-fast-prime'},'section3/subsection2.xml':{'ex:1_34'},'section3/subsection3.xml':{'ex:log-fixed-point'}}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for name,labels in required.items():
   root=ET.fromstring(t.extractfile('xml/chapter1/'+name).read())
   if not labels<={n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise labels missing: '+name)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch1.scm').read().decode('ascii')
 for phrase in ('(define (count-change amount)','(define (sine angle)','(define (gcd a b)','(define (expmod base exp m)','(define (fixed-point f first-guess)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Finite candidate observations only. 1.13 uses decimal constants; 1.20 explicitly simulates substitution with thunks; 1.22/1.24 use deterministic work/base fixtures instead of wall-clock timing/randomness; 1.36 uses a candidate logarithm and omits printed iteration traces. 1.34 expects a type error.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

#!/usr/bin/env python3
"""Bounded, independently checked candidates for SICP 2.2-2.14.

The source code contains teaching examples, not exercise solutions. All
candidate solutions below are ours; conceptual claims and I/O are not graded.
"""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import sicp_exercise_inventory as inv
import sicp_official_code as official

ROOT=Path(__file__).resolve().parents[1]
REVISION='a27d06c749cdea7ca051e69e7629e3af78c01ac4'
POINTS='''(define (make-point x y) (cons x y))
(define (x-point p) (car p)) (define (y-point p) (cdr p))
(define (make-segment a b) (cons a b))
(define (start-segment s) (car s)) (define (end-segment s) (cdr s))
(define (midpoint-segment s) (let ((a (start-segment s)) (b (end-segment s))) (make-point (/ (+ (x-point a) (x-point b)) 2) (/ (+ (y-point a) (y-point b)) 2))))'''
RECT1='''(define (make-rect a b) (cons a b))
(define (rect-width r) (abs (- (x-point (car r)) (x-point (cdr r)))))
(define (rect-height r) (abs (- (y-point (car r)) (y-point (cdr r)))))'''
RECT2='''(define (make-rect a b) (cons (abs (- (x-point a) (x-point b))) (abs (- (y-point a) (y-point b)))))
(define (rect-width r) (car r)) (define (rect-height r) (cdr r))'''
RECT_COMMON='''(define (area r) (* (rect-width r) (rect-height r)))
(define (perimeter r) (* 2 (+ (rect-width r) (rect-height r))))'''
PAIR4='''(define (cons x y) (lambda (m) (m x y)))
(define (car z) (z (lambda (p q) p)))
(define (cdr z) (z (lambda (p q) q)))'''
PAIR5='''(define (cons a b) (* (expt 2 a) (expt 3 b)))
(define (power-count z p) (if (= (remainder z p) 0) (+ 1 (power-count (quotient z p) p)) 0))
(define (car z) (power-count z 2)) (define (cdr z) (power-count z 3))'''
CHURCH='''(define zero (lambda (f) (lambda (x) x)))
(define (add-1 n) (lambda (f) (lambda (x) (f ((n f) x)))))
(define one (lambda (f) (lambda (x) (f x))))
(define two (lambda (f) (lambda (x) (f (f x)))))
(define (plus a b) (lambda (f) (lambda (x) ((a f) ((b f) x)))))
(define (value n) ((n (lambda (x) (+ x 1))) 0))'''
INTERVAL='''(define (make-interval a b) (cons a b))
(define (lower-bound i) (car i)) (define (upper-bound i) (cdr i))
(define (add-interval x y) (make-interval (+ (lower-bound x) (lower-bound y)) (+ (upper-bound x) (upper-bound y))))
(define (sub-interval x y) (make-interval (- (lower-bound x) (upper-bound y)) (- (upper-bound x) (lower-bound y))))
(define (mul-interval x y) (let ((p1 (* (lower-bound x) (lower-bound y))) (p2 (* (lower-bound x) (upper-bound y))) (p3 (* (upper-bound x) (lower-bound y))) (p4 (* (upper-bound x) (upper-bound y)))) (make-interval (min p1 p2 p3 p4) (max p1 p2 p3 p4))))
(define (width i) (/ (- (upper-bound i) (lower-bound i)) 2))'''
MULFAST='''(define (mul-fast x y) (let ((a (lower-bound x)) (b (upper-bound x)) (c (lower-bound y)) (d (upper-bound y)))
(cond ((>= a 0) (cond ((>= c 0) (make-interval (* a c) (* b d))) ((<= d 0) (make-interval (* b c) (* a d))) (else (make-interval (* b c) (* b d)))))
((<= b 0) (cond ((>= c 0) (make-interval (* a d) (* b c))) ((<= d 0) (make-interval (* b d) (* a c))) (else (make-interval (* a d) (* a c)))))
(else (cond ((>= c 0) (make-interval (* a d) (* b d))) ((<= d 0) (make-interval (* b c) (* a c))) (else (make-interval (min (* a d) (* b c)) (max (* a c) (* b d)))))))))'''
PERCENT='''(define (make-center-percent c p) (let ((w (/ (* (abs c) p) 100))) (make-interval (- c w) (+ c w))))
(define (center i) (/ (+ (lower-bound i) (upper-bound i)) 2))
(define (percent i) (/ (* 100 (width i)) (abs (center i))))'''
PARALLEL='''(define (div-interval x y) (mul-interval x (make-interval (/ 1 (upper-bound y)) (/ 1 (lower-bound y)))))
(define (par1 r1 r2) (div-interval (mul-interval r1 r2) (add-interval r1 r2)))
(define (par2 r1 r2) (let ((one (make-interval 1 1))) (div-interval one (add-interval (div-interval one r1) (div-interval one r2)))))'''

def rat(x):
 x=Fraction(x);return str(x.numerator) if x.denominator==1 else f'{x.numerator}/{x.denominator}'
def pair(a,b): return f'({rat(a)} . {rat(b)})'
def interval(a,b): return f'(make-interval {a} {b})'
def cases():
 out=[]
 def add(ex,setup,expr,expected):out.append(dict(exercise=ex,setup=setup,expression=expr,expected=expected))
 for a,b,c,d in ((0,0,4,6),(-3,2,5,-4),(1,2,2,5)):
  add('2.2',POINTS,f'(midpoint-segment (make-segment (make-point {a} {b}) (make-point {c} {d})))',pair(Fraction(a+c,2),Fraction(b+d,2)))
 for ctor in (RECT1,RECT2):
  for x,y in ((4,3),(7,5)):
   add('2.3',POINTS+'\n'+ctor+'\n'+RECT_COMMON,f'(let ((r (make-rect (make-point 0 0) (make-point {x} {y})))) (list (area r) (perimeter r)))',f'({x*y} {2*(x+y)})')
 for a,b in ((2,7),(0,-5),(8,8)):
  add('2.4',PAIR4,f'(list (car (cons {a} {b})) (cdr (cons {a} {b})))',f'({a} {b})')
 for a,b in ((0,0),(2,3),(4,1),(1,5)):
  add('2.5',PAIR5,f'(list (car (cons {a} {b})) (cdr (cons {a} {b})))',f'({a} {b})')
 for expr,answer in (('(value zero)','0'),('(value one)','1'),('(value two)','2'),('(value (add-1 two))','3'),('(value (plus two two))','4')):add('2.6',CHURCH,expr,answer)
 for a,b in ((-2,5),(0,0),(4,9)):
  add('2.7',INTERVAL,f'(let ((i {interval(a,b)})) (list (lower-bound i) (upper-bound i)))',f'({a} {b})')
 for a,b,c,d in ((1,3,2,5),(-4,-1,-3,2),(0,0,1,7)):
  add('2.8',INTERVAL,f'(sub-interval {interval(a,b)} {interval(c,d)})',pair(a-d,b-c))
 for a,b,c,d in ((1,3,2,6),(-4,-1,-3,2),(0,0,1,7)):
  w=Fraction(b-a+d-c,2)
  add('2.9',INTERVAL,f'(list (width (add-interval {interval(a,b)} {interval(c,d)})) (+ (width {interval(a,b)}) (width {interval(c,d)})))',f'({rat(w)} {rat(w)})')
 for a,b in ((1,3),(-5,-2),(-4,6)):
  for c,d in ((2,7),(-6,-1),(-3,8)):
   vals=[a*c,a*d,b*c,b*d]
   add('2.11',INTERVAL+'\n'+MULFAST,f'(mul-fast {interval(a,b)} {interval(c,d)})',pair(min(vals),max(vals)))
 for center,p in ((50,10),(100,5),(-20,25)):
  w=Fraction(abs(center)*p,100)
  add('2.12',INTERVAL+'\n'+PERCENT,f'(make-center-percent {center} {p})',pair(Fraction(center)-w,Fraction(center)+w))
  add('2.12',INTERVAL+'\n'+PERCENT,f'(percent (make-center-percent {center} {p}))',rat(p))
 for name,expected in (('par1',pair(Fraction(1,2),2)),('par2',pair(Fraction(3,4),Fraction(4,3)))):
  add('2.14',INTERVAL+'\n'+PARALLEL,f'({name} {interval(1,2)} {interval(3,4)})',expected)
 return out

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 required={'subsection2.xml':{'ex:segments1','ex:rectangles'},'subsection3.xml':{'ex:lambda-cons','ex:2_5','ex:church-numerals'},'subsection4.xml':{'ex:2_7','ex:2_8','ex:2_9','ex:alyssa-interval-end','ex:make-center-percent','ex:interval-compare'}}
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for file,labels in required.items():
   root=ET.fromstring(t.extractfile('xml/chapter2/section1/'+file).read());actual={n.get('NAME') for n in root.iter('LABEL')}
   if not labels<=actual:raise ValueError('exercise labels missing: '+file)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t: code=t.extractfile('ch2.scm').read().decode('ascii')
 for phrase in (';; EXERCISE 2.2',';; EXERCISE 2.4',';; EXERCISE 2.6',';; EXERCISE 2.7','(define (mul-interval x y)','(define (par1 r1 r2)','(define (par2 r1 r2)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi, case_builder=cases, source_verifier=verify_sources):
 source_verifier();chibi=chibi.resolve();home=chibi.parent
 revision=subprocess.check_output(['git','-C',str(home),'rev-parse','HEAD'],text=True).strip()
 if revision!=REVISION:raise ValueError('unexpected reference revision')
 env=dict(os.environ,CHIBI_MODULE_PATH=str(home/'lib'),DYLD_LIBRARY_PATH=str(home),LD_LIBRARY_PATH=str(home))
 program=['const std = @import("std"); const scheme = @import("scheme");','const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };'];rows=case_builder()
 for i,row in enumerate(rows):
  source='(begin '+row['setup']+' '+row['expression']+')'
  ref=subprocess.run([str(chibi),'-q','-p',source],cwd=home,env=env,text=True,capture_output=True)
  if row.get('expected_error'):
   if ref.returncode==0:raise ValueError('reference unexpectedly accepted '+row['expression'])
   if row.get('reference_error_contains') and row['reference_error_contains'] not in ref.stderr:raise ValueError('unexpected reference error '+row['expression']+': '+ref.stderr)
  elif ref.returncode or ref.stderr or ref.stdout!=row['expected']+'\n':raise ValueError('reference disagreement '+row['exercise']+' '+row['expression']+': '+ref.stdout+ref.stderr)
  preparation = ''
  if row.get('sequential_setup'):
   preparation = '_ = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("SICP_CASE\\t%d\\tsetup-error\\t{s}\\n", .{@errorName(err)}); return; }; ' % (json.dumps(row['setup']), i)
  expression = row['expression'] if row.get('sequential_setup') else source
  program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [1024]u8 = undefined; %sconst got = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("SICP_CASE\\t%d\\terror\\t{s}\\n", .{@errorName(err)}); return; }; std.debug.print("SICP_CASE\\t%d\\tvalue\\t{s}\\n", .{got}); }' % (i,preparation,json.dumps(expression),i,i))
 with tempfile.TemporaryDirectory(prefix='sicp-abstraction-') as folder:
  src=Path(folder)/'cases.zig';src.write_text('\n'.join(program)+'\n')
  result=subprocess.run([str(zig.resolve()),'test','-O','ReleaseSafe','--dep','scheme','-Mroot='+str(src),'--dep','view_config','-Mscheme='+str(ROOT/'src/xy/scheme_runtime.zig'),'-Mview_config='+str(ROOT/'src/xy/view_config.zig')],text=True,capture_output=True,check=True)
 found=set()
 for line in (result.stdout+result.stderr).splitlines():
  if 'SICP_CASE\t' not in line:continue
  _,idx,kind,value=line[line.index('SICP_CASE\t'):].split('\t',3);idx=int(idx)
  if idx in found or idx>=len(rows):raise ValueError('invalid duplicate case')
  found.add(idx);row=rows[idx];row['observed']=value
  if row.get('sequential_setup'):
   row['stage']='setup' if kind=='setup-error' else 'expression'
   if kind=='setup-error':kind='error'
  matches = (kind=='error' and value==row['expected_error']) if row.get('expected_error') else (kind=='value' and value==row['expected'])
  row['status']='matched' if matches else ('error' if kind=='error' else 'mismatch')
 if found!=set(range(len(rows))):raise ValueError('missing case observations')
 return {'xml_sha256':inv.SHA256,'official_code_sha256':official.SHA256,'reference_revision':revision,'cases':rows,'totals':dict(Counter(r['status'] for r in rows)),'note':'2.14 uses exact reciprocal 1 instead of original inexact 1.0; zero-spanning intervals not admitted'}

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

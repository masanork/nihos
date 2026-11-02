#!/usr/bin/env python3
"""Bounded factorial controller and tiny fixture for SICP 5.1 and 5.2."""
import argparse
import hashlib
import io
import json
from math import factorial
from pathlib import Path
import tarfile
import xml.etree.ElementTree as ET
import sicp_abstraction_2_2_2_14 as runner
import sicp_exercise_inventory as inv
import sicp_official_code as official

CONTROLLER="""'((assign product (const 1)) (assign counter (const 1)) test-counter
(test (op >) (reg counter) (reg n)) (branch (label fact-done))
(assign product (op *) (reg counter) (reg product))
(assign counter (op +) (reg counter) (const 1))
(goto (label test-counter)) fact-done)"""
SIMULATOR='''(define controller CONTROLLER_FORM)
(define (nth xs n) (if (= n 0) (car xs) (nth (cdr xs) (- n 1))))
(define (find-label name xs) (if (null? xs) '() (if (eq? (car xs) name) (cdr xs) (find-label name (cdr xs)))))
(define (run n)
 (define (loop pc product counter flag)
  (define (operand spec) (if (eq? (car spec) 'const) (cadr spec) (cond ((eq? (cadr spec) 'n) n) ((eq? (cadr spec) 'product) product) (else counter))))
  (if (null? pc) product
   (let ((inst (car pc)))
    (if (not (pair? inst)) (loop (cdr pc) product counter flag)
     (cond
      ((eq? (car inst) 'assign)
       (let* ((target (cadr inst)) (spec (nth inst 2))
              (v (if (eq? (car spec) 'const) (cadr spec) (if (eq? (cadr spec) '*) (* (operand (nth inst 3)) (operand (nth inst 4))) (+ (operand (nth inst 3)) (operand (nth inst 4)))))))
        (if (eq? target 'product) (loop (cdr pc) v counter flag) (loop (cdr pc) product v flag))))
      ((eq? (car inst) 'test) (loop (cdr pc) product counter (> (operand (nth inst 2)) (operand (nth inst 3)))))
      ((eq? (car inst) 'branch) (loop (if flag (find-label (cadr (cadr inst)) controller) (cdr pc)) product counter flag))
      ((eq? (car inst) 'goto) (loop (find-label (cadr (cadr inst)) controller) product counter flag))
      (else 'unknown-instruction))))))
 (loop controller 0 0 #f))'''.replace('CONTROLLER_FORM',CONTROLLER)

def cases():
 return [dict(exercise=ex,setup=SIMULATOR,expression=f'(run {n})',expected=str(factorial(n))) for ex in ('5.1','5.2') for n in (0,1,3,5,6)]

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  for name,label in (('section1.xml','ex:iterative-fact'),('subsection1.xml','ex:iterative-fact-2')):
   root=ET.fromstring(t.extractfile('xml/chapter5/section1/'+name).read())
   if label not in {n.get('NAME') for n in root.iter('LABEL')}:raise ValueError('exercise label missing: '+name)
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  code=t.extractfile('ch5.scm').read().decode('ascii');sim=t.extractfile('ch5-regsim.scm').read().decode('ascii')
 if not all(x in code for x in (';;EXERCISE 5.1','(define (factorial n)','(controller')) or '(define (make-machine' not in sim:raise ValueError('original prerequisite missing')

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Independently written factorial controller and tiny fixture support only the operations used here. Not MIT register-machine simulator, graphical design, complete instruction semantics, or full exercise grading.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

#!/usr/bin/env python3
"""Isolated candidates for selected SICP metacircular evaluator exercises."""
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

EVAL_ORDER='''(define order '())
(define (eval exp env) (set! order (append order (list exp))) exp)
(define (no-operands? xs) (null? xs)) (define (first-operand xs) (car xs)) (define (rest-operands xs) (cdr xs))'''
LEFT='''(define (list-of-values xs env) (if (no-operands? xs) '() (let* ((a (eval (first-operand xs) env)) (b (list-of-values (rest-operands xs) env))) (cons a b))))'''
RIGHT='''(define (list-of-values xs env) (if (no-operands? xs) '() (let* ((b (list-of-values (rest-operands xs) env)) (a (eval (first-operand xs) env))) (cons a b))))'''
CALL='''(define (tagged? exp tag) (and (pair? exp) (eq? (car exp) tag)))
(define (old-application? exp) (pair? exp)) (define (definition? exp) (tagged? exp 'define))
(define (application? exp) (tagged? exp 'call)) (define (operator exp) (cadr exp)) (define (operands exp) (cdr (cdr exp)))'''
LOGIC='''(define hits 0)
(define (eval exp env) (if (pair? exp) (begin (set! hits (+ hits 1)) (cadr exp)) exp))
(define (eval-and xs env) (if (null? xs) #t (let ((value (eval (car xs) env))) (if (eq? value #f) #f (if (null? (cdr xs)) value (eval-and (cdr xs) env))))))
(define (eval-or xs env) (if (null? xs) #f (let ((value (eval (car xs) env))) (if (eq? value #f) (eval-or (cdr xs) env) value))))'''
LET_TRANSFORM='''(define (cddr x) (cdr (cdr x)))
(define (vars bindings) (if (null? bindings) '() (cons (car (car bindings)) (vars (cdr bindings)))))
(define (values-of bindings) (if (null? bindings) '() (cons (cadr (car bindings)) (values-of (cdr bindings)))))
(define (let->combination e) (let ((bindings (cadr e)) (body (cddr e))) (cons (cons 'lambda (cons (vars bindings) body)) (values-of bindings))))'''
LETSTAR_TRANSFORM='''(define (cddr x) (cdr (cdr x)))
(define (let*->nested-lets e) (define (wrap bindings body) (if (null? bindings) (cons 'let (cons '() body)) (list 'let (list (car bindings)) (wrap (cdr bindings) body)))) (wrap (cadr e) (cddr e)))'''

def cases():
 rows=[]
 def add(ex,setup,expr,expected):rows.append(dict(exercise=ex,setup=setup,expression=expr,expected=expected))
 for proc,order in ((LEFT,'(a b c)'),(RIGHT,'(c b a)')):
  add('4.1',EVAL_ORDER+'\n'+proc,"(let* ((values (list-of-values '(a b c) 'env)) (observed order)) (list values observed))",f'((a b c) {order})')
  add('4.1',EVAL_ORDER+'\n'+proc,"(list-of-values '() 'env)",'()')
 add('4.2',CALL,"(list (old-application? '(define x 3)) (definition? '(define x 3)) (application? '(define x 3)))",'(#t #t #f)')
 add('4.2',CALL,"(list (application? '(call + 1 2)) (operator '(call + 1 2)) (operands '(call + 1 2)))",'(#t + (1 2))')
 for expr,expected in (("(eval-and '() 'env)",'#t'),("(eval-or '() 'env)",'#f'),("(let* ((v (eval-and '((effect #f) (effect 2)) 'env)) (h hits)) (list v h))",'(#f 1)'),("(let* ((v (eval-or '((effect 7) (effect 2)) 'env)) (h hits)) (list v h))",'(7 1)'),("(eval-and '(1 2 3) 'env)",'3')):add('4.4',LOGIC,expr,expected)
 add('4.6',LET_TRANSFORM,"(let->combination '(let ((x 2) (y 3)) (+ x y)))",'((lambda (x y) (+ x y)) 2 3)')
 add('4.6',LET_TRANSFORM,"(let->combination '(let () 42))",'((lambda () 42))')
 add('4.7',LETSTAR_TRANSFORM,"(let*->nested-lets '(let* ((x 3) (y (+ x 2))) (+ x y)))",'(let ((x 3)) (let ((y (+ x 2))) (let () (+ x y))))')
 add('4.7',LETSTAR_TRANSFORM,"(let*->nested-lets '(let* () 42))",'(let () 42)')
 return rows

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256:raise ValueError('XML archive hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
  one=ET.fromstring(t.extractfile('xml/chapter4/section1/subsection1.xml').read())
  two=ET.fromstring(t.extractfile('xml/chapter4/section1/subsection2.xml').read())
  if 'ex:arg-eval-order_scheme' not in {n.get('NAME') for n in one.iter('LABEL')}:raise ValueError('exercise 4.1 label missing')
  if not {'ex:application-predicate','ex:eval-and-or','ex:implement-let'} <= {n.get('NAME') for n in two.iter('LABEL')}:raise ValueError('exercise labels missing')
  if 'nested' not in ' '.join(two.itertext()) or 'let*' not in ' '.join(two.itertext()):raise ValueError('let* exercise missing')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch4.scm').read().decode('ascii')
 for phrase in (';;;SECTION 4.1.1','(define (list-of-values exps env)',';;;SECTION 4.1.2','(define (application? exp)'):
  if phrase not in code:raise ValueError('original prerequisite missing: '+phrase)

def run(zig,chibi):
 result=runner.run(zig,chibi,case_builder=cases,source_verifier=verify_sources)
 result['note']='Isolated candidate helper procedures with stub evaluator, not the complete original metacircular evaluator. Transform results are syntax data, not execution of a full metacircular interpreter.'
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

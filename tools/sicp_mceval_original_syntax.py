#!/usr/bin/env python3
"""Load the unmodified MIT metacircular syntax section in a host xy session."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import sicp_official_code as official

ROOT=Path(__file__).resolve().parents[1]
REVISION='a27d06c749cdea7ca051e69e7629e3af78c01ac4'
CASES=[
 ('self-evaluating-integer','(self-evaluating? 12)','#t'),
 ('self-evaluating-string','(self-evaluating? "hi")','#t'),
 ('self-evaluating-symbol',"(self-evaluating? 'foo)",'#f'),
 ('variable',"(variable? 'foo)",'#t'),
 ('variable-pair',"(variable? '(foo))",'#f'),
 ('assignment-value',"(assignment-value '(set! x 4))",'4'),
 ('definition-variable',"(definition-variable '(define (f x) (+ x 1)))",'f'),
 ('definition-value',"(definition-value '(define (f x) (+ x 1)))",'(lambda (x) (+ x 1))'),
 ('if-alternative',"(if-alternative '(if x 1 2))",'2'),
 ('if-default',"(if-alternative '(if x 1))",'false'),
 ('application',"(application? '(define x 3))",'#t'),
 ('cond-transform',"(cond->if '(cond ((> x 2) x) (else 0)))",'(if (> x 2) x 0)'),
]

ENV_CASES=[
 ('frame-variables',"(frame-variables (make-frame '(x y) '(1 2)))",'(x y)'),
 ('frame-values',"(frame-values (make-frame '(x y) '(1 2)))",'(1 2)'),
 ('lookup',"(lookup-variable-value 'x (extend-environment '(x y) '(1 2) '()))",'1'),
 ('mutation',"(let ((e (extend-environment '(x) '(1) '()))) (set-variable-value! 'x 9 e) (lookup-variable-value 'x e))",'9'),
 ('definition',"(let ((e (extend-environment '(x) '(1) '()))) (define-variable! 'z 3 e) (lookup-variable-value 'z e))",'3'),
 ('shadowing',"(let* ((outer (extend-environment '(x) '(1) '())) (inner (extend-environment '(x) '(2) outer))) (lookup-variable-value 'x inner))",'2'),
 ('procedure-tag',"(compound-procedure? (make-procedure '(x) '((+ x 1)) '()))",'#t'),
 ('procedure-body',"(procedure-body (make-procedure '(x) '((+ x 1)) '()))",'((+ x 1))'),
]

FULL_CASES=[
 ('quoted',"(let ((e (setup-environment))) (eval '(quote hello) e))",'hello'),
 ('if',"(let ((e (setup-environment))) (eval '(if true (quote yes) (quote no)) e))",'yes'),
 ('lambda',"(let ((e (setup-environment))) (eval '((lambda (x) x) (quote cat)) e))",'cat'),
 ('pair',"(let ((e (setup-environment))) (eval '((lambda (x) (cons x (quote (b)))) (quote a)) e))",'(a b)'),
]

def split_forms(text):
    forms=[]; start=None; depth=0; string=False; escape=False; comment=False
    for i,ch in enumerate(text):
        if comment:
            if ch=='\n':comment=False
            continue
        if string:
            if escape:escape=False
            elif ch=='\\':escape=True
            elif ch=='"':string=False
            continue
        if ch==';':comment=True;continue
        if ch=='"':string=True;continue
        if ch=='(':
            if depth==0:start=i
            depth+=1
        elif ch==')':
            depth-=1
            if depth<0:raise ValueError('unbalanced source')
            if depth==0:
                forms.append(text[start:i+1]);start=None
    if depth or string:raise ValueError('unterminated source')
    return forms

def source_forms(section='4.1.2'):
    raw=official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=official.SHA256:raise ValueError('MIT archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:code=t.extractfile('ch4-mceval.scm').read().decode('ascii')
    ending={'4.1.2':'4.1.3','4.1.3':'4.1.4'}
    block=code if section=='full' else code.split(';;;SECTION '+section,1)[1].split(';;;SECTION '+ending[section],1)[0]
    forms=split_forms(block)
    if section=='4.1.3':
        syntax=source_forms('4.1.2')
        forms=[next(f for f in syntax if f.startswith('(define (tagged-list?'))]+forms
    if not forms or not all(x.startswith('(define ') for x in forms):raise ValueError('unexpected section layout')
    return forms

def run(zig,chibi,section="4.1.2"):
    chibi=chibi.resolve();home=chibi.parent
    revision=subprocess.check_output(['git','-C',str(home),'rev-parse','HEAD'],text=True).strip()
    if revision!=REVISION:raise ValueError('unexpected reference revision')
    env=dict(os.environ,CHIBI_MODULE_PATH=str(home/'lib'),DYLD_LIBRARY_PATH=str(home),LD_LIBRARY_PATH=str(home))
    forms=source_forms(section); compat=['(define true #t)','(define false #f)']
    cases_to_run=FULL_CASES if section=='full' else (ENV_CASES if section=='4.1.3' else CASES)
    setup='\n'.join(compat+forms)
    reference_checks=[]
    for name,expr,expected in cases_to_run:
        p=subprocess.run([str(chibi),'-q','-e','(import (scheme cxr))','-p','(begin '+setup+' '+expr+')'],cwd=home,env=env,text=True,capture_output=True)
        if p.returncode or p.stderr or p.stdout!=expected+'\n':
            if section!='full':raise ValueError('reference disagreement: '+name+' '+p.stdout+p.stderr)
            reference_checks.append({'name':name,'status':'reference_error' if p.returncode else 'reference_mismatch','detail':p.stderr[:512] or p.stdout})
        else: reference_checks.append({'name':name,'status':'matched'})
    program=['const std = @import("std"); const scheme = @import("scheme");', 'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };',
             'test "original syntax session" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [4096]u8 = undefined;']
    for i,form in enumerate(compat+forms):
        program.append('_ = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("MCE_SETUP\\t%d\\t{s}\\n", .{@errorName(err)}); const recovered = vm.evaluate("(+ 20 22)", &h, &out) catch |next| { std.debug.print("MCE_RECOVERY\\terror\\t{s}\\n", .{@errorName(next)}); return; }; std.debug.print("MCE_RECOVERY\\tvalue\\t{s}\\n", .{recovered}); return; };' % (json.dumps(form),i))
    program.append('std.debug.print("MCE_SETUP\\t%d\\tok\\n", .{});' % len(compat+forms))
    for i,(_,expr,_) in enumerate(cases_to_run):
        program.append('{ const got = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("MCE_CASE\\t%d\\terror\\t{s}\\n", .{@errorName(err)}); return; }; std.debug.print("MCE_CASE\\t%d\\tvalue\\t{s}\\n", .{got}); }' % (json.dumps(expr),i,i))
    program.append('}')
    with tempfile.TemporaryDirectory(prefix='sicp-mceval-original-') as folder:
        src=Path(folder)/'cases.zig';src.write_text('\n'.join(program)+'\n')
        p=subprocess.run([str(zig.resolve()),'test','-O','ReleaseSafe','--dep','scheme','-Mroot='+str(src),'--dep','view_config','-Mscheme='+str(ROOT/'src/xy/scheme_runtime.zig'),'-Mview_config='+str(ROOT/'src/xy/view_config.zig')],text=True,capture_output=True,check=True)
    log=p.stdout+p.stderr;setup_result=None;recovery=None;found={}
    for line in log.splitlines():
        if 'MCE_SETUP\t' in line:
            _,index,value=line[line.index('MCE_SETUP\t'):].split('\t',2);setup_result={'completed':int(index),'status':value}
        if 'MCE_CASE\t' in line:
            _,index,kind,value=line[line.index('MCE_CASE\t'):].split('\t',3);found[int(index)]=(kind,value)
        if 'MCE_RECOVERY\t' in line:
            _,kind,value=line[line.index('MCE_RECOVERY\t'):].split('\t',2);recovery={'kind':kind,'observed':value}
    if setup_result is None:raise ValueError('missing setup result')
    cases=[]
    for i,(name,expr,expected) in enumerate(cases_to_run):
        if i not in found:cases.append(dict(name=name,expression=expr,expected=expected,status='not_run'));continue
        kind,value=found[i];cases.append(dict(name=name,expression=expr,expected=expected,observed=value,status='matched' if kind=='value' and value==expected else ('error' if kind=='error' else 'mismatch')))
    return {'source_archive_sha256':official.SHA256,'reference_revision':revision,'reference_checks':reference_checks,'source_member':'ch4-mceval.scm','section':section,'compatibility_definitions':compat,'source_forms':forms,'setup':setup_result,'recovery':recovery,'cases':cases,'test_log':log}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);p.add_argument('--section',choices=('4.1.2','4.1.3','full'),default='4.1.2');a=p.parse_args()
    print(json.dumps(run(a.zig,a.chibi,a.section),indent=2))

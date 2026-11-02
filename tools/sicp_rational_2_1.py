#!/usr/bin/env python3
"""Exercise 2.1 candidate with independent fraction and reference checks."""
import argparse
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

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'a27d06c749cdea7ca051e69e7629e3af78c01ac4'
CANDIDATE = '(define (make-rat n d) (let* ((g (gcd n d)) (a (/ n g)) (b (/ d g)) (sign (if (< b 0) -1 1))) (cons (* sign a) (* sign b))))'
INPUTS = [(6, 8), (6, -8), (-6, 8), (-6, -8), (0, -5), (10, 2), (1, 1)]

def verify_sources():
    raw = inv.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != inv.SHA256: raise ValueError('XML hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as t:
        root = ET.fromstring(t.extractfile('xml/chapter2/section1/subsection1.xml').read())
    if not any(x.get('NAME') == 'ex:2_1' for x in root.iter('LABEL')): raise ValueError('missing exercise 2.1 label')
    raw = official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != official.SHA256: raise ValueError('MIT archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as t: text=t.extractfile('ch2.scm').read().decode('ascii')
    if '(define (make-rat n d)' not in text or '(define (numer x)' not in text or '(define (denom x)' not in text: raise ValueError('original prerequisites changed')

def run(zig, chibi):
    verify_sources(); chibi=chibi.resolve(); home=chibi.parent
    revision=subprocess.check_output(['git','-C',str(home),'rev-parse','HEAD'],text=True).strip()
    if revision != REVISION: raise ValueError('unexpected reference revision')
    env=dict(os.environ, CHIBI_MODULE_PATH=str(home/'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    program=['const std = @import("std"); const scheme = @import("scheme");', 'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    rows=[]
    for i,(n,d) in enumerate(INPUTS):
        f=Fraction(n,d); expected=f'({f.numerator} . {f.denominator})'; expr=f'(make-rat {n} {d})'; source='(begin '+CANDIDATE+' '+expr+')'
        ref=subprocess.run([str(chibi),'-q','-p',source],cwd=home,env=env,text=True,capture_output=True,check=True)
        if ref.stderr or ref.stdout != expected+'\n': raise ValueError('reference disagreement: '+expr)
        program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [1024]u8 = undefined; try std.testing.expectEqualStrings(%s, try vm.evaluate(%s, &h, &out)); }' % (i,json.dumps(expected),json.dumps(source)))
        rows.append({'exercise':'2.1','expression':expr,'expected':expected,'status':'matched'})
    with tempfile.TemporaryDirectory(prefix='sicp-rat-2-1-') as folder:
        source=Path(folder)/'cases.zig';source.write_text('\n'.join(program)+'\n')
        p=subprocess.run([str(zig.resolve()),'test','-O','ReleaseSafe','--dep','scheme','-Mroot='+str(source),'--dep','view_config','-Mscheme='+str(ROOT/'src/xy/scheme_runtime.zig'),'-Mview_config='+str(ROOT/'src/xy/view_config.zig')],text=True,capture_output=True,check=True)
    return {'xml_sha256':inv.SHA256,'official_code_sha256':official.SHA256,'reference_revision':revision,'candidate':CANDIDATE,'cases':rows,'test_log':p.stdout+p.stderr}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
    print(json.dumps(run(a.zig,a.chibi),indent=2))

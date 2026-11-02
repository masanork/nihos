#!/usr/bin/env python3
"""Finite SICP 2.17, 2.18 and 2.21 candidates against independent answers."""
import argparse
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
CANDIDATES = {
 'last': '(define (last-pair x) (if (null? (cdr x)) x (last-pair (cdr x))))',
 'reverse': '(define (reverse x) (define (iter remaining result) (if (null? remaining) result (iter (cdr remaining) (cons (car remaining) result)))) (iter x (quote ())))',
 'square-rec': '(define (square-list items) (if (null? items) (quote ()) (cons (* (car items) (car items)) (square-list (cdr items)))))',
 'square-map': '(define (square-list items) (map (lambda (x) (* x x)) items))',
}
CASES = [
 ('2.17','last','(last-pair (list 23 72 149 34))','(34)'),
 ('2.17','last',"(last-pair '(5))",'(5)'),
 ('2.17','last',"(last-pair '(1 2 3))",'(3)'),
 ('2.18','reverse','(reverse (list 1 4 9 16 25))','(25 16 9 4 1)'),
 ('2.18','reverse',"(reverse '())",'()'),
 ('2.18','reverse',"(reverse '(a (b c) d))",'(d (b c) a)'),
 ('2.21','square-rec','(square-list (list 1 2 3 4))','(1 4 9 16)'),
 ('2.21','square-rec',"(square-list '())",'()'),
 ('2.21','square-rec',"(square-list '(-2 0 3))",'(4 0 9)'),
 ('2.21','square-map','(square-list (list 1 2 3 4))','(1 4 9 16)'),
 ('2.21','square-map',"(square-list '())",'()'),
 ('2.21','square-map',"(square-list '(-2 0 3))",'(4 0 9)'),
]

def verify_sources():
 raw = inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest() != inv.SHA256: raise ValueError('XML hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as t:
  root = ET.fromstring(t.extractfile('xml/chapter2/section2/subsection1.xml').read())
 labels={n.get('NAME') for n in root.iter('LABEL')}
 if not {'ex:last','ex:reverse','ex:square-list'} <= labels: raise ValueError('missing exercise labels')
 raw = official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest() != official.SHA256: raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as t: code=t.extractfile('ch2.scm').read().decode('ascii')
 for exercise, expr in [('2.17',CASES[0][2]),('2.18',CASES[3][2]),('2.21',CASES[6][2])]:
  block=code.split(';; EXERCISE '+exercise,1)[1].split(';; EXERCISE ',1)[0]
  if ';: '+expr not in block: raise ValueError('original exercise expression changed: '+exercise)

def run(zig, chibi):
 verify_sources(); chibi=chibi.resolve(); home=chibi.parent
 revision=subprocess.check_output(['git','-C',str(home),'rev-parse','HEAD'],text=True).strip()
 if revision!=REVISION: raise ValueError('unexpected reference revision')
 env=dict(os.environ,CHIBI_MODULE_PATH=str(home/'lib'),DYLD_LIBRARY_PATH=str(home),LD_LIBRARY_PATH=str(home))
 program=['const std = @import("std"); const scheme = @import("scheme");', 'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
 rows=[]
 for i,(exercise, key, expr, expected) in enumerate(CASES):
  source='(begin '+CANDIDATES[key]+' '+expr+')'
  reference=subprocess.run([str(chibi),'-q','-p',source],cwd=home,env=env,text=True,capture_output=True,check=True)
  if reference.stderr or reference.stdout != expected+'\n': raise ValueError('reference disagreement: '+expr)
  program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [1024]u8 = undefined; try std.testing.expectEqualStrings(%s, try vm.evaluate(%s, &h, &out)); }' % (i,json.dumps(expected),json.dumps(source)))
  rows.append({'exercise':exercise,'candidate':key,'expression':expr,'expected':expected,'status':'matched'})
 with tempfile.TemporaryDirectory(prefix='sicp-list-exercises-') as folder:
  src=Path(folder)/'test.zig';src.write_text('\n'.join(program)+'\n')
  result=subprocess.run([str(zig.resolve()),'test','-O','ReleaseSafe','--dep','scheme','-Mroot='+str(src),'--dep','view_config','-Mscheme='+str(ROOT/'src/xy/scheme_runtime.zig'),'-Mview_config='+str(ROOT/'src/xy/view_config.zig')],text=True,capture_output=True,check=True)
 return {'xml_sha256':inv.SHA256,'official_code_sha256':official.SHA256,'reference_revision':revision,'candidates':CANDIDATES,'cases':rows,'test_log':result.stdout+result.stderr}

if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--zig',type=Path,required=True);ap.add_argument('--chibi',type=Path,required=True);args=ap.parse_args()
 print(json.dumps(run(args.zig,args.chibi),indent=2))

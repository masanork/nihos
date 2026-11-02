#!/usr/bin/env python3
"""Original SICP 2.53-2.55 forms and a bounded 2.54 solution candidate."""
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

ROOT=Path(__file__).resolve().parents[1]
REVISION='a27d06c749cdea7ca051e69e7629e3af78c01ac4'
CANDIDATE="(define (same-tree? x y) (cond ((and (pair? x) (pair? y)) (and (same-tree? (car x) (car y)) (same-tree? (cdr x) (cdr y)))) ((or (pair? x) (pair? y)) #f) (else (eq? x y))))"
CASES=[
 ('2.53','',"(list 'a 'b 'c)",'(a b c)'),
 ('2.53','',"(list (list 'george))",'((george))'),
 ('2.53','',"(cdr '((x1 x2) (y1 y2)))",'((y1 y2))'),
 ('2.53','',"(cadr '((x1 x2) (y1 y2)))",'(y1 y2)'),
 ('2.53','',"(pair? (car '(a short list)))",'#f'),
 ('2.53','',"(memq 'red '((red shoes) (blue socks)))",'#f'),
 ('2.53','',"(memq 'red '(red shoes blue socks))",'(red shoes blue socks)'),
 ('2.54','',"(equal? '(this is a list) '(this is a list))",'#t'),
 ('2.54','',"(equal? '(this is a list) '(this (is a) list))",'#f'),
 ('2.54',CANDIDATE,"(same-tree? '(a (b c)) '(a (b c)))",'#t'),
 ('2.54',CANDIDATE,"(same-tree? '(a (b c)) '(a (b d)))",'#f'),
 ('2.54',CANDIDATE,"(same-tree? '(a . b) '(a . c))",'#f'),
 ('2.55','',"(car ''abracadabra)",'quote'),
]

def verify_sources():
 raw=inv.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=inv.SHA256: raise ValueError('XML hash mismatch')
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t: root=ET.fromstring(t.extractfile('xml/chapter2/section3/subsection1.xml').read())
 labels={n.get('NAME') for n in root.iter('LABEL')}
 if not {'ex:2_53','ex:equal?','ex:double-quote'}<=labels: raise ValueError('missing source labels')
 raw=official.ARCHIVE.read_bytes()
 if hashlib.sha256(raw).hexdigest()!=official.SHA256: raise ValueError('MIT archive hash mismatch')
 official.inventory(official.ARCHIVE)
 with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t: code=t.extractfile('ch2.scm').read().decode('ascii')
 for exercise,prelude,expr,expected in CASES:
  if prelude: continue
  block=code.split(';; EXERCISE '+exercise,1)[1].split(';; EXERCISE ',1)[0]
  if ';: '+expr not in block: raise ValueError('original expression changed: '+exercise)

def run(zig,chibi):
 verify_sources();chibi=chibi.resolve();home=chibi.parent
 revision=subprocess.check_output(['git','-C',str(home),'rev-parse','HEAD'],text=True).strip()
 if revision!=REVISION: raise ValueError('unexpected reference revision')
 env=dict(os.environ,CHIBI_MODULE_PATH=str(home/'lib'),DYLD_LIBRARY_PATH=str(home),LD_LIBRARY_PATH=str(home))
 program=['const std = @import("std"); const scheme = @import("scheme");','const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };'];rows=[]
 for i,(exercise,prelude,expr,expected) in enumerate(CASES):
  source='(begin '+prelude+' '+expr+')'
  ref=subprocess.run([str(chibi),'-q','-p',source],cwd=home,env=env,text=True,capture_output=True,check=True)
  if ref.stderr or ref.stdout!=expected+'\n': raise ValueError('reference disagreement: '+expr)
  program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [1024]u8 = undefined; try std.testing.expectEqualStrings(%s, try vm.evaluate(%s, &h, &out)); }' % (i,json.dumps(expected),json.dumps(source)))
  rows.append({'exercise':exercise,'expression':expr,'expected':expected,'origin':'candidate' if prelude else 'original','status':'matched'})
 with tempfile.TemporaryDirectory(prefix='sicp-symbols-') as folder:
  src=Path(folder)/'cases.zig';src.write_text('\n'.join(program)+'\n')
  p=subprocess.run([str(zig.resolve()),'test','-O','ReleaseSafe','--dep','scheme','-Mroot='+str(src),'--dep','view_config','-Mscheme='+str(ROOT/'src/xy/scheme_runtime.zig'),'-Mview_config='+str(ROOT/'src/xy/view_config.zig')],text=True,capture_output=True,check=True)
 return {'xml_sha256':inv.SHA256,'official_code_sha256':official.SHA256,'reference_revision':revision,'candidate':CANDIDATE,'cases':rows,'test_log':p.stdout+p.stderr}

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--zig',type=Path,required=True);p.add_argument('--chibi',type=Path,required=True);a=p.parse_args()
 print(json.dumps(run(a.zig,a.chibi),indent=2))

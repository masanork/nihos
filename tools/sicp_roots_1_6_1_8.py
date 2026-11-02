#!/usr/bin/env python3
"""Original SICP square-root examples and bounded exercises 1.6--1.8.

The relative square-root and cube-root procedures are test candidates, not
original book code. Finite results are checked against independent math oracles and compared with Chibi;
divergent new-if evaluation is tested only with xy's bounded evaluator.
"""
import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET

import sicp_exercise_inventory as inventory
import sicp_official_code as official

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'a27d06c749cdea7ca051e69e7629e3af78c01ac4'
XML_MEMBER = 'xml/chapter1/section1/subsection7.xml'
REL = '(define (sqrt-rel x) (define (loop g) (let ((next (/ (+ g (/ x g)) 2))) (if (< (abs (- next g)) (* 0.000000001 (abs next))) next (loop next)))) (if (= x 0) 0.0 (loop 1.0)))'
CUBE = '(define (cube-root x) (define (loop g) (let ((next (/ (+ (/ x (* g g)) (* 2 g)) 3))) (if (< (abs (- next g)) (* 0.000000001 (abs next))) next (loop next)))) (if (= x 0) 0.0 (loop (if (< x 0) -1.0 1.0))))'


def sources():
    raw_xml = inventory.ARCHIVE.read_bytes()
    if hashlib.sha256(raw_xml).hexdigest() != inventory.SHA256:
        raise ValueError('SICP XML archive hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(raw_xml), mode='r:gz') as archive:
        xml = ET.fromstring(archive.extractfile(XML_MEMBER).read())
    labels = {n.get('NAME') for n in xml.iter('LABEL')}
    if not {'ex:new-if', 'ex:ex-sqrt-end-test', 'ex:cube-root-newton'} <= labels:
        raise ValueError('missing exercise labels')
    raw = official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != official.SHA256:
        raise ValueError('MIT SICP archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        chapter = archive.extractfile('ch1.scm').read().decode('ascii')
    square = chapter.split(';;;SECTION 1.1.4', 1)[1].split(';: (square 21)', 1)[0].strip()
    original = chapter.split(';;;SECTION 1.1.7', 1)[1].split(';: (sqrt 9)', 1)[0].strip()
    ex16 = chapter.split(';;EXERCISE 1.6', 1)[1].split(';;;SECTION 1.1.8', 1)[0]
    new_if = ex16.split(';: (new-if (= 2 3) 0 5)', 1)[0].strip()
    replacement = ex16.split(';: (new-if (= 1 1) 0 5)', 1)[1].strip()
    if not square.startswith('(define (square ') or not original.startswith('(define (sqrt-iter ') or not replacement.startswith('(define (sqrt-iter '):
        raise ValueError('unexpected source layout')
    return square, original, new_if, replacement


def run(zig, chibi):
    chibi = chibi.resolve()
    home = chibi.parent
    revision = subprocess.check_output(['git', '-C', str(home), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('unexpected reference revision')
    env = dict(os.environ, CHIBI_MODULE_PATH=str(home / 'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    square, original, new_if, replacement = sources()
    original_context = square + '\n' + original
    checks = [
        ('original', '(sqrt 9)', 3.00009155413138),
        ('original', '(sqrt (+ 100 37))', 11.704699917758145),
        ('original', '(sqrt (+ (sqrt 2) (sqrt 3)))', 1.7739279023207892),
        ('original', '(square (sqrt 1000))', 1000.000369924366),
        ('original', '(sqrt 1e-12)', 0.031250000010656254),
        ('relative', '(sqrt-rel 9)', 3.0),
        ('relative', '(sqrt-rel 1e-12)', 1e-6),
        ('relative', '(sqrt-rel 10000000000000.0)', math.sqrt(1e13)),
        ('relative', '(sqrt-rel 0)', 0.0),
        ('cube', '(cube-root 27)', 3.0),
        ('cube', '(cube-root -8)', -2.0),
        ('cube', '(cube-root 1e-12)', 0.0001),
        ('cube', '(cube-root 0)', 0.0),
    ]
    contexts = {'original': original_context, 'relative': REL, 'cube': CUBE}
    rows = []
    for group, expression, oracle in checks:
        result = subprocess.run([str(chibi), '-q', '-p', '(begin ' + contexts[group] + ' ' + expression + ')'],
                                cwd=home, env=env, text=True, capture_output=True, check=True)
        if result.stderr:
            raise ValueError(f'reference failed for {expression}: {result.stderr}')
        reference = float(result.stdout.strip())
        agrees = math.isclose(reference, oracle, rel_tol=1e-12, abs_tol=1e-15)
        if not agrees and expression != '(sqrt-rel 1e-12)':
            raise ValueError(f'unexpected reference disagreement for {expression}: {reference}')
        rows.append({'group': group, 'expression': expression, 'reference': result.stdout.strip(), 'oracle': oracle,
                     'reference_agrees_with_oracle': agrees})
    program = ['const std=@import("std"); const scheme=@import("scheme");',
               'const Host=struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };',
               'fn check(vm:*scheme.Runtime, host:*Host, expression:[]const u8, expected:f64) !void { var out:[512]u8=undefined; const text=try vm.evaluate(expression, host, &out); const got=try std.fmt.parseFloat(f64,text); try std.testing.expectApproxEqAbs(expected,got,@max(1e-15, @abs(expected)*1e-12)); }']
    for group in ('original', 'relative', 'cube'):
        body = ['var vm:scheme.Runtime=undefined; vm.initInPlace(); var host=Host{}; var out:[512]u8=undefined;',
                f'_ = try vm.evaluate({json.dumps(contexts[group])}, &host, &out);']
        for category, expression, oracle in checks:
            if category == group:
                body.append(f'try check(&vm,&host,{json.dumps(expression)},{oracle:.17g});')
        if group == 'relative':
            body.append('try std.testing.expectEqualStrings("#t", try vm.evaluate("(< -0.0009765623293330288 0)", &host, &out));')
            body.append('try std.testing.expectEqualStrings("0.0009765623293330288", try vm.evaluate("(abs -0.0009765623293330288)", &host, &out));')
        if group == 'original':
            # Large original is a current bound: permit a future successful,
            # accurate evaluation as well as the current budget failure.
            body.append('if (vm.evaluate("(sqrt 10000000000000.0)", &host, &out)) |value| { const f=try std.fmt.parseFloat(f64,value); try std.testing.expectApproxEqRel(@as(f64,3162277.6601683795), f, 1e-9); std.debug.print("LARGE_ORIGINAL=success\\n", .{}); } else |err| { if (err != error.Budget) return err; std.debug.print("LARGE_ORIGINAL=Budget\\n", .{}); }')
        program.append('test ' + json.dumps(group) + ' { ' + ' '.join(body) + ' }')
    body = ['var vm:scheme.Runtime=undefined; vm.initInPlace(); var host=Host{}; var out:[512]u8=undefined;',
            f'_ = try vm.evaluate({json.dumps(original_context)}, &host, &out);',
            f'_ = try vm.evaluate({json.dumps(new_if)}, &host, &out);',
            'try std.testing.expectEqualStrings("5", try vm.evaluate("(new-if (= 2 3) 0 5)", &host, &out));',
            'try std.testing.expectEqualStrings("0", try vm.evaluate("(new-if (= 1 1) 0 5)", &host, &out));',
            f'_ = try vm.evaluate({json.dumps(replacement)}, &host, &out);',
            'if (vm.evaluate("(sqrt 9)", &host, &out)) |_| { return error.UnexpectedSuccess; } else |err| { if (err != error.Depth and err != error.HeapFull and err != error.Budget) return err; std.debug.print("NEW_IF_LIMIT={s}\\n", .{@errorName(err)}); }',
            'try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));']
    program.append('test "exercise 1.6" { ' + ' '.join(body) + ' }')
    with tempfile.TemporaryDirectory(prefix='sicp-roots-') as folder:
        path = Path(folder) / 'cases.zig'
        path.write_text('\n'.join(program) + '\n')
        result = subprocess.run([str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(path),
                                 '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
                                 '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')], text=True, capture_output=True, check=True)
    marker = result.stdout + result.stderr
    print(json.dumps({'xml_sha256': inventory.SHA256, 'official_code_sha256': official.SHA256,
                      'source_xml': XML_MEMBER, 'reference_revision': revision,
                      'original_square': square, 'original_sqrt_definitions': original,
                      'original_new_if': new_if, 'original_new_if_sqrt_iter': replacement,
                      'exercise_1_7_candidate': REL, 'exercise_1_8_candidate': CUBE,
                      'finite_checks': rows, 'test_log': marker}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', required=True, type=Path)
    parser.add_argument('--chibi', required=True, type=Path)
    args = parser.parse_args()
    run(args.zig.resolve(), args.chibi)

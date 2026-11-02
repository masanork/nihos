#!/usr/bin/env python3
"""Bounded executable checks for SICP exercises 1.2--1.5.

Exercise 1.2 is our translation of the original mathematical expression;
1.3 uses our own candidate procedure and independent integer oracles. 1.4
and 1.5 load the definitions from MIT's pinned unmodified chapter code.
A fuel error on the divergent 1.5 example is evidence of bounded evaluation,
not a mathematical termination proof or a test of normal-order evaluation.
"""
import argparse
from fractions import Fraction
import hashlib
import io
import itertools
import json
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
XML_MEMBER = 'xml/chapter1/section1/subsection6.xml'
EX12 = '(/ (+ 5 4 (- 2 (- 3 (+ 6 (/ 4 5))))) (* 3 (- 6 2) (- 2 7)))'
EX13 = '(define (two-square a b c) (let ((m (min a b c))) (- (+ (* a a) (* b b) (* c c)) (* m m))))'


def sources():
    raw_xml = inventory.ARCHIVE.read_bytes()
    if hashlib.sha256(raw_xml).hexdigest() != inventory.SHA256:
        raise ValueError('SICP XML archive hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(raw_xml), mode='r:gz') as archive:
        xml = ET.fromstring(archive.extractfile(XML_MEMBER).read())
    labels = {node.get('NAME') for node in xml.iter('LABEL')}
    required = {'ex:1_2', 'ex:1_3', 'ex:a-plus-abs-b', 'ex:normal-order-vs-appl-order-test'}
    if not required.issubset(labels):
        raise ValueError('missing source exercise labels')
    raw_code = official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw_code).hexdigest() != official.SHA256:
        raise ValueError('MIT SICP archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw_code), mode='r:gz') as archive:
        code = archive.extractfile('ch1.scm').read().decode('ascii')
    ex14 = code.split(';;EXERCISE 1.4', 1)[1].split(';;EXERCISE 1.5', 1)[0].strip()
    ex15 = code.split(';;EXERCISE 1.5', 1)[1].split(';: (test 0 (p))', 1)[0].strip()
    if not ex14.startswith('(define (a-plus-abs-b ') or not ex15.startswith('(define (p)'):
        raise ValueError('unexpected chapter code layout')
    return ex14, ex15


def run(zig, chibi):
    chibi = chibi.resolve()
    home = chibi.parent
    revision = subprocess.check_output(['git', '-C', str(home), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('unexpected Chibi revision')
    env = dict(os.environ, CHIBI_MODULE_PATH=str(home / 'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    ex14, ex15 = sources()
    expression_cases = [('1.2', EX12, str((Fraction(5) + 4 + (2 - (3 - (6 + Fraction(4, 5))))) / (3 * (6 - 2) * (2 - 7))))]
    triples = sorted(set(itertools.permutations((4, 7, 2))) | set(itertools.permutations((-3, -2, -1))) |
                     set(itertools.permutations((2, 2, 3))) | {(0, 0, 0), (-2, -2, -2)})
    for a, b, c in triples:
        two = sorted((a, b, c))[-2:]
        expression_cases.append(('1.3', f'(two-square {a} {b} {c})', str(sum(x * x for x in two))))
    for a, b in ((5, 4), (5, -4), (5, 0), (-7, 3), (-7, -3)):
        expression_cases.append(('1.4', f'(a-plus-abs-b {a} {b})', str(a + abs(b))))
    expression_cases.extend([('1.5', '(test 1 9)', '9'), ('1.5', '(test 0 9)', '0')])
    context = {'1.2': '', '1.3': EX13, '1.4': ex14, '1.5': ex15}
    ref_rows = []
    for exercise, expr, expected in expression_cases:
        # Finite reference evaluations only. Never run (p) in the reference.
        ref = subprocess.run([str(chibi), '-q', '-p', '(begin ' + context[exercise] + ' ' + expr + ')'],
                             cwd=home, env=env, text=True, capture_output=True, check=True)
        if ref.stderr or ref.stdout != expected + '\n':
            raise ValueError(f'reference disagreement in exercise {exercise}: {expr}: {ref.stdout} {ref.stderr}')
        ref_rows.append({'exercise': exercise, 'expression': expr, 'expected': expected, 'status': 'matched'})
    program = ['const std=@import("std"); const scheme=@import("scheme");',
               'const Host=struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    for exercise in ('1.2', '1.3', '1.4', '1.5'):
        body = ['var vm: scheme.Runtime=undefined; vm.initInPlace(); var host=Host{}; var out:[512]u8=undefined;']
        if context[exercise]:
            body.append(f'_ = try vm.evaluate({json.dumps(context[exercise])}, &host, &out);')
        for category, expr, expected in expression_cases:
            if category == exercise:
                body.append(f'try std.testing.expectEqualStrings({json.dumps(expected)}, try vm.evaluate({json.dumps(expr)}, &host, &out));')
        if exercise == '1.5':
            body.append('try std.testing.expectError(error.Budget, vm.evaluate("(test 0 (p))", &host, &out));')
            body.append('try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));')
        program.append('test ' + json.dumps('exercise ' + exercise) + ' { ' + ' '.join(body) + ' }')
    with tempfile.TemporaryDirectory(prefix='sicp-exercises-') as folder:
        root = Path(folder) / 'cases.zig'
        root.write_text('\n'.join(program) + '\n')
        subprocess.run([str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(root),
                        '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
                        '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')], check=True)
    print(json.dumps({'xml_sha256': inventory.SHA256, 'official_code_sha256': official.SHA256,
                      'source_xml': XML_MEMBER, 'reference_revision': revision,
                      'exercise_1_2_translation': EX12, 'exercise_1_3_candidate': EX13,
                      'exercise_1_4_source': ex14, 'exercise_1_5_source': ex15,
                      'finite_checks': ref_rows, 'divergence': {'source': '(test 0 (p))',
                      'status': 'budget_error_then_recovered', 'reference_run': False}}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', required=True, type=Path)
    parser.add_argument('--chibi', required=True, type=Path)
    args = parser.parse_args()
    run(args.zig.resolve(), args.chibi)

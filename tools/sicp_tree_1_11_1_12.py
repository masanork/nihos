#!/usr/bin/env python3
"""SICP 1.2.2 examples and bounded candidate checks for exercises 1.11/1.12.

Known resource failures are recorded as gaps, never counted as matches.
The exercise solutions here are explicit candidates, not original code.
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
XML_MEMBER = 'xml/chapter1/section2/subsection2.xml'
FREC = '(define (f-rec n) (if (< n 3) n (+ (f-rec (- n 1)) (* 2 (f-rec (- n 2))) (* 3 (f-rec (- n 3))))))'
FIT = '(define (f-it n) (define (go a b c k) (if (= k 0) c (go (+ a (* 2 b) (* 3 c)) a b (- k 1)))) (if (< n 3) n (go 2 1 0 n)))'
PASCAL = '(define (pascal row col) (if (or (= col 0) (= col row)) 1 (+ (pascal (- row 1) (- col 1)) (pascal (- row 1) col))))'


def sources():
    raw = inventory.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != inventory.SHA256:
        raise ValueError('SICP XML archive hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        xml = ET.fromstring(archive.extractfile(XML_MEMBER).read())
    labels = {n.get('NAME') for n in xml.iter('LABEL')}
    if not {'ex:1_11', 'ex:1_12'} <= labels:
        raise ValueError('missing exercise labels')
    raw = official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != official.SHA256:
        raise ValueError('MIT SICP archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        chapter = archive.extractfile('ch1.scm').read().decode('ascii')
    section = chapter.split(';;;SECTION 1.2.2', 1)[1].split(';;;SECTION 1.2.3', 1)[0]
    fib_rec = section.split(';; Recursive', 1)[1].split(';; Iterative', 1)[0].strip()
    fib_it = section.split(';; Iterative', 1)[1].split(';; Counting change', 1)[0].strip()
    coins = section.split(';; Counting change', 1)[1].split(';: (count-change 100)', 1)[0].strip()
    if not all(x.startswith('(define ') for x in (fib_rec, fib_it, coins)):
        raise ValueError('unexpected chapter source layout')
    return fib_rec, fib_it, coins


def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def recurrence(n):
    values = [0, 1, 2]
    for k in range(3, n + 1):
        values.append(values[k - 1] + 2 * values[k - 2] + 3 * values[k - 3])
    return values[n]


def changes(n):
    dp = [1] + [0] * n
    for coin in (1, 5, 10, 25, 50):
        for i in range(coin, n + 1):
            dp[i] += dp[i - coin]
    return dp[n]


def run(zig, chibi, require_expanded=False, strict=False):
    chibi = chibi.resolve()
    home = chibi.parent
    revision = subprocess.check_output(['git', '-C', str(home), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('unexpected Chibi revision')
    env = dict(os.environ, CHIBI_MODULE_PATH=str(home / 'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    fib_rec, fib_it, coins = sources()
    contexts = {'fib-rec': fib_rec, 'fib-it': fib_it, 'count-change': coins,
                'exercise-1.11-rec': FREC, 'exercise-1.11-it': FIT, 'exercise-1.12': PASCAL}
    cases = []
    for n in range(11): cases.append(('fib-rec', f'(fib {n})', str(fib(n))))
    for n in (0, 1, 2, 10, 30, 45, 46): cases.append(('fib-it', f'(fib {n})', str(fib(n))))
    for n in (0, 5, 10, 15, 20, 25, 100): cases.append(('count-change', f'(count-change {n})', str(changes(n))))
    for n in range(11): cases.append(('exercise-1.11-rec', f'(f-rec {n})', str(recurrence(n))))
    for n in (0, 1, 2, 3, 5, 10, 15, 20): cases.append(('exercise-1.11-it', f'(f-it {n})', str(recurrence(n))))
    for row in range(9):
        for col in sorted({0, row // 2, row}):
            cases.append(('exercise-1.12', f'(pascal {row} {col})', str(math.comb(row, col))))
    rows = []
    for group, expression, expected in cases:
        ref = subprocess.run([str(chibi), '-q', '-p', '(begin ' + contexts[group] + ' ' + expression + ')'],
                             cwd=home, env=env, text=True, capture_output=True, check=True)
        if ref.stderr or ref.stdout != expected + '\n':
            raise ValueError(f'reference disagreement for {expression}: {ref.stdout} {ref.stderr}')
        rows.append({'group': group, 'expression': expression, 'expected': expected, 'status': 'pending'})
    program = ['const std=@import("std"); const scheme=@import("scheme");',
               'const Host=struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    for group, context in contexts.items():
        body = ['var vm:scheme.Runtime=undefined; vm.initInPlace(); var host=Host{}; var out:[512]u8=undefined;',
                f'_ = try vm.evaluate({json.dumps(context)}, &host, &out);']
        for i, (category, expression, expected) in enumerate(cases):
            if category != group: continue
            body.append(f'if (vm.evaluate({json.dumps(expression)}, &host, &out)) |value| {{ try std.testing.expectEqualStrings({json.dumps(expected)},value); std.debug.print("CASE_{i}=match\\n", .{{}}); }} else |err| {{ if (err != error.HeapFull and err != error.Depth and err != error.Budget and err != error.Overflow) return err; std.debug.print("CASE_{i}={{s}}\\n", .{{@errorName(err)}}); }}')
            body.append('try std.testing.expectEqualStrings("42", try vm.evaluate("(+ 20 22)", &host, &out));')
        program.append('test ' + json.dumps(group) + ' { ' + ' '.join(body) + ' }')
    with tempfile.TemporaryDirectory(prefix='sicp-tree-') as folder:
        path = Path(folder) / 'cases.zig'
        path.write_text('\n'.join(program) + '\n')
        result = subprocess.run([str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(path),
                                 '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
                                 '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')], text=True, capture_output=True, check=True)
    marker = result.stdout + result.stderr
    for i, row in enumerate(rows):
        matches = [line.split('=', 1)[1].strip() for line in marker.splitlines() if f'CASE_{i}=' in line]
        if len(matches) != 1: raise ValueError(f'missing case marker {i}')
        row['status'] = matches[0]
    required = {('fib-rec', '(fib 10)'), ('count-change', '(count-change 15)'),
                ('exercise-1.11-rec', '(f-rec 9)'), ('exercise-1.12', '(pascal 8 4)')}
    failed = [(row['group'], row['expression'], row['status']) for row in rows
              if (row['group'], row['expression']) in required and row['status'] != 'match']
    if require_expanded and failed:
        raise ValueError(f'regression in expanded-capacity cases: {failed}')
    print(json.dumps({'xml_sha256': inventory.SHA256, 'official_code_sha256': official.SHA256,
                      'source_xml': XML_MEMBER, 'reference_revision': revision,
                      'original_fib_recursive': fib_rec, 'original_fib_iterative': fib_it, 'original_count_change': coins,
                      'exercise_1_11_recursive_candidate': FREC, 'exercise_1_11_iterative_candidate': FIT,
                      'exercise_1_12_candidate': PASCAL, 'cases': rows,
                      'matched': sum(row['status'] == 'match' for row in rows),
                      'gaps': sum(row['status'] != 'match' for row in rows), 'test_log': marker}, indent=2))
    if strict and any(row['status'] != 'match' for row in rows):
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', required=True, type=Path)
    parser.add_argument('--chibi', required=True, type=Path)
    parser.add_argument('--require-expanded', action='store_true')
    parser.add_argument('--strict', action='store_true', help='exit nonzero after reporting any gaps')
    args = parser.parse_args()
    run(args.zig.resolve(), args.chibi, args.require_expanded, args.strict)

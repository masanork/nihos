#!/usr/bin/env python3
"""Small independent host probes for prioritizing SICP/R7RS gaps, not conformance."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Expressions are closed and use fresh runtimes; expected results are literal oracles.
CASES = [
    ('closure-state', 'closures/set!', '(begin (define (counter) (let ((n 0)) (lambda () (set! n (+ n 1)) n))) (define c (counter)) (c) (c))', '2'),
    ('mutable-pair', 'pairs/mutation', "(let ((x (cons 1 2))) (set-car! x 3) (set-cdr! x 4) x)", '(3 . 4)'),
    ('pair-equality', 'pairs/equality', "(equal? '(a (b c)) '(a (b c)))", '#t'),
    ('list-map', 'lists/map', "(map (lambda (x) (* x x)) '(1 2 3))", '(1 4 9)'),
    ('member', 'lists/search', "(member 'b '(a b c))", '(b c)'),
    ('let-star', 'binding/let*', '(let* ((a 1) (b (+ a 2))) b)', '3'),
    ('letrec', 'binding/letrec', '(letrec ((f (lambda (n) (if (= n 0) 0 (f (- n 1)))))) (f 5))', '0'),
    ('named-let', 'binding/named-let', '(let loop ((n 5) (a 0)) (if (= n 0) a (loop (- n 1) (+ a n))))', '15'),
    ('quasiquote', 'reader/quasiquote', "(let ((x 2)) `(1 ,x 3))", '(1 2 3)'),
    ('symbol-predicate', 'symbols', "(symbol? 'x)", '#t'),
    ('character', 'characters', '(char? #\\a)', '#t'),
    ('string', 'strings', '(string-length "abc")', '3'),
    ('vector', 'vectors', '(let ((v (vector 1 2))) (vector-set! v 0 7) (vector-ref v 0))', '7'),
    ('bytevector', 'bytevectors', '(bytevector-u8-ref (bytevector 3 4) 1)', '4'),
    ('delay-force', 'control/promises', '(force (delay (+ 1 2)))', '3'),
    ('call-cc', 'control/continuations', '(call-with-current-continuation (lambda (k) (+ 1 (k 9))))', '9'),
    ('multiple-values', 'control/values', '(call-with-values (lambda () (values 2 3)) +)', '5'),
    ('hygienic-macro', 'syntax/macros', '(begin (define-syntax twice (syntax-rules () ((_ x) (+ x x)))) (twice 4))', '8'),
    ('large-integer', 'numbers/range', '(+ 2147483647 1)', '2147483648'),
    ('transcendental', 'numbers/transcendentals', '(sqrt 4)', '2'),
]

def probe(zig):
    program = ['const std = @import("std"); const scheme = @import("scheme");',
        'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    for i, (_, _, source, _) in enumerate(CASES):
        program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [4096]u8 = undefined; const value = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("FEATURE\\t%d\\terror\\t{s}\\n", .{@errorName(err)}); return; }; std.debug.print("FEATURE\\t%d\\tvalue\\t{s}\\n", .{value}); }' % (i, json.dumps(source), i, i))
    with tempfile.TemporaryDirectory(prefix='sicp-r7rs-feature-') as folder:
        src = Path(folder) / 'probe.zig'; src.write_text('\n'.join(program) + '\n')
        p = subprocess.run([str(zig.resolve()), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot='+str(src), '--dep', 'view_config', '-Mscheme='+str(ROOT/'src/xy/scheme_runtime.zig'), '-Mview_config='+str(ROOT/'src/xy/view_config.zig')], text=True, capture_output=True)
    if p.returncode: raise RuntimeError(p.stdout + p.stderr)
    found = {}
    for line in (p.stdout + p.stderr).splitlines():
        if 'FEATURE\t' not in line: continue
        _, index, kind, value = line[line.index('FEATURE\t'):].split('\t', 3)
        i = int(index)
        if i in found or i >= len(CASES): raise ValueError('duplicate or invalid probe index')
        name, feature, source, expected = CASES[i]
        found[i] = dict(id=name, feature=feature, expression=source, expected=expected, observed=value,
                        outcome='match' if kind == 'value' and value == expected else ('error' if kind == 'error' else 'mismatch'))
    if set(found) != set(range(len(CASES))): raise ValueError('missing feature probe results')
    return [found[i] for i in range(len(CASES))]

if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('--zig', type=Path, required=True); args = ap.parse_args()
    print(json.dumps({'scope':'fresh host runtimes; individual examples, not conformance', 'cases':probe(args.zig)}, indent=2))

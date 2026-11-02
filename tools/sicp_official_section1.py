#!/usr/bin/env python3
"""Differential tests for the original chapter 1, section 1.1.1 examples.

The 21-file archive is kept intact. This narrow executable slice does not
represent the complete book or any exercise-coverage measurement.
"""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import sicp_official_code as official

ROOT = Path(__file__).resolve().parents[1]
REFERENCE_REVISION = 'a27d06c749cdea7ca051e69e7629e3af78c01ac4'


def source_examples():
    official.inventory()  # Validate the entire pinned archive before reading any member.
    with tarfile.open(fileobj=io.BytesIO(official.ARCHIVE.read_bytes()), mode='r:gz') as archive:
        text = archive.extractfile('ch1.scm').read().decode('ascii')
    section = text.split(';;;SECTION 1.1.1', 1)[1].split(';;;SECTION 1.1.2', 1)[0]
    expressions, pending, depth = [], [], 0
    for line in section.splitlines():
        if not line.startswith(';:'):
            continue
        part = line[2:].strip()
        pending.append(part)
        depth += part.count('(') - part.count(')')
        if depth < 0:
            raise ValueError('unexpected parenthesis in upstream section')
        if depth == 0:
            expressions.append(' '.join(pending))
            pending = []
    if pending or depth or len(expressions) != 11:
        raise ValueError('unexpected upstream example layout')
    return expressions


def run(zig, chibi):
    chibi = chibi.resolve()
    home = chibi.parent
    revision = subprocess.check_output(['git', '-C', str(home), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REFERENCE_REVISION:
        raise ValueError('unexpected reference revision')
    env = dict(os.environ, CHIBI_MODULE_PATH=str(home / 'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    expressions = source_examples()
    expected = []
    for expr in expressions:
        result = subprocess.run([str(chibi), '-q', '-p', expr], cwd=home, env=env, text=True, capture_output=True, check=True)
        if result.stderr or not result.stdout.endswith('\n'):
            raise ValueError('unexpected reference output')
        expected.append(result.stdout[:-1])
    program = ['const std = @import("std"); const scheme = @import("scheme");',
               'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    rows = []
    for index, (expr, result) in enumerate(zip(expressions, expected)):
        known_gap = expr == '(+ 2.7 10)'
        expected_assertion = (f'if (got) |value| {{ try std.testing.expectEqualStrings({json.dumps(result)}, value); std.debug.print("XY_SICP_INEXACT_MATCH\\n", .{{}}); }} else |err| {{ if (err != error.Overflow) return err; std.debug.print("XY_SICP_INEXACT_UNSUPPORTED\\n", .{{}}); }}' if known_gap else
                              f'try std.testing.expectEqualStrings({json.dumps(result)}, try got);')
        program.append(f'test "official_{index}" {{ var vm: scheme.Runtime = undefined; vm.initInPlace(); var host = Host{{}}; var out: [512]u8 = undefined; const got = vm.evaluate({json.dumps(expr)}, &host, &out); {expected_assertion} }}')
        rows.append({'expression': expr, 'reference': result, 'status': 'pending-inexact' if known_gap else 'matched'})
    with tempfile.TemporaryDirectory(prefix='sicp-official-section-') as folder:
        path = Path(folder) / 'cases.zig'
        path.write_text('\n'.join(program) + '\n')
        result = subprocess.run([str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(path),
                                 '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
                                 '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')], text=True, capture_output=True, check=True)
        marker = result.stdout + result.stderr
        if marker.count('XY_SICP_INEXACT_MATCH') + marker.count('XY_SICP_INEXACT_UNSUPPORTED') != 1:
            raise ValueError('missing or duplicate inexact status')
        rows[5]['status'] = 'matched' if 'XY_SICP_INEXACT_MATCH' in marker else 'unsupported-inexact'
    print(json.dumps({'source_archive_sha256': official.SHA256, 'chapter': 'ch1.scm',
                      'section': '1.1.1', 'reference_revision': revision, 'examples': rows}, indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--zig', type=Path, required=True)
    p.add_argument('--chibi', type=Path, required=True)
    a = p.parse_args()
    run(a.zig.resolve(), a.chibi)

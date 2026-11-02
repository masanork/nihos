#!/usr/bin/env python3
"""Compare two sequential, isolated SICP sessions from MIT's pinned code.

Definitions are executed in order in each fresh runtime. Only ordinary value
expressions are compared; a definition has unspecified Scheme return value.
This is not a whole-book or whole-exercise conformance claim.
"""
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

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'a27d06c749cdea7ca051e69e7629e3af78c01ac4'
SESSIONS = (('section-1.1.2', ';;;SECTION 1.1.2', ';;;SECTION 1.1.3', 8),
            ('exercise-1.1', ';;EXERCISE 1.1\n', ';;EXERCISE 1.4', 13))


def source_sessions():
    raw = official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != official.SHA256:
        raise ValueError('MIT SICP archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        text = archive.extractfile('ch1.scm').read().decode('ascii')
    sessions = {}
    for name, start, end, count in SESSIONS:
        section = text.split(start, 1)[1].split(end, 1)[0]
        forms, pending, depth = [], [], 0
        for line in section.splitlines():
            if not line.startswith(';:'):
                continue
            part = line[2:].strip()
            pending.append(part)
            depth += part.count('(') - part.count(')')
            if depth < 0:
                raise ValueError(f'unbalanced upstream form in {name}')
            if depth == 0:
                forms.append(' '.join(pending))
                pending = []
        if pending or depth or len(forms) != count:
            raise ValueError(f'unexpected upstream example layout in {name}')
        sessions[name] = forms
    return sessions


def run(zig, chibi):
    chibi = chibi.resolve()
    home = chibi.parent
    revision = subprocess.check_output(['git', '-C', str(home), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('unexpected reference revision')
    env = dict(os.environ, CHIBI_MODULE_PATH=str(home / 'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    sessions = source_sessions()
    program = ['const std = @import("std"); const scheme = @import("scheme");',
               'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    rows = []
    with tempfile.TemporaryDirectory(prefix='sicp-sessions-') as folder:
        folder = Path(folder)
        for name, forms in sessions.items():
            reference = []
            for form in forms:
                if form.startswith('(define '):
                    reference.append(form)
                else:
                    reference.append('(write ' + form + ') (newline)')
            source = folder / (name + '.scm')
            source.write_text('\n'.join(reference) + '\n')
            result = subprocess.run([str(chibi), '-q', str(source)], cwd=home, env=env, text=True, capture_output=True, check=True)
            if result.stderr:
                raise ValueError('unexpected reference stderr: ' + result.stderr)
            reference_values = result.stdout.splitlines()
            # Independently specified answers anchor the reference run;
            # definitions have no portable printed result.
            if name == 'exercise-1.1' and reference_values != [
                    '10', '12', '8', '3', '6', '19', '#f', '4', '16', '6', '16']:
                raise ValueError('exercise 1.1 reference answers changed')
            values = iter(reference_values)
            body = ['var vm: scheme.Runtime = undefined; vm.initInPlace(); var host = Host{}; var out: [512]u8 = undefined;']
            observed = []
            for form in forms:
                if form.startswith('(define '):
                    body.append(f'_ = try vm.evaluate({json.dumps(form)}, &host, &out);')
                    observed.append({'source': form, 'kind': 'definition', 'status': 'executed'})
                else:
                    value = next(values)
                    body.append(f'try std.testing.expectEqualStrings({json.dumps(value)}, try vm.evaluate({json.dumps(form)}, &host, &out));')
                    observed.append({'source': form, 'kind': 'expression', 'reference': value, 'status': 'matched'})
            if next(values, None) is not None:
                raise ValueError('unexpected additional reference output')
            program.append('test ' + json.dumps(name) + ' { ' + ' '.join(body) + ' }')
            rows.append({'name': name, 'forms': observed})
        root = folder / 'cases.zig'
        root.write_text('\n'.join(program) + '\n')
        subprocess.run([str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(root),
                        '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
                        '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')], check=True)
    print(json.dumps({'source_archive_sha256': official.SHA256, 'chapter': 'ch1.scm',
                      'reference_revision': revision, 'sessions': rows}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--chibi', type=Path, required=True)
    args = parser.parse_args()
    run(args.zig.resolve(), args.chibi)

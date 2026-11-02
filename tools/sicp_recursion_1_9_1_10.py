#!/usr/bin/env python3
"""Bounded original SICP 1.9 and 1.10 recursion checks.

The two definitions of + use separate VMs. The inc/dec setup is taken from
pinned Source Academy XML; other definitions come from the MIT code archive.
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
import xml.etree.ElementTree as ET

import sicp_exercise_inventory as inventory
import sicp_official_code as official

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'a27d06c749cdea7ca051e69e7629e3af78c01ac4'
XML_MEMBER = 'xml/chapter1/section2/subsection1.xml'


def sources():
    raw = inventory.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != inventory.SHA256:
        raise ValueError('SICP XML archive hash mismatch')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        xml = ET.fromstring(archive.extractfile(XML_MEMBER).read())
    labels = {node.get('NAME') for node in xml.iter('LABEL')}
    if not {'ex:addition-procedures', 'ex:1_10'} <= labels:
        raise ValueError('missing exercise labels')
    matches = [snippet for snippet in xml.iter('SNIPPET') if snippet.findtext('NAME') == 'inc_dec_definition']
    if len(matches) != 1:
        raise ValueError('unexpected inc/dec setup')
    inc_dec = matches[0].findtext('SCHEME').strip()
    raw = official.ARCHIVE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != official.SHA256:
        raise ValueError('MIT SICP archive hash mismatch')
    official.inventory(official.ARCHIVE)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        chapter = archive.extractfile('ch1.scm').read().decode('ascii')
    add_section = chapter.split(';;EXERCISE 1.9', 1)[1].split(';;EXERCISE 1.10', 1)[0].strip()
    rec, iterative = add_section.split('\n\n', 1)
    a_section = chapter.split(';;EXERCISE 1.10', 1)[1].split(';;;SECTION 1.2.2', 1)[0]
    a_proc = a_section.split(';: (A 1 10)', 1)[0].strip()
    wrappers = a_section.split(';: (A 3 3)', 1)[1].strip()
    if not all(x.startswith('(define ') for x in (inc_dec, rec, iterative, a_proc, wrappers)):
        raise ValueError('unexpected source layout')
    return inc_dec, rec, iterative, a_proc, wrappers


def run(zig, chibi):
    chibi = chibi.resolve()
    home = chibi.parent
    revision = subprocess.check_output(['git', '-C', str(home), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('unexpected Chibi revision')
    env = dict(os.environ, CHIBI_MODULE_PATH=str(home / 'lib'), DYLD_LIBRARY_PATH=str(home), LD_LIBRARY_PATH=str(home))
    inc_dec, rec, iterative, a_proc, wrappers = sources()
    contexts = {'recursive': inc_dec + '\n' + rec, 'iterative': inc_dec + '\n' + iterative,
                'ackermann': a_proc + '\n' + wrappers}
    cases = [('recursive', '(+ 0 5)', '5'), ('recursive', '(+ 4 5)', '9'), ('recursive', '(+ 6 3)', '9'),
             ('iterative', '(+ 0 5)', '5'), ('iterative', '(+ 4 5)', '9'), ('iterative', '(+ 30 5)', '35'),
             ('iterative', '(+ 150 5)', '155'), ('ackermann', '(A 0 5)', '10'),
             ('ackermann', '(A 1 10)', '1024'), ('ackermann', '(A 2 4)', '65536'),
             ('ackermann', '(A 3 3)', '65536'), ('ackermann', '(f 5)', '10'),
             ('ackermann', '(g 5)', '32'), ('ackermann', '(h 3)', '16'), ('ackermann', '(k 5)', '125')]
    rows = []
    for group, expression, expected in cases:
        result = subprocess.run([str(chibi), '-q', '-p', '(begin ' + contexts[group] + ' ' + expression + ')'],
                                cwd=home, env=env, text=True, capture_output=True, check=True)
        if result.stderr or result.stdout != expected + '\n':
            raise ValueError(f'reference disagrees for {expression}: {result.stdout} {result.stderr}')
        rows.append({'group': group, 'expression': expression, 'expected': expected, 'status': 'matched'})
    program = ['const std=@import("std"); const scheme=@import("scheme");',
               'const Host=struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    for group in ('recursive', 'iterative', 'ackermann'):
        body = ['var vm:scheme.Runtime=undefined; vm.initInPlace(); var host=Host{}; var out:[512]u8=undefined;',
                f'_ = try vm.evaluate({json.dumps(contexts[group])}, &host, &out);']
        for category, expression, expected in cases:
            if category == group:
                body.append(f'try std.testing.expectEqualStrings({json.dumps(expected)}, try vm.evaluate({json.dumps(expression)}, &host, &out));')
        if group == 'recursive':
            # A future implementation may legitimately expand depth capacity.
            body.append('if (vm.evaluate("(+ 30 5)", &host, &out)) |v| { try std.testing.expectEqualStrings("35",v); std.debug.print("NONTAIL_30=success\\n", .{}); } else |err| { if (err != error.Depth) return err; std.debug.print("NONTAIL_30=Depth\\n", .{}); }')
            body.append('try std.testing.expectEqualStrings("42", try vm.evaluate("(- 44 2)", &host, &out));')
        program.append('test ' + json.dumps(group) + ' { ' + ' '.join(body) + ' }')
    with tempfile.TemporaryDirectory(prefix='sicp-recursion-') as folder:
        path = Path(folder) / 'cases.zig'
        path.write_text('\n'.join(program) + '\n')
        result = subprocess.run([str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(path),
                                 '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
                                 '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')], text=True, capture_output=True, check=True)
    print(json.dumps({'xml_sha256': inventory.SHA256, 'official_code_sha256': official.SHA256,
                      'source_xml': XML_MEMBER, 'reference_revision': revision,
                      'inc_dec': inc_dec, 'recursive_add': rec, 'iterative_add': iterative,
                      'ackermann': a_proc, 'wrappers': wrappers, 'finite_checks': rows,
                      'test_log': result.stdout + result.stderr}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', required=True, type=Path)
    parser.add_argument('--chibi', required=True, type=Path)
    args = parser.parse_args()
    run(args.zig.resolve(), args.chibi)

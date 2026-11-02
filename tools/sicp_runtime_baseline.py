#!/usr/bin/env python3
"""Observe all currently catalogued learning experiments in isolated host VMs.

This is a runtime probe, not a grading suite: upstream reference outputs are
unapproved and setup forms may depend on features absent from this runtime.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def zig_string(value):
    return json.dumps(value, ensure_ascii=False)


def probe(zig):
    asset = json.loads((ROOT / 'assets/xy/sicp-learning.json').read_text())
    nodes = {item['id']: item for item in asset['snippets']}
    program = ['const std = @import("std");', 'const scheme = @import("scheme");',
               'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    for i, experiment in enumerate(asset['experiments']):
        program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var host = Host{}; var out: [4096]u8 = undefined;' % i)
        for stage, key in enumerate(experiment['run_order']):
            # Observe each step separately, matching persistent learning sessions.
            code = zig_string(nodes[key]['code'])
            program.append('const r%d = vm.evaluate(%s, &host, &out) catch |err| { std.debug.print("SICP\\t%d\\terror\\t%d\\t{s}\\n", .{@errorName(err)}); return; };' % (stage, code, i, stage))
            if stage + 1 < len(experiment['run_order']):
                program.append('_ = r%d;' % stage)
        program.append('std.debug.print("SICP\\t%d\\tresult\\t%d\\t{s}\\n", .{r%d}); }' % (i, len(experiment['run_order'])-1, len(experiment['run_order'])-1))
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / 'probe.zig'
        path.write_text('\n'.join(program) + '\n')
        cmd = [str(zig), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(path),
               '--dep', 'view_config', '-Mscheme=' + str(ROOT / 'src/xy/scheme_runtime.zig'),
               '-Mview_config=' + str(ROOT / 'src/xy/view_config.zig')]
        result = subprocess.run(cmd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Zig probe failed:\n' + result.stdout + result.stderr)
    found = {}
    for line in (result.stdout + result.stderr).splitlines():
        if 'SICP\t' not in line:
            continue
        fields = line[line.index('SICP\t'):].split('\t', 4)
        if len(fields) != 5:
            raise ValueError('Malformed probe result: ' + line)
        _, index, status, stage, value = fields
        index = int(index)
        if index in found:
            raise ValueError('Duplicate result')
        found[index] = {'id': asset['experiments'][index]['id'], 'status': status,
                        'stage': int(stage), 'value': value,
                        'reference': asset['experiments'][index]['reference']}
    if set(found) != set(range(len(asset['experiments']))):
        raise ValueError('Missing probe results')
    return [found[i] for i in range(len(found))]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps({'scope': 'existing learning catalogue only; not all SICP exercises',
                      'results': probe(args.zig)}, ensure_ascii=False, indent=2))

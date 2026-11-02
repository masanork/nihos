#!/usr/bin/env python3
"""Locate the first Depth site for the recorded failed SICP observations.

Instrumentation is compiled from a temporary copy; the production runtime is
never modified. The input cases are the existing bounded experiment evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/measurements/evidence/2026-11-02-xy-4096-adopt'


def run(zig, depth_limit=24, step_limit=8192, include_all=False, snapshot_heap=False):
    rows = []
    for path in sorted(EVIDENCE.glob('current-*.json')):
        for case in json.loads(path.read_text()).get('cases', []):
            if case.get('status') == 'error' and (include_all or case.get('observed') == 'Depth'):
                rows.append(dict(case, evidence=path.name))
    if len(rows) != (19 if include_all else 17):
        raise ValueError('unexpected baseline error cases')
    runtime = ROOT / 'src/xy/scheme_runtime.zig'
    original = runtime.read_text()
    if not 1 <= depth_limit <= 128:
        raise ValueError('depth limit outside experiment range')
    if not 1 <= step_limit <= 1000000:
        raise ValueError('step limit outside experiment range')
    changed = original.replace('pub const depth_limit = 24;', f'pub const depth_limit = {depth_limit};', 1)
    if changed == original and depth_limit != 24:
        raise ValueError('depth declaration changed')
    if 'pub const step_limit = 8192;' not in changed:
        raise ValueError('step declaration changed')
    changed = changed.replace('pub const step_limit = 8192;', f'pub const step_limit = {step_limit};', 1)
    if snapshot_heap:
        needle = 'if (self.free_cells <= self.cell_reserve) return error.HeapFull;'
        if needle not in changed: raise ValueError('allocator changed')
        changed = changed.replace(needle, 'if (self.free_cells <= self.cell_reserve) { var snapshot = self.*; snapshot.collect(); std.debug.print("HEAP_SNAPSHOT before={d} after_roots_only={d}\\n", .{self.free_cells, snapshot.free_cells}); return error.HeapFull; }', 1)
    with tempfile.TemporaryDirectory(prefix='sicp-depth-sites-') as folder:
        tmp = Path(folder)
        shutil.copytree(ROOT / 'src/xy', tmp / 'xy')
        instrumented = []
        for line_number, line in enumerate(changed.splitlines(keepends=True), 1):
            if 'return error.Depth;' in line:
                line = line.replace('return error.Depth;',
                    '{ std.debug.print("DEPTH_SITE %d\\n", .{}); return error.Depth; }' % line_number)
            instrumented.append(line)
        (tmp / 'xy/scheme_runtime.zig').write_text(''.join(instrumented))
        program = ['const std = @import("std"); const scheme = @import("scheme");',
                   'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
        for i, case in enumerate(rows):
            setup = ''
            if case.get('sequential_setup'):
                setup = '_ = vm.evaluate(%s, &h, &out) catch |e| { std.debug.print("CASE_RESULT %d setup {s}\\n", .{@errorName(e)}); return; };' % (json.dumps(case['setup']), i)
                expression = case['expression']
            else:
                expression = '(begin ' + case['setup'] + ' ' + case['expression'] + ')'
            program.append('test "case_%d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [1024]u8 = undefined; std.debug.print("CASE_START %d\\n", .{}); %s const value = vm.evaluate(%s, &h, &out) catch |e| { std.debug.print("CASE_STEPS %d {d}\\n", .{vm.steps}); std.debug.print("CASE_RESULT %d expression {s}\\n", .{@errorName(e)}); return; }; std.debug.print("CASE_STEPS %d {d}\\n", .{vm.steps}); std.debug.print("CASE_RESULT %d value {s}\\n", .{value}); }' % (i, i, setup, json.dumps(expression), i, i, i, i))
        (tmp / 'cases.zig').write_text('\n'.join(program) + '\n')
        p = subprocess.run([str(zig.resolve()), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(tmp / 'cases.zig'), '--dep', 'view_config', '-Mscheme=' + str(tmp / 'xy/scheme_runtime.zig'), '-Mview_config=' + str(tmp / 'xy/view_config.zig')], capture_output=True, text=True, check=True)
    current = None
    sites = {}
    results = {}
    steps = {}
    snapshots = {}
    for line in (p.stdout + p.stderr).splitlines():
        if 'CASE_START ' in line:
            current = int(line.split('CASE_START ', 1)[1])
        elif line.startswith('DEPTH_SITE '):
            if current is None: raise ValueError('unassociated site')
            sites.setdefault(current, []).append(int(line.split()[1]))
        elif line.startswith('CASE_RESULT '):
            _, i, stage, result = line.split(' ', 3)
            results[int(i)] = (stage, result)
        elif line.startswith('CASE_STEPS '):
            _, i, count = line.split()
            steps[int(i)] = int(count)
        elif line.startswith('HEAP_SNAPSHOT '):
            if current is None: raise ValueError('unassociated snapshot')
            fields = dict(item.split('=', 1) for item in line.split()[1:])
            snapshots[current] = {k: int(v) for k, v in fields.items()}
    if set(results) != set(range(len(rows))): raise ValueError('missing case')
    for i, row in enumerate(rows):
        row['instrumented_stage'], row['instrumented_result'] = results[i]
        row['depth_sites'] = sites.get(i, [])
        row['steps'] = steps.get(i)
        row['heap_snapshot'] = snapshots.get(i)
        if depth_limit == 24 and step_limit == 8192 and (
                row['instrumented_stage'] != row.get('stage', 'expression') or
                row['instrumented_result'] != row['observed']):
            raise ValueError('instrumented baseline differs from recorded case')
        if row['instrumented_result'] == 'Depth' and len(row['depth_sites']) != 1:
            raise ValueError('Depth case lacks a unique origin')
    return {'runtime_sha256': hashlib.sha256(runtime.read_bytes()).hexdigest(),
            'experimental_depth_limit': depth_limit,
            'experimental_step_limit': step_limit,
            'snapshot_heap': snapshot_heap,
            'instrumentation': 'temporary host copy; source line numbers before instrumentation',
            'cases': rows, 'test_log': p.stderr}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', required=True, type=Path)
    parser.add_argument('--depth-limit', type=int, default=24)
    parser.add_argument('--step-limit', type=int, default=8192)
    parser.add_argument('--include-all', action='store_true')
    parser.add_argument('--snapshot-heap', action='store_true')
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.depth_limit, args.step_limit, args.include_all, args.snapshot_heap), indent=2))

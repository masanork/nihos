#!/usr/bin/env python3
"""Differential SICP experiment on temporary runtime copies, never product code."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/measurements/evidence/2026-11-02-xy-vm-final'


def cases():
    result = []
    for path in sorted(EVIDENCE.glob('current-*.json')):
        data = json.loads(path.read_text())
        for row in data.get('cases', []):
            if 'setup' in row and 'observed' in row and 'expression' in row:
                result.append(dict(row, evidence=path.name))
    if len(result) != 342:
        raise ValueError('expected 342 recorded cases')
    return result


def run(zig, quantum, yield_gc, adaptive=False):
    if not 1 <= quantum <= 8192:
        raise ValueError('invalid quantum')
    rows = cases()
    runtime = (ROOT / 'src/xy/scheme_runtime.zig').read_text()
    prototype = (ROOT / 'tools/xy_continuation_poc.zig.inc').read_text()
    integrated = 'const ContinuationState = struct {' in runtime
    groups_before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(EVIDENCE.glob('current-*.json'))}
    field = '    ast_root_frame_count: u8,'
    if runtime.count(field) != 1:
        raise ValueError('runtime field anchor changed')
    with_counter = runtime.replace(field, field + '\n    continuation_probe_count: u32,', 1)
    anchor = '        var binding_reclaim_at: u16 = 96;\n        while (true) {\n            try self.tick(depth);'
    inserted = '''        var binding_reclaim_at: u16 = 96;
        while (true) {
            // Experimental host-only admission after each global tail step.
            if (depth == 0 and cur_env == self.global and owned_frame == 0 and self.ast_root_frame_count == 0 and self.eval_sp == 0 and self.call_sp == 0 and self.cell_reserve == 0) {
                var admission = ContinuationAdmission{};
                if (admission.expression(self, cur_r, 0)) {
                    self.continuation_probe_count += 1;
                    var state = ContinuationProbe{ .expression = cur_r, .environment = cur_env };
                    while (!try state.run(self, host, PROBE_QUANTUM, false)) { PROBE_YIELD_GC }
                    return state.value;
                }
            }
            try self.tick(depth);'''
    if adaptive and not yield_gc:
        raise ValueError('adaptive collection requires yield GC')
    if adaptive:
        inserted = inserted.replace('var state = ContinuationProbe{ .expression = cur_r, .environment = cur_env };', 'var state = ContinuationProbe{ .expression = cur_r, .environment = cur_env };\n                    var probe_reclaim_at: u16 = 512;')
        gc = 'if (self.free_cells <= probe_reclaim_at) { self.collect(); probe_reclaim_at = if (self.free_cells > 512) 512 else self.free_cells / 2; }'
    else:
        gc = 'self.collect();' if yield_gc else ''
    if integrated:
        inserted = inserted.replace('ContinuationProbe{', 'ContinuationState{')
        # Drive the same stop-the-mutator collector used by the integrated
        # lease; this host differential does not model scheduler timing.
        gc = gc.replace('self.collect();', 'var cursor = Runtime.SliceCursor{}; while (!self.collectSlice(&cursor, 0, 0, 64)) {}')
    inserted = inserted.replace('PROBE_QUANTUM', str(quantum)).replace('PROBE_YIELD_GC', gc)
    if with_counter.count(anchor) != 1:
        raise ValueError('evaluator anchor changed')
    candidate = with_counter.replace(anchor, inserted, 1) + ('' if integrated else '\n' + prototype)
    code = ['const std = @import("std"); const scheme = @import("scheme");',
            'const Host = struct { pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void { return error.EditorFailure; } };']
    for index, row in enumerate(rows):
        if row.get('sequential_setup'):
            setup = '_ = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("OBS\\t%d\\tsetup\\t{s}\\t{d}\\n", .{@errorName(err), vm.continuation_probe_count}); return; };' % (json.dumps(row['setup']), index)
            source = row['expression']
        else:
            setup = ''
            source = '(begin ' + row['setup'] + ' ' + row['expression'] + ')'
        code.append('test "case_%03d" { var vm: scheme.Runtime = undefined; vm.initInPlace(); var h = Host{}; var out: [1024]u8 = undefined; %s const value = vm.evaluate(%s, &h, &out) catch |err| { std.debug.print("OBS\\t%d\\terror\\t{s}\\t{d}\\n", .{@errorName(err), vm.continuation_probe_count}); return; }; std.debug.print("OBS\\t%d\\tvalue\\t{s}\\t{d}\\n", .{value, vm.continuation_probe_count}); }' % (index, setup, json.dumps(source), index, index))
    observations = {}
    with tempfile.TemporaryDirectory(prefix='xy-continuation-sicp-') as folder:
        tmp = Path(folder)
        shutil.copytree(ROOT / 'src/xy', tmp / 'xy')
        case_file = tmp / 'cases.zig'
        case_file.write_text('\n'.join(code) + '\n')
        for name, source in [('baseline', with_counter), ('candidate', candidate)]:
            (tmp / 'xy/scheme_runtime.zig').write_text(source)
            cmd = [str(zig.resolve()), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(case_file), '--dep', 'view_config', '-Mscheme=' + str(tmp / 'xy/scheme_runtime.zig'), '-Mview_config=' + str(tmp / 'xy/view_config.zig')]
            proc = subprocess.run(cmd, text=True, capture_output=True)
            if proc.returncode:
                raise RuntimeError(name + ' failed: ' + proc.stderr[-5000:])
            found = {}
            for line in (proc.stdout + proc.stderr).splitlines():
                if 'OBS\t' not in line: continue
                fields = line[line.index('OBS\t'):].split('\t')
                if len(fields) != 5: raise ValueError('malformed observation')
                _, idx, kind, value, count = fields
                idx = int(idx)
                if idx in found: raise ValueError('duplicate observation')
                found[idx] = {'kind': kind, 'value': value, 'admissions': int(count)}
            if len(found) != len(rows): raise ValueError('missing observation')
            observations[name] = found
    changes = []
    admitted = 0
    statuses = Counter()
    details = []
    for i, row in enumerate(rows):
        before = observations['baseline'][i]
        after = observations['candidate'][i]
        expected_kind = 'setup' if row.get('stage') == 'setup' else ('error' if row['status'] == 'error' or row.get('expected_error') else 'value')
        if before['kind'] != expected_kind or before['value'] != row['observed']:
            raise ValueError(f'recorded baseline differs at {i}: {before}, {row}')
        if after['admissions']:
            admitted += 1
        matches = (after['kind'] == 'error' and after['value'] == row['expected_error']) if row.get('expected_error') else (after['kind'] == 'value' and after['value'] == row['expected'])
        statuses['matched' if matches else after['kind']] += 1
        details.append({'index': i, 'exercise': row['exercise'], 'source': row['expression'], 'expected': row['expected'], 'baseline': before, 'candidate': after, 'evidence': row['evidence']})
        if (before['kind'], before['value']) != (after['kind'], after['value']):
            changes.append({'index': i, 'exercise': row['exercise'], 'source': row['expression'], 'expected': row['expected'], 'baseline': before, 'candidate': after, 'evidence': row['evidence']})
    if (ROOT / 'src/xy/scheme_runtime.zig').read_text() != runtime or (ROOT / 'tools/xy_continuation_poc.zig.inc').read_text() != prototype:
        raise ValueError('runtime or prototype changed during experiment')
    groups_after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(EVIDENCE.glob('current-*.json'))}
    if groups_before != groups_after:
        raise ValueError('SICP evidence changed during experiment')
    return {'runtime_sha256': hashlib.sha256(runtime.encode()).hexdigest(), 'prototype_sha256': None if integrated else hashlib.sha256(prototype.encode()).hexdigest(), 'integrated': integrated, 'group_sha256': groups_before, 'scope': 'host-only temporary instrumentation; selected finite cases; no PSRAM or UI', 'quantum': quantum, 'gc_on_yield': yield_gc, 'adaptive': adaptive, 'cases': len(rows), 'admitted_cases': admitted, 'candidate_status': dict(statuses), 'changes': changes, 'observations': details}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    parser.add_argument('--quantum', type=int, default=128)
    parser.add_argument('--no-yield-gc', action='store_true')
    parser.add_argument('--adaptive', action='store_true')
    args = parser.parse_args()
    print(json.dumps(run(args.zig, args.quantum, not args.no_yield_gc, args.adaptive), indent=2))

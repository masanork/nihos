#!/usr/bin/env python3
"""Diagnose the eight-queens native-apply GC barrier in a temporary host copy."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('unexpected source for ' + old)
    return source.replace(old, new, 1)


def run(zig):
    source_path = ROOT / 'src/xy/scheme_runtime.zig'
    source = source_path.read_text()
    cases = json.loads((ROOT / 'docs/measurements/evidence/2026-11-02-xy-operand-roots/current-sicp_sequences_2_33_2_42.json').read_text())['cases']
    case = next(x for x in cases if x['exercise'] == '2.42' and x['expression'] == '(length (queens 8))')
    capacity = re.search(r'pub const ast_root_frame_capacity = [0-9]+;', source)
    if capacity is None:
        raise ValueError('root frame capacity declaration missing')
    source = replace_once(source, capacity.group(0), 'pub const ast_root_frame_capacity = 128;')
    source = replace_once(source, 'pub const depth_limit = 24;', 'pub const depth_limit = 64;')
    source = replace_once(source, 'pub const step_limit = 8192;', 'pub const step_limit = 32768;')
    source = replace_once(source, '    ast_root_frame_count: u8,', '    ast_root_frame_count: u8,\n    gc_apply_depth: u8,\n    pub_test_gc_blocked: u32,\n    pub_test_gc_runs: u32,')
    needle = '        if (depth == 0 and self.running and self.cell_reserve == 0 and self.eval_sp == 0 and self.call_sp == 0 and self.free_cells <= reclaim_at.*) {'
    replacement = '''        if (depth > 0 and self.gc_apply_depth > 0 and self.free_cells <= reclaim_at.*) self.pub_test_gc_blocked += 1;
        if ((depth == 0 or (self.ast_root_frame_count != 0 and self.gc_apply_depth == 0)) and self.running and self.cell_reserve == 0 and self.eval_sp == 0 and self.call_sp == 0 and self.free_cells <= reclaim_at.*) {
            if (depth > 0) self.pub_test_gc_runs += 1;'''
    source = replace_once(source, needle, replacement)
    needle = '    fn apply(self: *Runtime, procedure: Ref, args: []const Ref, depth: usize, host: anytype) linksection(code_section) Error!Ref {'
    source = replace_once(source, needle, needle + '\n        self.gc_apply_depth += 1;\n        defer self.gc_apply_depth -= 1;')
    with tempfile.TemporaryDirectory(prefix='sicp-nested-gc-block-') as folder:
        tmp = Path(folder)
        shutil.copytree(ROOT / 'src/xy', tmp / 'xy')
        (tmp / 'xy/scheme_runtime.zig').write_text(source)
        expression = '(begin ' + case['setup'] + ' ' + case['expression'] + ')'
        code = '''const std=@import("std"); const scheme=@import("scheme");
const Host=struct { pub fn schemeCall(_: *@This(), _:scheme.EditorOp, _:[]const u8, _:i32) scheme.Error!void {return error.EditorFailure;} };
test "queens" {var vm:scheme.Runtime=undefined; vm.initInPlace(); var h=Host{}; var out:[1024]u8=undefined;
const got=vm.evaluate(%s, &h, &out) catch |e| {std.debug.print("RESULT {s} {d} {d} {d}\\n", .{@errorName(e),vm.steps,vm.pub_test_gc_blocked,vm.pub_test_gc_runs});return;};
std.debug.print("RESULT {s} {d} {d} {d}\\n", .{got,vm.steps,vm.pub_test_gc_blocked,vm.pub_test_gc_runs});}
''' % json.dumps(expression)
        (tmp / 'case.zig').write_text(code)
        cmd = [str(zig.resolve()), 'test', '-O', 'ReleaseSafe', '--dep', 'scheme', '-Mroot=' + str(tmp / 'case.zig'), '--dep', 'view_config', '-Mscheme=' + str(tmp / 'xy/scheme_runtime.zig'), '-Mview_config=' + str(tmp / 'xy/view_config.zig')]
        p = subprocess.run(cmd, text=True, capture_output=True, check=True)
    line = next(x for x in (p.stdout + p.stderr).splitlines() if 'RESULT ' in x)
    _, result, steps, blocked, collections = line[line.index('RESULT '):].split()
    return {'runtime_sha256': hashlib.sha256(source_path.read_bytes()).hexdigest(),
            'scope': 'host only; temporary nested-GC experiment with raised limits',
            'exercise': case['exercise'], 'expression': case['expression'], 'expected': case['expected'],
            'observed': result, 'steps': int(steps), 'blocked_boundaries': int(blocked),
            'nested_collections': int(collections), 'test_log': p.stderr}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.zig), indent=2))

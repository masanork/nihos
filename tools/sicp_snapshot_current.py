#!/usr/bin/env python3
"""Re-run recorded SICP host groups into a separate evidence directory."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'docs/measurements/evidence/2026-11-02-xy-native-roots'


def run(zig, chibi, output, workers):
    runtime = ROOT / 'src/xy/scheme_runtime.zig'
    before = hashlib.sha256(runtime.read_bytes()).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(BASELINE / 'mit-exercise-index.json', output / 'mit-exercise-index.json')
    scripts = sorted(path.name[8:-5] for path in BASELINE.glob('current-*.json'))
    if len(scripts) != 21:
        raise ValueError('expected 21 recorded SICP groups')
    scripts.extend(('sicp_recursive_bindings_4_8_4_20',
                    'sicp_symbolic_deriv_2_57', 'sicp_set_trees_2_63_2_64',
                    'sicp_huffman_2_67', 'sicp_huffman_2_68',
                    'sicp_huffman_2_69_2_70'))
    def group(name):
        result = subprocess.run([sys.executable, str(ROOT / 'tools' / (name + '.py')), '--zig', str(zig.resolve()), '--chibi', str(chibi.resolve())], cwd=ROOT, text=True, capture_output=True)
        (output / (name + '.log')).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f'{name}: exit {result.returncode}; see log')
        parsed = json.loads(result.stdout)
        (output / ('current-' + name + '.json')).write_text(json.dumps(parsed, indent=2, ensure_ascii=False) + '\n')
        print(name + ' complete', flush=True)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(group, name) for name in scripts]
        for future in as_completed(futures):
            future.result()
    report = subprocess.run([sys.executable, str(ROOT / 'tools/sicp_coverage_report.py'), '--evidence', str(output)], cwd=ROOT, text=True, capture_output=True, check=True)
    coverage = json.loads(report.stdout)
    (output / 'coverage.json').write_text(json.dumps(coverage, indent=2, ensure_ascii=False) + '\n')
    digest = hashlib.sha256(runtime.read_bytes()).hexdigest()
    if digest != before:
        raise RuntimeError('runtime changed while the SICP snapshot was running')
    (output / 'snapshot.json').write_text(json.dumps({'runtime_sha256': digest, 'groups': scripts, 'scope': 'host only; selected finite observations'}, indent=2) + '\n')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--zig', type=Path, required=True)
    p.add_argument('--chibi', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--workers', type=int, default=3, choices=range(1, 5))
    a = p.parse_args()
    run(a.zig, a.chibi, a.output, a.workers)

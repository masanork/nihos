#!/usr/bin/env python3
"""Compare all 21 re-run SICP JSON groups and coverage totals."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('before', type=Path)
p.add_argument('after', type=Path)
a = p.parse_args()
left = {p.name: p for p in a.before.glob('current-*.json')}
right = {p.name: p for p in a.after.glob('current-*.json')}
if set(left) != set(right) or len(left) != 21:
    raise ValueError('SICP group inventory mismatch')
changed = [name for name in sorted(left) if json.loads(left[name].read_text()) != json.loads(right[name].read_text())]
before = json.loads((a.before / 'coverage.json').read_text())
after = json.loads((a.after / 'coverage.json').read_text())
summary = {'groups': len(left), 'changed_groups': changed, 'coverage_before': before['totals'], 'coverage_after': after['totals'], 'chapters_after': after['by_chapter'], 'before_runtime_sha256': json.loads((a.before / 'snapshot.json').read_text())['runtime_sha256'], 'after_runtime_sha256': json.loads((a.after / 'snapshot.json').read_text())['runtime_sha256'], 'scope': 'host-only selected finite observations; compares complete parsed JSON in each group'}
print(json.dumps(summary, indent=2))
if changed or summary['coverage_before'] != summary['coverage_after']:
    raise SystemExit(1)

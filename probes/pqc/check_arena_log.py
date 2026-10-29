#!/usr/bin/env python3
"""Check preemptible ML-DSA fixture evidence, not cryptographic conformance."""
import re
import sys
from pathlib import Path

FIELDS = ('status', 'cycles', 'verify_ticks', 'verify_worker0', 'verify_worker1', 'heap_before', 'heap_after', 'charged', 'lease', 'peak',
          'allocs', 'frees', 'failures', 'valid', 'rejected', 'oom', 'live',
          'stack_used', 'stack_painted', 'erased', 'released', 'mie')

def check(path, mode):
    text = Path(path).read_text(errors='replace')
    pattern = r'^NIHOS_NATIVE_PQC_ARENA' + ''.join(' ' + n + r'=([0-9a-f]{8})' for n in FIELDS) + r'\r?$'
    rows = re.findall(pattern, text, re.M)
    if len(rows) != 1 or 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('missing/duplicate fixture record or native failure')
    r = dict(zip(FIELDS, (int(v, 16) for v in rows[0])))
    if mode == '4M':
        if not (r['status'] == 1 and r['lease'] == 16304 and r['charged'] == 16384 and
                r['heap_before'] - r['heap_after'] == r['charged'] and 0 < r['peak'] <= r['lease'] and
                r['allocs'] == r['frees'] > 0 and r['failures'] > 0 and r['live'] == 0 and
                all(r[k] == 1 for k in ('valid', 'rejected', 'oom', 'erased', 'released')) and
                r['mie'] == 8 and 0 < r['stack_used'] < 8192 - 16 and
                0x4ff60010 < r['stack_painted'] < 0x4ff62000 and
                all(r[k] > 0 for k in ('verify_ticks', 'verify_worker0', 'verify_worker1'))):
            raise ValueError(f'incomplete fixture evidence: {r}')
    elif mode == '0':
        if r['status'] != 2 or any(r[k] for k in ('heap_before', 'heap_after', 'charged', 'lease', 'peak', 'valid', 'rejected', 'oom', 'released', 'mie')):
            raise ValueError(f'invalid no-PSRAM result: {r}')
    else:
        raise ValueError('mode must be 4M or 0')
    return r

if __name__ == '__main__':
    if len(sys.argv) != 3: raise SystemExit('usage: check_arena_log.py LOG 4M|0')
    print(check(sys.argv[1], sys.argv[2]))

#!/usr/bin/env python3
"""Validate the single experimental ML-DSA fixture record in an emulator log."""
import re
import sys
from pathlib import Path

FIELDS = ('status', 'cycles', 'masked_cycles', 'ticks0', 'ticks1', 'lease', 'stack_used', 'guard', 'erased', 'released', 'masked')

def check(path, mode):
    text = Path(path).read_text(errors='replace')
    pattern = r'^NIHOS_NATIVE_PQC_VERIFY' + ''.join(' ' + name + r'=([0-9a-f]{8})' for name in FIELDS) + r'\r?$'
    matches = re.findall(pattern, text, re.M)
    if len(matches) != 1 or 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('missing/duplicate report or native failure')
    r = dict(zip(FIELDS, (int(v, 16) for v in matches[0])))
    if mode == '4M':
        if not (r['status'] == 1 and r['lease'] == 32768 and 0 < r['stack_used'] < 32768 - 256 and
                r['cycles'] >= r['masked_cycles'] > 0 and r['guard'] == r['erased'] == r['released'] == r['masked'] == 1):
            raise ValueError(f'invalid fixture result: {r}')
    elif mode == '0':
        if r['status'] != 2 or any(r[k] for k in ('lease', 'stack_used', 'masked_cycles', 'guard', 'erased', 'released', 'masked')):
            raise ValueError(f'invalid unavailable result: {r}')
    else:
        raise ValueError('mode must be 4M or 0')
    return r

if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: check_native_log.py LOG 4M|0')
    print(check(sys.argv[1], sys.argv[2]))

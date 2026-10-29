#!/usr/bin/env python3
"""Validate a native cleanup failure or correct-owner control trace."""
import hashlib
import json
from pathlib import Path
import re
import sys

import check_worker_log as worker

PRE = ('mode', 'identity', 'owned', 'pending', 'charged', 'free', 'initial_free')
CONTROL = ('cleaned', 'reaped', 'free')


def check(log, elf, image, audit, mode):
    data, binary = Path(elf).read_bytes(), Path(image).read_bytes()
    a = json.loads(Path(audit).read_text())
    if hashlib.sha256(data).hexdigest() != a['elf_sha256'] or hashlib.sha256(binary).hexdigest() != a['image_sha256']:
        raise ValueError('ELF/image does not match audit')
    base, size = worker.stack_symbol(data)
    bss = [s for s in a['sections'] if s['name'] == '.bss']
    if len(bss) != 1 or not int(bss[0]['address'], 16) <= base < base + size <= int(bss[0]['address'], 16) + bss[0]['bytes']:
        raise ValueError('worker stack outside audited BSS')
    text = Path(log).read_text(errors='replace')
    lines = text.splitlines()
    pre = worker.record(text, 'NIHOS_NATIVE_PQC_DRAIN_PRE', PRE)
    if not (mode in ('failure', 'control') and pre['mode'] == (1 if mode == 'failure' else 2) and pre['identity'] == 0x10001 and pre['owned'] == pre['pending'] == 1 and pre['charged'] == 16384 and pre['free'] > 0 and pre['initial_free'] - pre['free'] == pre['charged']):
        raise ValueError('drain setup is incomplete')
    if not any(re.fullmatch(r'\[INFO  esp_emu\] Timeout reached after 4\.\d+s', line) for line in lines):
        raise ValueError('missing bounded observation timeout')
    failures = [line for line in lines if line.startswith('NIHOS_NATIVE_FAIL')]
    if mode == 'failure':
        if failures != ['NIHOS_NATIVE_FAIL task invariant'] or 'NIHOS_NATIVE_PQC_DRAIN_CONTROL' in text or 'NIHOS_NATIVE_PQC_DRAIN_DONE' in text or text.index(failures[0]) < text.index('NIHOS_NATIVE_PQC_DRAIN_PRE'):
            raise ValueError('expected fail-stop missing or control appeared')
    else:
        control = worker.record(text, 'NIHOS_NATIVE_PQC_DRAIN_CONTROL', CONTROL)
        done = [line for line in lines if line.startswith('NIHOS_NATIVE_PQC_DRAIN_DONE ')]
        if failures or control != {'cleaned': 1, 'reaped': 1, 'free': pre['initial_free']} or done != ['NIHOS_NATIVE_PQC_DRAIN_DONE complete=00000001'] or not text.index('NIHOS_NATIVE_PQC_DRAIN_PRE') < text.index('NIHOS_NATIVE_PQC_DRAIN_CONTROL') < text.index('NIHOS_NATIVE_PQC_DRAIN_DONE'):
            raise ValueError('correct-owner cleanup did not complete')
    return {'mode': mode, 'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'stack_start': hex(base), 'stack_bytes': size, 'pre': pre}


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_drain_log.py LOG ELF BIN AUDIT failure|control OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Drain trace validated: ' + result['mode'])

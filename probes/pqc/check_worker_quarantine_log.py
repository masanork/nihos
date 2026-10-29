#!/usr/bin/env python3
"""Validate the injected native ledger drain failure against the audited image."""
import hashlib
import json
from pathlib import Path
import sys

import check_worker_log as worker

FIELDS = ('identity', 'verify_valid', 'lease', 'charged', 'peak', 'stack_used', 'free_before', 'free_after', 'wrong_owner', 'retained', 'uncleaned', 'reopen_blocked', 'heap_unchanged', 'reap_blocked', 'restart_blocked')


def check(log, elf, image, audit):
    data, binary = Path(elf).read_bytes(), Path(image).read_bytes()
    a = json.loads(Path(audit).read_text())
    if hashlib.sha256(data).hexdigest() != a['elf_sha256'] or hashlib.sha256(binary).hexdigest() != a['image_sha256']:
        raise ValueError('ELF/image does not match audit')
    base, size = worker.stack_symbol(data)
    bss = [s for s in a['sections'] if s['name'] == '.bss']
    if len(bss) != 1 or not int(bss[0]['address'], 16) <= base < base + size <= int(bss[0]['address'], 16) + bss[0]['bytes']:
        raise ValueError('worker stack outside audited BSS')
    text = Path(log).read_text(errors='replace')
    if 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('native failure')
    result = worker.record(text, 'NIHOS_NATIVE_PQC_QUARANTINE_PASS', FIELDS)
    done = [line for line in text.splitlines() if line.startswith('NIHOS_NATIVE_PQC_QUARANTINE_DONE ')]
    if done != ['NIHOS_NATIVE_PQC_QUARANTINE_DONE complete=00000001'] or text.index('NIHOS_NATIVE_PQC_QUARANTINE_DONE') < text.index('NIHOS_NATIVE_PQC_QUARANTINE_PASS'):
        raise ValueError('incomplete or out of order')
    flags = ('verify_valid', 'wrong_owner', 'retained', 'uncleaned', 'reopen_blocked', 'heap_unchanged', 'reap_blocked', 'restart_blocked')
    if not (result['identity'] == 0x10001 and all(result[k] == 1 for k in flags) and
            result['lease'] == 16304 and result['charged'] == 16384 and 0 < result['peak'] <= result['lease'] and
            0 < result['stack_used'] < size - 16 and result['free_before'] > 0 and result['free_before'] == result['free_after']):
        raise ValueError('failure did not retain ownership and block reuse')
    return {'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'stack_start': hex(base), 'stack_bytes': size, 'quarantine': result}


if __name__ == '__main__':
    if len(sys.argv) != 6:
        raise SystemExit('usage: check_worker_quarantine_log.py LOG ELF BIN AUDIT OUTPUT.json')
    result = check(*sys.argv[1:5])
    Path(sys.argv[5]).write_text(json.dumps(result, indent=2) + '\n')
    print('Injected drain failure and blocked reuse validated')

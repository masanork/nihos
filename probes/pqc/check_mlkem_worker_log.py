#!/usr/bin/env python3
"""Validate deterministic ML-KEM worker evidence against its audited image."""
import hashlib
import json
from pathlib import Path
import sys

import check_worker_log as worker

KEM = ('status', 'key_ok', 'enc_ok', 'dec_ok', 'implicit_ok', 'oom_ok', 'key_peak', 'enc_peak', 'dec_peak', 'allocs', 'frees', 'oom_error', 'live', 'uncleared', 'ticks', 'foreground0', 'foreground1')
MEMORY = ('before', 'after_arena', 'after_both', 'after_release', 'arena', 'io', 'charged', 'stack_used', 'stack_painted', 'erased', 'released', 'mie')
OWNER = ('captures', 'terminated', 'cleaned', 'reaped')


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
    if 'NIHOS_NATIVE_FAIL' in text: raise ValueError('native failure')
    k = worker.record(text, 'NIHOS_NATIVE_MLKEM_WORKER', KEM)
    m = worker.record(text, 'NIHOS_NATIVE_MLKEM_MEMORY', MEMORY)
    o = worker.record(text, 'NIHOS_NATIVE_MLKEM_OWNER', OWNER)
    if not (o['captures'] > 0 and all(o[x] == 1 for x in ('terminated', 'cleaned', 'reaped'))):
        raise ValueError('worker not retired')
    if mode == '4M':
        if not (k['status'] == 1 and all(k[x] == 1 for x in ('key_ok', 'enc_ok', 'dec_ok', 'implicit_ok', 'oom_ok')) and
                all(0 < k[x] <= m['arena'] for x in ('key_peak', 'enc_peak', 'dec_peak')) and k['dec_peak'] > 16304 and
                k['allocs'] == k['frees'] > 0 and k['oom_error'] == 1 and k['live'] == k['uncleared'] == 0 and
                k['ticks'] > 0 and k['foreground0'] > 0 and k['foreground1'] > 0 and o['captures'] >= 2 and
                m['arena'] == 32688 and m['io'] == 6144 and m['charged'] == 40960 and
                m['before'] - m['after_arena'] == 32768 and m['after_arena'] - m['after_both'] == 8192 and
                m['after_release'] == m['before'] and 0 < m['stack_used'] < size - 16 and base + 16 < m['stack_painted'] < base + size and
                m['erased'] == m['released'] == 1 and m['mie'] == 8):
            raise ValueError('ML-KEM execution or memory evidence incomplete')
    elif mode == '0':
        if k['status'] != 2 or any(k[x] for x in KEM if x != 'status') or any(m.values()):
            raise ValueError('unexpected no-PSRAM outcome')
    else:
        raise ValueError('mode must be 4M or 0')
    return {'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'stack_start': hex(base), 'stack_bytes': size, 'worker': k, 'memory': m, 'owner': o}


if __name__ == '__main__':
    if len(sys.argv) != 7: raise SystemExit('usage: check_mlkem_worker_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('ML-KEM worker validated')

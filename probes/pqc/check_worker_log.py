#!/usr/bin/env python3
"""Validate worker fixture against its exact audited ELF/image and stack symbol."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

FIELDS = ('status', 'verify_ticks', 'verify_worker0', 'verify_worker1', 'lease', 'charged', 'peak', 'allocs', 'frees', 'failures', 'valid', 'rejected', 'oom', 'live', 'stack_used', 'stack_painted', 'erased', 'released', 'mie')
OWNER = ('captures', 'foreground', 'terminated', 'cleaned', 'reaped')

def record(text, marker, fields):
    pattern = '^' + marker + ''.join(' ' + n + r'=([0-9a-f]{8})' for n in fields) + r'\r?$'
    rows = re.findall(pattern, text, re.M)
    if len(rows) != 1:
        raise ValueError('missing or duplicated ' + marker)
    return dict(zip(fields, (int(v, 16) for v in rows[0])))

def stack_symbol(data):
    if data[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('expected ELF32')
    h = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    sections = [struct.unpack_from('<10I', data, h[5] + i * h[10]) for i in range(h[11])]
    hits = []
    for section in sections:
        if section[1] != 2:
            continue
        strings = sections[section[6]]
        table = data[strings[4]:strings[4] + strings[5]]
        for pos in range(section[4], section[4] + section[5], 16):
            name, value, size, info, _, index = struct.unpack_from('<IIIBBH', data, pos)
            if name and table[name:table.index(0, name)] == b'native_tasks.pqc_worker_stack':
                if info & 15 != 1 or index == 0: raise ValueError('invalid worker symbol')
                hits.append((value, size))
    if len(hits) != 1 or hits[0][1] != 8192 or hits[0][0] % 64:
        raise ValueError('missing or invalid worker stack')
    return hits[0]

def check(log, elf, image, audit, mode):
    data, binary = Path(elf).read_bytes(), Path(image).read_bytes()
    a = json.loads(Path(audit).read_text())
    if hashlib.sha256(data).hexdigest() != a['elf_sha256'] or hashlib.sha256(binary).hexdigest() != a['image_sha256']:
        raise ValueError('ELF/image does not match audit')
    base, size = stack_symbol(data)
    bss = [s for s in a['sections'] if s['name'] == '.bss']
    if len(bss) != 1 or not int(bss[0]['address'], 16) <= base < base + size <= int(bss[0]['address'], 16) + bss[0]['bytes']:
        raise ValueError('worker stack is not within audited SRAM BSS')
    text = Path(log).read_text(errors='replace')
    if 'NIHOS_NATIVE_FAIL' in text: raise ValueError('native failure')
    r = record(text, 'NIHOS_NATIVE_PQC_WORKER', FIELDS)
    o = record(text, 'NIHOS_NATIVE_PQC_WORKER_OWNER', OWNER)
    if not (o['captures'] > 0 and o['foreground'] > 0 and o['terminated'] == o['cleaned'] == o['reaped'] == 1):
        raise ValueError('worker ownership not retired')
    if mode == '4M':
        if not (r['status'] == 1 and r['verify_ticks'] > 0 and r['verify_worker0'] > 0 and r['verify_worker1'] > 0 and
                r['lease'] == 16304 and r['charged'] == 16384 and 0 < r['peak'] <= r['lease'] and
                r['allocs'] == r['frees'] > 0 and r['failures'] > 0 and r['live'] == 0 and
                all(r[k] == 1 for k in ('valid', 'rejected', 'oom', 'erased', 'released')) and
                r['mie'] == 8 and 0 < r['stack_used'] < size - 16 and
                base + 16 < r['stack_painted'] < base + size and o['captures'] >= 2):
            raise ValueError('worker crypto or preemption evidence incomplete')
    elif mode == '0':
        if r['status'] != 2 or any(r[k] for k in ('lease', 'charged', 'peak', 'valid', 'rejected', 'oom', 'stack_used', 'erased', 'released', 'mie')):
            raise ValueError('invalid no-PSRAM outcome')
    else: raise ValueError('mode must be 4M or 0')
    return {'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'stack_start': hex(base), 'stack_bytes': size, 'worker': r, 'owner': o}

if __name__ == '__main__':
    if len(sys.argv) != 7: raise SystemExit('usage: check_worker_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))

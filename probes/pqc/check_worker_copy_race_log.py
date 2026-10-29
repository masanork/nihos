#!/usr/bin/env python3
"""Check single-hart cooperative mid-copy mutation and unchanged control."""
import hashlib
import json
from pathlib import Path
import sys

import check_worker_log as worker
import check_worker_snapshot_log as snapshot
import check_worker_mutation_log as mutation

RACE = ('mode', 'version', 'ack', 'rejected', 'verified')
SOURCE = tuple('paused' if field == 'copied' else field for field in mutation.FIELDS)


def check(log, elf, image, audit, mode):
    if mode not in ('change', 'control', 'absent'):
        raise ValueError('mode must be change, control or absent')
    text = Path(log).read_text(errors='replace')
    if 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('native failure')
    a = json.loads(Path(audit).read_text())
    data, binary = Path(elf).read_bytes(), Path(image).read_bytes()
    if hashlib.sha256(data).hexdigest() != a['elf_sha256'] or hashlib.sha256(binary).hexdigest() != a['image_sha256']:
        raise ValueError('ELF/image does not match audit')
    base, size = worker.stack_symbol(data)
    bss = [s for s in a['sections'] if s['name'] == '.bss']
    if len(bss) != 1 or not int(bss[0]['address'], 16) <= base < base + size <= int(bss[0]['address'], 16) + bss[0]['bytes']:
        raise ValueError('stack outside audited BSS')
    src = worker.record(text, 'NIHOS_NATIVE_PQC_RACE_SOURCE', SOURCE)
    race = worker.record(text, 'NIHOS_NATIVE_PQC_COPY_RACE', RACE)
    snap = worker.record(text, 'NIHOS_NATIVE_PQC_SNAPSHOT', snapshot.FIELDS)
    r = worker.record(text, 'NIHOS_NATIVE_PQC_WORKER', worker.FIELDS)
    own = worker.record(text, 'NIHOS_NATIVE_PQC_WORKER_OWNER', worker.OWNER)
    if own['captures'] < 1 or own['foreground'] < 1 or not all(own[k] == 1 for k in ('terminated', 'cleaned', 'reaped')):
        raise ValueError('worker not retired')
    if mode == 'absent':
        if race != {'mode': 1, 'version': 0, 'ack': 0, 'rejected': 0, 'verified': 0}:
            raise ValueError('unexpected no-PSRAM race')
        result = snapshot.check(log, elf, image, audit, '0')
        if src['status'] != 2 or any(src[k] for k in SOURCE if k != 'status'):
            raise ValueError('unexpected source allocation')
    else:
        expected = {'mode': 1, 'version': 2, 'ack': 1, 'rejected': 1, 'verified': 0} if mode == 'change' else {'mode': 2, 'version': 0, 'ack': 1, 'rejected': 0, 'verified': 1}
        if race != expected:
            raise ValueError('sequence decision incorrect')
        if not (src['status'] == 1 and src['payload'] == 9612 and src['charged'] == 16384 and src['simultaneous'] == 49152 and src['before'] - src['after_alloc'] == 16384 and src['after_alloc'] == snap['before'] and src['before'] - snap['after_both'] == 49152 and src['after_release'] == src['before'] and src['paused'] == src['erased'] == src['released'] == 1 and src['mutated'] == (1 if mode == 'change' else 0)):
            raise ValueError('source accounting or release incorrect')
        if mode == 'control':
            result = snapshot.check(log, elf, image, audit, '4M')
        else:
            if not (snap['status'] == 5 and snap['payload'] == 9612 and snap['charged'] == 16384 and snap['combined'] == 32768 and snap['before'] - snap['after_snapshot'] == 16384 and snap['before'] - snap['after_both'] == 32768 and snap['after_release'] == snap['before'] and snap['erased'] == snap['released'] == 1 and r['status'] == 5 and r['lease'] == 16304 and r['charged'] == 16384 and all(r[k] == 0 for k in ('valid', 'rejected', 'oom', 'allocs', 'frees', 'peak', 'live', 'verify_ticks', 'verify_worker0', 'verify_worker1')) and r['erased'] == r['released'] == 1 and r['mie'] == 8 and 0 < r['stack_used'] < size - 16):
                raise ValueError('changed snapshot was verified or cleanup failed')
            result = {'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'worker': r, 'owner': own, 'snapshot': snap}
    result['race'] = race
    result['source'] = src
    return result


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_copy_race_log.py LOG ELF BIN AUDIT change|control|absent OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Cooperative copy race validated')

#!/usr/bin/env python3
"""Check repeated snapshot jobs with a real ledger-full second job."""
import json
from pathlib import Path
import sys
import tempfile

import check_worker_log as worker
import check_worker_repeat_log as repeat
import check_worker_snapshot_log as snapshot

PRESSURE = ('active', 'charged', 'arena_error', 'released')


def check(log, elf, image, audit, mode):
    text = Path(log).read_text(errors='replace')
    if 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('native failure')
    prefixes = ('NIHOS_NATIVE_PQC_PRESSURE ', 'NIHOS_NATIVE_PQC_SNAPSHOT ', 'NIHOS_NATIVE_PQC_WORKER ', 'NIHOS_NATIVE_PQC_WORKER_OWNER ', 'NIHOS_NATIVE_PQC_WORKER_JOB ', 'NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS ')
    lines = [line for line in text.splitlines() if line.startswith(prefixes)]
    if len(lines) != 16 or lines[-1] != 'NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS jobs=00000003':
        raise ValueError('incomplete sequence')
    if mode not in ('4M', '0'):
        raise ValueError('mode must be 4M or 0')
    previous, jobs = 0, []
    for i in range(3):
        chunk = lines[5*i:5*i+5]
        p = worker.record(chunk[0], 'NIHOS_NATIVE_PQC_PRESSURE', PRESSURE)
        snap = worker.record(chunk[1], 'NIHOS_NATIVE_PQC_SNAPSHOT', snapshot.FIELDS)
        job = worker.record(chunk[4], 'NIHOS_NATIVE_PQC_WORKER_JOB', repeat.JOB)
        identity = job['identity']
        if job != {'index': i, 'identity': identity, 'previous': previous, 'stale_rejected': 1} or identity >> 16 == 0 or (i and ((identity & 0xffff) != (previous & 0xffff) or identity >> 16 <= previous >> 16)):
            raise ValueError('invalid job sequence or stale identity')
        is_pressure = mode == '4M' and i == 1
        if p != ({'active': 1, 'charged': 256, 'arena_error': 1, 'released': 1} if is_pressure else dict.fromkeys(PRESSURE, 0)):
            raise ValueError('incorrect pressure or failure evidence')
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as f:
            f.write('\n'.join(chunk[1:4]) + '\n'); f.flush()
            if is_pressure:
                result = worker.check(f.name, elf, image, audit, '0')
                if not (snap['status'] == 2 and snap['payload'] == 9612 and snap['charged'] == 16384 and snap['combined'] == 0 and snap['before'] > 0 and snap['before'] - snap['after_snapshot'] == 16384 and snap['after_both'] == 0 and snap['after_release'] == snap['before'] and snap['erased'] == snap['released'] == 1):
                    raise ValueError('failed allocation did not release snapshot')
            else:
                result = snapshot.check(f.name, elf, image, audit, mode)
        result['snapshot'] = snap
        result['pressure'] = p
        result['job'] = job
        jobs.append(result)
        previous = identity
    return {'mode': mode, 'jobs': jobs}


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_pressure_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Three snapshot jobs and pressure recovery validated')

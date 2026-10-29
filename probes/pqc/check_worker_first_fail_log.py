#!/usr/bin/env python3
"""Validate early snapshot failure after a successful worker generation."""
import json
from pathlib import Path
import sys
import tempfile

import check_worker_log as worker
import check_worker_repeat_log as repeat
import check_worker_snapshot_log as snapshot
import check_worker_pressure_log as pressure

FIRST = ('active', 'full', 'charged', 'before', 'after', 'released')


def check(log, elf, image, audit, mode):
    text = Path(log).read_text(errors='replace')
    if 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('native failure')
    prefixes = ('NIHOS_NATIVE_PQC_PRESSURE ', 'NIHOS_NATIVE_PQC_FIRST_FAIL ', 'NIHOS_NATIVE_PQC_SNAPSHOT ', 'NIHOS_NATIVE_PQC_WORKER ', 'NIHOS_NATIVE_PQC_WORKER_OWNER ', 'NIHOS_NATIVE_PQC_WORKER_JOB ', 'NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS ')
    lines = [line for line in text.splitlines() if line.startswith(prefixes)]
    if len(lines) != 19 or lines[-1] != 'NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS jobs=00000003' or mode not in ('4M', '0'):
        raise ValueError('incomplete sequence')
    previous, jobs = 0, []
    for i in range(3):
        chunk = lines[6*i:6*i+6]
        p = worker.record(chunk[0], 'NIHOS_NATIVE_PQC_PRESSURE', pressure.PRESSURE)
        first = worker.record(chunk[1], 'NIHOS_NATIVE_PQC_FIRST_FAIL', FIRST)
        job = worker.record(chunk[5], 'NIHOS_NATIVE_PQC_WORKER_JOB', repeat.JOB)
        identity = job['identity']
        if job != {'index': i, 'identity': identity, 'previous': previous, 'stale_rejected': 1} or identity >> 16 == 0 or (i and ((identity & 0xffff) != (previous & 0xffff) or identity >> 16 <= previous >> 16)):
            raise ValueError('invalid job sequence or stale identity')
        if p != dict.fromkeys(pressure.PRESSURE, 0):
            raise ValueError('unexpected arena-stage pressure')
        is_first_fail = mode == '4M' and i == 1
        if is_first_fail:
            if not (first['active'] == first['full'] == first['released'] == 1 and first['charged'] == 512 and first['before'] > 0 and first['after'] == first['before']):
                raise ValueError('first allocation failure or cleanup incomplete')
            report = worker.record(chunk[3], 'NIHOS_NATIVE_PQC_WORKER', worker.FIELDS)
            if report['status'] != 2 or any(report[k] for k in worker.FIELDS if k != 'status'):
                raise ValueError('previous result leaked into failed job')
        elif first != dict.fromkeys(FIRST, 0):
            raise ValueError('unexpected first-stage injection')
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as f:
            f.write('\n'.join(chunk[2:5]) + '\n'); f.flush()
            result = snapshot.check(f.name, elf, image, audit, '0' if is_first_fail else mode)
        result['first_failure'] = first
        result['job'] = job
        jobs.append(result)
        previous = identity
    return {'mode': mode, 'jobs': jobs}


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_first_fail_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('First-allocation failure and clean next generation validated')

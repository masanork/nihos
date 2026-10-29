#!/usr/bin/env python3
"""Validate all three worker jobs against the exact audited candidate."""
import json
from pathlib import Path
import re
import sys
import tempfile

import check_worker_log as worker

JOB = ('index', 'identity', 'previous', 'stale_rejected')


def check(log, elf, image, audit, mode):
    text = Path(log).read_text(errors='replace')
    if 'NIHOS_NATIVE_FAIL' in text:
        raise ValueError('native failure')
    lines = text.splitlines()
    selected = [line for line in lines if line.startswith(('NIHOS_NATIVE_PQC_WORKER ', 'NIHOS_NATIVE_PQC_WORKER_OWNER ', 'NIHOS_NATIVE_PQC_WORKER_JOB ', 'NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS '))]
    if len(selected) != 10 or selected[-1] != 'NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS jobs=00000003':
        raise ValueError('missing or duplicated jobs or completion')
    results, previous = [], 0
    for i in range(3):
        chunk = selected[i * 3:i * 3 + 3]
        job = worker.record(chunk[2], 'NIHOS_NATIVE_PQC_WORKER_JOB', JOB)
        identity = job['identity']
        if job['index'] != i or job['previous'] != previous or job['stale_rejected'] != 1 or identity >> 16 == 0:
            raise ValueError('invalid job identity')
        if i and ((identity & 0xffff) != (previous & 0xffff) or identity >> 16 <= previous >> 16):
            raise ValueError('slot reuse or generation invalid')
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as tmp:
            tmp.write('\n'.join(chunk[:2]) + '\n')
            tmp.flush()
            result = worker.check(tmp.name, elf, image, audit, mode)
        result['job'] = job
        results.append(result)
        previous = identity
    return {'jobs': results}


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_repeat_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Three worker jobs validated')

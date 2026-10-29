#!/usr/bin/env python3
"""Check deferred cancellation and reuse against an audited fixture image."""
import json
from pathlib import Path
import sys
import tempfile

import check_worker_log as worker
import check_worker_repeat_log as repeat

CANCEL = ('requested', 'accepted_phase', 'phase', 'computed_valid', 'exposed_valid', 'outcome', 'cleaned', 'reaped')


def check(log, elf, image, audit, mode):
    text = Path(log).read_text(errors='replace')
    lines = text.splitlines()
    records = [i for i, line in enumerate(lines) if line.startswith('NIHOS_NATIVE_PQC_CANCEL ')]
    workers = [i for i, line in enumerate(lines) if line.startswith('NIHOS_NATIVE_PQC_WORKER ')]
    if len(records) != 1 or len(workers) != 3 or not workers[0] < records[0] < workers[1]:
        raise ValueError('missing, duplicated or misplaced cancellation record')
    cancel = worker.record(lines[records[0]], 'NIHOS_NATIVE_PQC_CANCEL', CANCEL)
    if mode == '4M':
        if cancel != {'requested': 1, 'accepted_phase': 1, 'phase': 2, 'computed_valid': 1, 'exposed_valid': 0, 'outcome': 3, 'cleaned': 1, 'reaped': 1}:
            raise ValueError('cancellation not accepted and retired')
        report = worker.record(lines[workers[1]], 'NIHOS_NATIVE_PQC_WORKER', worker.FIELDS)
        if report['valid'] != 0:
            raise ValueError('cancelled verification exposed as valid')
        # Preserve all other native evidence and reuse the original checks.
        lines[workers[1]] = lines[workers[1]].replace(' valid=00000000 ', ' valid=00000001 ', 1)
    elif mode == '0':
        if cancel != {'requested': 0, 'accepted_phase': 0, 'phase': 0, 'computed_valid': 0, 'exposed_valid': 0, 'outcome': 2, 'cleaned': 1, 'reaped': 1}:
            raise ValueError('unexpected cancellation with no workspace')
    else:
        raise ValueError('mode must be 4M or 0')
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as tmp:
        tmp.write('\n'.join(lines) + '\n')
        tmp.flush()
        result = repeat.check(tmp.name, elf, image, audit, mode)
    if mode == '4M':
        result['jobs'][1]['worker']['valid'] = 0
    result['cancellation'] = cancel
    return result


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_cancel_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Deferred cancellation and three jobs validated')

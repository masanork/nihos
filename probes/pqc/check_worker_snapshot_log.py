#!/usr/bin/env python3
"""Check the copied-input worker fixture and simultaneous heap charge."""
import json
from pathlib import Path
import sys

import check_worker_log as worker

FIELDS = ('status', 'payload', 'charged', 'combined', 'before', 'after_snapshot', 'after_both', 'after_release', 'erased', 'released')


def check(log, elf, image, audit, mode):
    result = worker.check(log, elf, image, audit, mode)
    text = Path(log).read_text(errors='replace')
    snapshot = worker.record(text, 'NIHOS_NATIVE_PQC_SNAPSHOT', FIELDS)
    if mode == '4M':
        if not (snapshot['status'] == 1 and snapshot['payload'] == 9612 and snapshot['charged'] == 16384 and snapshot['combined'] == 32768 and snapshot['before'] > snapshot['after_snapshot'] > snapshot['after_both'] and snapshot['before'] - snapshot['after_snapshot'] == snapshot['charged'] and snapshot['before'] - snapshot['after_both'] == snapshot['combined'] and snapshot['after_release'] == snapshot['before'] and snapshot['erased'] == snapshot['released'] == 1 and result['worker']['charged'] == snapshot['combined'] - snapshot['charged']):
            raise ValueError('snapshot allocation or release evidence incomplete')
    elif mode == '0':
        if snapshot['status'] != 2 or any(snapshot[k] for k in FIELDS if k != 'status'):
            raise ValueError('unexpected snapshot with absent PSRAM')
    else:
        raise ValueError('mode must be 4M or 0')
    result['snapshot'] = snapshot
    return result


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_snapshot_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Copied-input worker validated')

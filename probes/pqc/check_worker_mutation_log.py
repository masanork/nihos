#!/usr/bin/env python3
"""Validate copied-input verification after the caller buffer changes."""
import json
from pathlib import Path
import sys

import check_worker_log as worker
import check_worker_snapshot_log as snapshot

FIELDS = ('status', 'payload', 'charged', 'simultaneous', 'before', 'after_alloc', 'after_release', 'copied', 'mutated', 'erased', 'released')


def check(log, elf, image, audit, mode):
    result = snapshot.check(log, elf, image, audit, mode)
    text = Path(log).read_text(errors='replace')
    source = worker.record(text, 'NIHOS_NATIVE_PQC_SOURCE', FIELDS)
    snap = result['snapshot']
    if mode == '4M':
        if not (source['status'] == 1 and source['payload'] == 9612 and source['charged'] == 16384 and source['simultaneous'] == 49152 and source['before'] > 0 and source['before'] - source['after_alloc'] == source['charged'] and source['after_alloc'] == snap['before'] and source['before'] - snap['after_both'] == source['simultaneous'] and source['after_release'] == source['before'] and all(source[k] == 1 for k in ('copied', 'mutated', 'erased', 'released'))):
            raise ValueError('mutation handshake or source accounting incomplete')
    elif mode == '0':
        if source['status'] != 2 or any(source[k] for k in FIELDS if k != 'status'):
            raise ValueError('unexpected source with absent PSRAM')
    else:
        raise ValueError('mode must be 4M or 0')
    result['source'] = source
    return result


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('usage: check_worker_mutation_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Copied-input mutation fixture validated')

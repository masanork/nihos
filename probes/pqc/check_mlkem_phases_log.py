#!/usr/bin/env python3
"""Check per-operation ML-KEM worker stack watermarks."""
import json
from pathlib import Path
import sys

import check_mlkem_worker_log as base
import check_worker_log as worker

FIELDS = ('key_stack', 'enc_stack', 'dec_stack', 'implicit_stack', 'oom_stack')


def check(log, elf, image, audit, mode):
    result = base.check(log, elf, image, audit, mode)
    phases = worker.record(Path(log).read_text(errors='replace'), 'NIHOS_NATIVE_MLKEM_STACK', FIELDS)
    if mode == '4M':
        if not all(0 < phases[k] <= result['memory']['stack_used'] < result['stack_bytes'] - 16 for k in FIELDS):
            raise ValueError('invalid per-operation stack samples')
    elif mode == '0':
        if any(phases.values()): raise ValueError('stack samples with no PSRAM')
    else: raise ValueError('mode must be 4M or 0')
    result['phase_stack'] = phases
    return result


if __name__ == '__main__':
    if len(sys.argv) != 7: raise SystemExit('usage: check_mlkem_phases_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('ML-KEM phase stack samples validated')

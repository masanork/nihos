#!/usr/bin/env python3
"""Check sequential ML-DSA and ML-KEM on an explicitly experimental XIP image."""
import json
from pathlib import Path
import re
import sys

import check_worker_log as worker
import check_mlkem_phases_log as kem
from inspect_combined_xip import FUNCTIONS, xip_sections

JOB = ('index', 'identity', 'previous', 'stale_rejected')


def check(log, elf, image, audit, mode):
    dsa = worker.check(log, elf, image, audit, mode)
    mlkem = kem.check(log, elf, image, audit, mode)
    a = json.loads(Path(audit).read_text())
    fixture = a.get('pqc_fixture', {})
    flash = xip_sections(elf)
    if fixture.get('profile') != 'diagnostic-combined-headless-fixture' or fixture.get('cache_off_qualified') is not False or set(fixture.get('functions', {})) != FUNCTIONS or fixture.get('text_sha256') != flash['.flash.pqc']['sha256'] or fixture.get('rodata_sha256') != flash['.flash.pqc.rodata']['sha256']:
        raise ValueError('experimental XIP audit does not match ELF')
    if a['heap']['bytes'] < 49152:
        raise ValueError('primary SRAM heap floor not met')
    text = Path(log).read_text(errors='replace')
    pattern = r'^NIHOS_NATIVE_PQC_COMBINED_JOB' + ''.join(' ' + n + r'=([0-9a-f]{8})' for n in JOB) + r'\r?$'
    jobs = [dict(zip(JOB, (int(v, 16) for v in row))) for row in re.findall(pattern, text, re.M)]
    if len(jobs) != 2 or jobs[0]['index'] != 0 or jobs[1]['index'] != 1 or jobs[0]['previous'] != 0 or jobs[1]['previous'] != jobs[0]['identity'] or any(j['stale_rejected'] != 1 for j in jobs):
        raise ValueError('invalid combined jobs')
    if not (jobs[0]['identity'] & 0xffff == jobs[1]['identity'] & 0xffff and jobs[0]['identity'] >> 16 != 0 and jobs[1]['identity'] >> 16 > jobs[0]['identity'] >> 16):
        raise ValueError('slot reuse or generation invalid')
    markers = ['NIHOS_NATIVE_PQC_WORKER ', 'NIHOS_NATIVE_PQC_WORKER_OWNER ', 'NIHOS_NATIVE_PQC_COMBINED_JOB index=00000000', 'NIHOS_NATIVE_MLKEM_WORKER ', 'NIHOS_NATIVE_MLKEM_OWNER ', 'NIHOS_NATIVE_PQC_COMBINED_JOB index=00000001', 'NIHOS_NATIVE_PQC_COMBINED_PASS jobs=00000002']
    indices = [text.find(x) for x in markers]
    if any(x < 0 for x in indices) or indices != sorted(indices) or text.count('NIHOS_NATIVE_PQC_COMBINED_PASS ') != 1:
        raise ValueError('missing or out-of-order completion')
    return {'mode': mode, 'elf_sha256': a['elf_sha256'], 'image_sha256': a['image_sha256'], 'heap_bytes': a['heap']['bytes'], 'flash': flash, 'jobs': jobs, 'mldsa': dsa, 'mlkem': mlkem}


if __name__ == '__main__':
    if len(sys.argv) != 7: raise SystemExit('usage: check_combined_xip_log.py LOG ELF BIN AUDIT 4M|0 OUTPUT.json')
    result = check(*sys.argv[1:6])
    Path(sys.argv[6]).write_text(json.dumps(result, indent=2) + '\n')
    print('Combined XIP worker evidence validated')

#!/usr/bin/env python3
"""Validate P4 updater's pre-token capture; this is not OTA evidence.

The caller independently proves P4 byte identity, serial ownership and that
no token was written. The capture is not a C6 flash readback.
"""
import argparse
import hashlib
import json
from pathlib import Path
from c6_ota_evidence import InvalidEvidence
from c6_hosted3_upgrade_evidence import CANDIDATE_SHA, CANDIDATE_BYTES


def analyze(capture):
    try:
        lines = capture.decode('ascii').splitlines()
    except UnicodeDecodeError as err:
        raise InvalidEvidence('non-ASCII capture') from err
    required = (
        'NIHOS_C6_MAP_BOOT',
        f'NIHOS_C6_MAP_RESULT bytes={CANDIDATE_BYTES:08x} sha256={CANDIDATE_SHA}',
        'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000002 minor=0000000d patch=00000001',
        'NIHOS_C6_OTA_READY',
    )
    if any(lines.count(line) != 1 for line in required):
        raise InvalidEvidence('missing or duplicated preflight event')
    indices = [lines.index(line) for line in required]
    if indices != sorted(indices) or len(set(indices)) != len(indices):
        raise InvalidEvidence('preflight events out of order')
    forbidden = ('NIHOS_C6_OTA_SIMULATED', 'NIHOS_C6_OTA_PROGRESS', 'NIHOS_C6_OTA_RESULT',
                 'NIHOS_C6_OTA_POST', 'NIHOS_C6_OTA_ERROR', 'NIHOS_C6_MAP_TRAP',
                 'NIHOS_C6_MAP_INVALID', 'NIHOS_C6_PREFLIGHT_ERROR', 'NIHOS_C6_PREFLIGHT_HASH_FAIL',
                 'NIHOS_C6_PREFLIGHT_TIMER_FAIL', 'NIHOS_C6_OTA_TARGET_VERSION_')
    if any(line.startswith(forbidden) for line in lines):
        raise InvalidEvidence('simulation, update or failure event in preflight')
    return {'capture_sha256': hashlib.sha256(capture).hexdigest(),
            'candidate_sha256': CANDIDATE_SHA, 'candidate_bytes': CANDIDATE_BYTES,
            'origin_version': '2.13.1', 'preflight_ready': True,
            'meaning': 'P4 pre-token report only; no OTA, flash readback or recovery proof'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes())
    except (InvalidEvidence, OSError) as err:
        raise SystemExit(f'Hosted 3 preflight evidence rejected: {err}') from err
    with args.output.open('x') as out:
        json.dump(result, out, indent=2)
        out.write('\n')
    print(result['meaning'])


if __name__ == '__main__':
    main()

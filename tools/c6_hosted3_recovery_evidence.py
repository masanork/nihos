#!/usr/bin/env python3
"""Analyze a P4 3.0.10 -> 2.13.1 OTA capture without device I/O.

This checks reported transfer and version only, not installed-byte identity,
NTP, bootloader rollback, or an independent recovery route.
"""
import argparse
import hashlib
import json
from pathlib import Path
from c6_ota_evidence import InvalidEvidence, fields

CANDIDATE_SHA = '7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be'
CANDIDATE_BYTES = 1_278_048


def analyze(capture, token):
    if token != ('OTA1 ' + CANDIDATE_SHA + '\n').encode('ascii'):
        raise InvalidEvidence('incorrect one-shot start token')
    try:
        lines = capture.decode('ascii').splitlines()
    except UnicodeDecodeError as err:
        raise InvalidEvidence('non-ASCII capture') from err
    if 'NIHOS_C6_OTA_SIMULATED' in lines:
        raise InvalidEvidence('simulated transfer is not physical OTA evidence')
    if any(line.startswith(('NIHOS_C6_MAP_TRAP', 'NIHOS_C6_OTA_ERROR',
                            'NIHOS_C6_PREFLIGHT_ERROR', 'NIHOS_C6_OTA_TARGET_VERSION_FAIL')) for line in lines):
        raise InvalidEvidence('fixture reported an error')
    fixed = ('NIHOS_C6_MAP_BOOT',
             f'NIHOS_C6_MAP_RESULT bytes={CANDIDATE_BYTES:08x} sha256={CANDIDATE_SHA}',
             'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000003 minor=00000000 patch=0000000a',
             'NIHOS_C6_OTA_READY', 'NIHOS_C6_OTA_TARGET_VERSION_OK')
    if any(lines.count(value) != 1 for value in fixed):
        raise InvalidEvidence('missing or duplicate fixture event')
    updates = [line for line in lines if line.startswith('NIHOS_C6_OTA_RESULT ')]
    posts = [line for line in lines if line.startswith('NIHOS_C6_OTA_POST ')]
    if len(updates) != 1 or len(posts) != 1:
        raise InvalidEvidence('missing or duplicate update or post result')
    ordered = (fixed[0], fixed[1], fixed[2], fixed[3], updates[0], posts[0], fixed[4])
    indexes = [lines.index(item) for item in ordered]
    if indexes != sorted(indexes) or len(set(indexes)) != len(indexes):
        raise InvalidEvidence('fixture events out of order')
    update = fields(updates[0], 'NIHOS_C6_OTA_RESULT')
    if update != {'status': 1, 'stage': 8, 'error_code': 0, 'acknowledged_bytes': CANDIDATE_BYTES}:
        raise InvalidEvidence('transfer incomplete')
    post = fields(posts[0], 'NIHOS_C6_OTA_POST')
    expected = {'status': 1, 'stage': 6, 'error_code': 0, 'peer_chip': 13,
                'version_known': 1, 'major': 2, 'minor': 13, 'patch': 1}
    if any(post.get(k) != v for k, v in expected.items()):
        raise InvalidEvidence('post-update peer version mismatch')
    return {'capture_sha256': hashlib.sha256(capture).hexdigest(),
            'candidate_sha256': CANDIDATE_SHA, 'acknowledged_bytes': CANDIDATE_BYTES,
            'meaning': 'P4-reported OTA and version only; C6 flash identity, health and recovery unverified'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', required=True, type=Path)
    parser.add_argument('--sent-token', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes(), args.sent_token.read_bytes())
    except (InvalidEvidence, OSError) as err:
        raise SystemExit(f'Hosted 3 recovery evidence rejected: {err}') from err
    with args.output.open('x') as out:
        json.dump(result, out, indent=2)
        out.write('\n')
    print(result['meaning'])


if __name__ == '__main__':
    main()

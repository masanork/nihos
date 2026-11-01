#!/usr/bin/env python3
"""Strictly analyze P4 1.4.1 -> 2.13.1 time OTA capture; no device I/O.

Acceptance is P4-reported transfer and peer version, not flash readback,
identity proof, application health, NTP success, or a recovery guarantee.
"""
import argparse
import hashlib
import json
from pathlib import Path
from c6_ota_evidence import HEX64, InvalidEvidence, fields

CANDIDATE_SHA = '7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be'
CANDIDATE_BYTES = 1_278_048

def analyze(capture, token, candidate_sha):
    if not HEX64.fullmatch(candidate_sha) or candidate_sha != CANDIDATE_SHA:
        raise InvalidEvidence('wrong reviewed candidate hash')
    if token != ('OTA1 ' + candidate_sha + '\n').encode('ascii'):
        raise InvalidEvidence('incorrect start token')
    try:
        lines = capture.decode('ascii').splitlines()
    except UnicodeDecodeError as error:
        raise InvalidEvidence('non-ASCII capture') from error
    if 'NIHOS_C6_OTA_SIMULATED' in lines:
        raise InvalidEvidence('simulated transfer is not physical evidence')
    if any(line.startswith(('NIHOS_C6_MAP_TRAP', 'NIHOS_C6_OTA_ERROR',
                            'NIHOS_C6_PREFLIGHT_ERROR', 'NIHOS_C6_OTA_TARGET_VERSION_FAIL')) for line in lines):
        raise InvalidEvidence('fixture reported an error')
    map_line = f'NIHOS_C6_MAP_RESULT bytes={CANDIDATE_BYTES:08x} sha256={candidate_sha}'
    fixed = ('NIHOS_C6_MAP_BOOT', map_line,
             'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000001 minor=00000004 patch=00000001',
             'NIHOS_C6_OTA_READY', 'NIHOS_C6_OTA_TARGET_VERSION_OK')
    if any(lines.count(item) != 1 for item in fixed):
        raise InvalidEvidence('missing or duplicate fixture event')
    updates = [line for line in lines if line.startswith('NIHOS_C6_OTA_RESULT ')]
    posts = [line for line in lines if line.startswith('NIHOS_C6_OTA_POST ')]
    if len(updates) != 1 or len(posts) != 1:
        raise InvalidEvidence('missing or duplicate update/post result')
    ordered = (fixed[0], fixed[1], fixed[2], fixed[3], updates[0], posts[0], fixed[4])
    indexes = [lines.index(item) for item in ordered]
    if indexes != sorted(indexes) or len(set(indexes)) != len(indexes):
        raise InvalidEvidence('fixture events out of order')
    update = fields(updates[0], 'NIHOS_C6_OTA_RESULT')
    post = fields(posts[0], 'NIHOS_C6_OTA_POST')
    if update != {'status': 1, 'stage': 8, 'error_code': 0, 'acknowledged_bytes': CANDIDATE_BYTES}:
        raise InvalidEvidence('transfer incomplete')
    required = {'status': 1, 'stage': 6, 'error_code': 0, 'peer_chip': 13,
                'version_known': 1, 'major': 2, 'minor': 13, 'patch': 1}
    if any(post.get(name) != value for name, value in required.items()):
        raise InvalidEvidence('post-reboot peer version mismatch')
    return {'capture_sha256': hashlib.sha256(capture).hexdigest(),
            'candidate_sha256': candidate_sha, 'acknowledged_bytes': CANDIDATE_BYTES,
            'meaning': 'P4-reported OTA and version only; C6 image identity, functionality and recovery unverified'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--sent-token', type=Path, required=True)
    parser.add_argument('--candidate-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes(), args.sent_token.read_bytes(), args.candidate_sha256)
    except (InvalidEvidence, OSError) as error:
        raise SystemExit(f'OTA evidence rejected: {error}') from error
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(result['meaning'])

if __name__ == '__main__':
    main()

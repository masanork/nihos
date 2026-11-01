#!/usr/bin/env python3
"""Analyze OTA fixture output; no serial, reset, or flash operations.

A successful report means a correlated, structurally valid P4 console capture,
not a physical image readback or proof of future C6 recovery. The caller must
separately establish exact P4 image identity and exclusive device ownership.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

CANDIDATE_BYTES = 1_079_120
HEX64 = re.compile(r'^[0-9a-f]{64}$')
FIELD = re.compile(r'^([a-z_]+)=([0-9a-f]{8})$')

class InvalidEvidence(ValueError):
    pass

def fields(line, prefix):
    words = line.split(' ')
    if not words or words[0] != prefix:
        raise InvalidEvidence('unexpected result prefix')
    result = {}
    for word in words[1:]:
        match = FIELD.fullmatch(word)
        if not match or match[1] in result:
            raise InvalidEvidence('malformed or duplicate result field')
        result[match[1]] = int(match[2], 16)
    return result

def analyze(capture, candidate_sha256, sent_token):
    if not HEX64.fullmatch(candidate_sha256):
        raise InvalidEvidence('invalid candidate hash')
    if sent_token != ('OTA1 ' + candidate_sha256 + '\n').encode('ascii'):
        raise InvalidEvidence('start token differs from candidate')
    try:
        text = capture.decode('ascii')
    except UnicodeDecodeError as error:
        raise InvalidEvidence('non-ASCII capture') from error
    lines = text.splitlines()
    if 'NIHOS_C6_OTA_SIMULATED' in lines:
        raise InvalidEvidence('simulation capture cannot prove a C6 OTA')
    if lines.count('NIHOS_C6_MAP_BOOT') != 1:
        raise InvalidEvidence('missing or repeated P4 fixture boot')
    expected_map = f'NIHOS_C6_MAP_RESULT bytes={CANDIDATE_BYTES:08x} sha256={candidate_sha256}'
    if lines.count(expected_map) != 1 or lines.count('NIHOS_C6_OTA_READY') != 1:
        raise InvalidEvidence('missing or duplicate candidate hash or ready event')
    if any(line.startswith(('NIHOS_C6_MAP_TRAP', 'NIHOS_C6_OTA_ERROR', 'NIHOS_C6_PREFLIGHT_ERROR')) for line in lines):
        raise InvalidEvidence('fixture reported an error')
    updates = [line for line in lines if line.startswith('NIHOS_C6_OTA_RESULT ')]
    posts = [line for line in lines if line.startswith('NIHOS_C6_OTA_POST ')]
    if len(updates) != 1 or len(posts) != 1:
        raise InvalidEvidence('missing or duplicate OTA or post-boot result')
    indexes = [lines.index(expected_map), lines.index('NIHOS_C6_OTA_READY'), lines.index(updates[0]), lines.index(posts[0])]
    if indexes != sorted(indexes) or len(set(indexes)) != len(indexes):
        raise InvalidEvidence('events out of order')
    update, post = fields(updates[0], 'NIHOS_C6_OTA_RESULT'), fields(posts[0], 'NIHOS_C6_OTA_POST')
    if update != {'status': 1, 'stage': 8, 'error_code': 0, 'acknowledged_bytes': CANDIDATE_BYTES}:
        raise InvalidEvidence('OTA not fully acknowledged')
    required = {'status': 1, 'stage': 6, 'error_code': 0, 'peer_chip': 13,
                'version_known': 1, 'major': 1, 'minor': 4, 'patch': 1, 'diag_known': 1}
    if any(post.get(name) != value for name, value in required.items()):
        raise InvalidEvidence('post-reboot version or diagnostics missing')
    if post.get('diag_heap', 0) == 0 or 'diag_uptime' not in post:
        raise InvalidEvidence('invalid diagnostic snapshot')
    return {'capture_sha256': hashlib.sha256(capture).hexdigest(),
            'candidate_sha256': candidate_sha256,
            'acknowledged_bytes': update['acknowledged_bytes'],
            'post_reboot_diag_uptime_seconds': post['diag_uptime'],
            'post_reboot_free_heap_bytes': post['diag_heap'],
            'meaning': 'P4-reported OTA response and post-reboot diagnostics; no C6 flash readback'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--sent-token', type=Path, required=True)
    parser.add_argument('--candidate-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes(), args.candidate_sha256, args.sent_token.read_bytes())
    except (InvalidEvidence, OSError) as error:
        raise SystemExit(f'OTA evidence rejected: {error}') from error
    # Do not replace a prior result if this invocation fails.
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print('P4 OTA response and post-reboot diagnostics accepted; C6 readback unverified')

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check a C6 AppGetDesc capture against a local candidate's metadata.

The comparison is not flash readback or image identity. Device ownership and
exact P4 bytes must be established independently by the physical runner.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
from c6_ota_evidence import HEX64, InvalidEvidence, fields


def analyze(capture, candidate, candidate_sha):
    if not HEX64.fullmatch(candidate_sha) or hashlib.sha256(candidate).hexdigest() != candidate_sha:
        raise InvalidEvidence('reviewed candidate digest mismatch')
    if len(candidate) < 288 or candidate[0] != 0xe9 or struct.unpack_from('<H', candidate, 12)[0] != 13 or struct.unpack_from('<I', candidate, 32)[0] != 0xabcd5432:
        raise InvalidEvidence('candidate is not a C6 app image')
    try:
        lines = capture.decode('ascii').splitlines()
    except UnicodeDecodeError as err:
        raise InvalidEvidence('non-ASCII capture') from err
    if lines.count('NIHOS_C6_BOOT backend=zig-sram rtos=none cpu1=parked') != 1 or any(line.startswith(('NIHOS_C6_TRAP', 'NIHOS_C6_FAIL')) for line in lines):
        raise InvalidEvidence('missing boot or probe error')
    desc = [line for line in lines if line.startswith('NIHOS_C6_APP_DESC ')]
    reports = [line for line in lines if line.startswith('NIHOS_C6_OTA_INFO ')]
    if len(desc) != 1 or len(reports) != 1 or lines.index(desc[0]) >= lines.index(reports[0]):
        raise InvalidEvidence('missing, duplicate or unordered reports')
    report = fields(reports[0], 'NIHOS_C6_OTA_INFO')
    required = {'status': 0, 'stage': 5, 'peer_chip': 13, 'fw_known': 1,
                'major': 2, 'minor': 13, 'patch': 1, 'desc_known': 1,
                'ack_known': 1, 'ack_status': 0x105, 'result_known': 0}
    if any(report.get(k) != v for k, v in required.items()):
        raise InvalidEvidence('unexpected C6 peer or unsupported-service result')
    parts = desc[0].split(' ')
    if len(parts) != 5:
        raise InvalidEvidence('malformed app description')
    metadata = {}
    for key, item in zip(('version', 'project', 'idf', 'elf_sha256'), parts[1:]):
        if not item.startswith(key + '='):
            raise InvalidEvidence('unexpected description field')
        value = item[len(key) + 1:]
        if key == 'elf_sha256':
            if value != '-':
                raise InvalidEvidence('unexpected optional ELF digest')
            continue
        if not re.fullmatch(r'(?:[0-9a-f]{2}){1,32}', value):
            raise InvalidEvidence('invalid metadata hex')
        raw = bytes.fromhex(value)
        if any(x < 32 or x > 126 for x in raw):
            raise InvalidEvidence('non-printable metadata')
        metadata[key] = raw.decode('ascii')
    expected = {}
    for key, offset in (('version', 48), ('project', 80), ('idf', 144)):
        raw = candidate[offset:offset + 32].split(b'\0', 1)[0]
        try:
            expected[key] = raw.decode('ascii')
        except UnicodeDecodeError as err:
            raise InvalidEvidence('candidate description is non-ASCII') from err
    if metadata != expected:
        raise InvalidEvidence('reported metadata differs from candidate')
    return {'capture_sha256': hashlib.sha256(capture).hexdigest(),
            'candidate_sha256': candidate_sha, 'metadata': metadata,
            'ota_info_status': report['ack_status'],
            'meaning': 'self-reported metadata matches candidate; no C6 flash identity or rollback proof'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--candidate-sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes(), args.candidate.read_bytes(), args.candidate_sha256)
    except (InvalidEvidence, OSError) as err:
        raise SystemExit(f'C6 description evidence rejected: {err}') from err
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(result['meaning'])


if __name__ == '__main__':
    main()

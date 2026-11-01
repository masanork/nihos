#!/usr/bin/env python3
"""Analyze a P4 C6 time snapshot capture; this does not prove trusted time.

Device identity, exclusive ownership and flashed P4 bytes must be verified by
the caller. NTP is unauthenticated and this is not a C6 flash readback.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
from c6_ota_evidence import InvalidEvidence, fields

def analyze(capture, reference_unix, max_skew):
    if reference_unix < 0 or max_skew < 0:
        raise InvalidEvidence('invalid external clock comparison')
    try:
        lines = capture.decode('ascii').splitlines()
    except UnicodeDecodeError as error:
        raise InvalidEvidence('non-ASCII capture') from error
    if any(line.startswith(('NIHOS_C6_TIME_ERROR', 'NIHOS_C6_TRAP', 'NIHOS_C6_FAIL')) for line in lines):
        raise InvalidEvidence('P4 reported an error')
    outputs = [line for line in lines if line.startswith('NIHOS_C6_TIME ')]
    if len(outputs) != 1:
        raise InvalidEvidence('missing or ambiguous time report')
    result = fields(outputs[0], 'NIHOS_C6_TIME')
    required = {'status': 1, 'stage': 6, 'error_code': 0, 'peer_chip': 13,
                'fw_known': 1, 'major': 2, 'minor': 13, 'patch': 1,
                'station_connected': 1, 'split_address_known': 1,
                'acknowledged': 1, 'got_result': 1, 'synced': 1,
                'last_rpc_id': 788, 'last_rpc_kind': 3}
    if any(result.get(name) != value for name, value in required.items()):
        raise InvalidEvidence('time service result incomplete')
    if not all(key in result for key in ('seconds_high', 'seconds_low', 'age_seconds', 'attempts')):
        raise InvalidEvidence('missing sample fields')
    unix = (result['seconds_high'] << 32) | result['seconds_low']
    if not 1_704_067_200 <= unix < 4_102_444_800:
        raise InvalidEvidence('wall clock outside diagnostic range')
    if abs(reference_unix - unix) > max_skew:
        raise InvalidEvidence('wall clock differs from external reference')
    return {'capture_sha256': hashlib.sha256(capture).hexdigest(),
            'unix_seconds': unix, 'utc': datetime.fromtimestamp(unix, timezone.utc).isoformat(),
            'sync_age_seconds_at_c6': result['age_seconds'], 'attempts': result['attempts'],
            'reference_unix_seconds': reference_unix, 'reference_skew_seconds': reference_unix - unix,
            'meaning': 'P4-reported C6 time snapshot; SNTP is unauthenticated and flash bytes are not read back'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--reference-unix', type=int, required=True)
    parser.add_argument('--max-skew', type=int, default=60)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes(), args.reference_unix, args.max_skew)
    except (InvalidEvidence, OSError, OverflowError) as error:
        raise SystemExit(f'C6 time evidence rejected: {error}') from error
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(result['meaning'])
if __name__ == '__main__':
    main()

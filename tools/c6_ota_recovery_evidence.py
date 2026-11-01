#!/usr/bin/env python3
"""Analyze 2.13.1 -> 1.4.1 recovery fixture output; performs no device I/O."""
import argparse
import json
from pathlib import Path
from c6_ota_evidence import analyze as analyze_legacy, InvalidEvidence

CANDIDATE_SHA = '0ab00183efb3149b568d0968877f1a7718f7c79817748a8e5c0417957cbf5e3b'
ORIGIN = 'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000002 minor=0000000d patch=00000001'

def analyze(capture, token, candidate_sha):
    if candidate_sha != CANDIDATE_SHA:
        raise InvalidEvidence('wrong reviewed 1.4.1 candidate')
    result = analyze_legacy(capture, candidate_sha, token)
    lines = capture.decode('ascii').splitlines()
    if lines.count(ORIGIN) != 1:
        raise InvalidEvidence('missing or duplicate 2.13.1 origin')
    map_line = next(line for line in lines if line.startswith('NIHOS_C6_MAP_RESULT '))
    if not lines.index(map_line) < lines.index(ORIGIN) < lines.index('NIHOS_C6_OTA_READY'):
        raise InvalidEvidence('origin out of order')
    result['meaning'] = 'P4-reported 2.13.1 to 1.4.1 OTA and diagnostics; C6 flash readback and future recovery unverified'
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--sent-token', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(args.capture.read_bytes(), args.sent_token.read_bytes(), CANDIDATE_SHA)
    except (InvalidEvidence, OSError) as error:
        raise SystemExit(f'OTA recovery evidence rejected: {error}') from error
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(result['meaning'])

if __name__ == '__main__':
    main()

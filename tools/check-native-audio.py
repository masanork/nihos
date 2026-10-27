#!/usr/bin/env python3
"""Validate a finite native audio capture; actual sound remains operator evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re

FIELDS = ('phase', 'fault', 'dma', 'bclk', 'fifo', 'eof_descriptor', 'parked', 'codec_off', 'stopped', 'returned')
IO_FIELDS = ('device', 'register', 'expected', 'actual', 'stage')


def records(log, marker, fields):
    pattern = re.compile('^' + marker + ' ' + ' '.join(name + r'=([0-9a-f]{8})' for name in fields) + r'\r?$', re.M)
    rows = [dict(zip(fields, (int(value, 16) for value in match.groups()))) for match in pattern.finditer(log)]
    if len(rows) != log.count(marker + ' ') or not rows:
        raise ValueError('missing/malformed ' + marker)
    return rows


def check(log):
    if log.count('ESP-ROM:esp32p4') != 1 or 'NIHOS_NATIVE_FAIL' in log or 'NIHOS_NATIVE_TRAP' in log:
        raise ValueError('missing single boot or native failure')
    rows = records(log, 'NIHOS_NATIVE_AUDIO', FIELDS)
    io = records(log, 'NIHOS_NATIVE_AUDIO_IO', IO_FIELDS)
    if any(row['fault'] or row['phase'] > 7 for row in rows) or any(row['stage'] for row in io):
        raise ValueError('audio or codec failure')
    if any(a['phase'] > b['phase'] for a, b in zip(rows, rows[1:])):
        raise ValueError('audio state restarted after completion')
    complete = [row for row in rows if row['phase'] == 7]
    if len(complete) < 2 or rows[-1]['phase'] != 7:
        raise ValueError('missing stable completion')
    final = complete[-1]
    if (final['dma'] & 8 == 0 or final['dma'] & 4 or not 262144 <= final['bclk'] <= 262176 or final['fifo'] != 16384 or
            not 0x4ff00000 <= final['eof_descriptor'] < 0x4ff28000 or final['eof_descriptor'] % 16 or
            (final['parked'], final['codec_off'], final['stopped'], final['returned']) != (1, 1, 1, 1)):
        raise ValueError('incomplete DMA/end/cleanup evidence')
    if any(row != final for row in complete):
        raise ValueError('completion changed after shutdown')
    return {'scope': 'native finite DMA/codec output progression; audible output not evaluated',
            'records': len(rows), 'complete_records': len(complete), 'final': final}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path, help='Private capture directory including result.json and candidate audit')
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    raw = (args.capture / 'serial.log').read_bytes()
    metadata = json.loads((args.capture / 'result.json').read_text())
    audit = json.loads((args.capture / 'candidate/retained-loader-audit.json').read_text())
    if (not metadata['written'] or not metadata['restored'] or metadata['native_fail'] or
            metadata['serial_sha256'] != hashlib.sha256(raw).hexdigest() or
            metadata['app_sha256'] != hashlib.sha256((args.capture / 'candidate/nihos-native.bin').read_bytes()).hexdigest() or
            metadata['app_sha256'] != audit['image_sha256']):
        raise ValueError('capture/restore/image identity mismatch')
    report = check(raw.decode('utf-8', errors='replace'))
    report.update(evidence='physical-device capture', app_sha256=metadata['app_sha256'], serial_sha256=metadata['serial_sha256'])
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Finite native audio DMA/codec/cleanup evidence passed; audible output remains separate')


if __name__ == '__main__':
    main()

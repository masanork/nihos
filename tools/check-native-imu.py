#!/usr/bin/env python3
"""Check native IMU acquisition; motion and board-axis mapping are separate."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

FIELDS = ('chip', 'initialized', 'stage', 'fault', 'uploaded', 'valid', 'samples',
          'acc_x', 'acc_y', 'acc_z', 'gyr_x', 'gyr_y', 'gyr_z', 'sensor_error', 'ready_status')
PATTERN = re.compile(r'^NIHOS_NATIVE_IMU ' + ' '.join(name + r'=([0-9a-f]{8})' for name in FIELDS) + r'\r?$', re.M)


def signed(value):
    return value - 2**32 if value >= 2**31 else value


def check(log):
    if log.count('ESP-ROM:esp32p4') != 1 or 'NIHOS_NATIVE_FAIL' in log:
        raise ValueError('missing single boot or native failure')
    rows = [dict(zip(FIELDS, (int(value, 16) for value in match.groups()))) for match in PATTERN.finditer(log)]
    if len(rows) != log.count('NIHOS_NATIVE_IMU ') or not rows:
        raise ValueError('missing or malformed IMU records')
    ready = []
    uploaded = samples = 0
    for row in rows:
        if (row['fault'] or row['sensor_error'] or row['stage'] >= 14 or
                row['initialized'] not in (0, 1) or row['valid'] not in (0, 1) or
                not uploaded <= row['uploaded'] <= 8192 or row['uploaded'] % 32 or
                row['samples'] < samples):
            raise ValueError('IMU fault, regressing progress or invalid state')
        uploaded, samples = row['uploaded'], row['samples']
        if not row['valid']:
            if ready:
                raise ValueError('acquisition lost validity')
            continue
        if (row['chip'] != 0x24 or row['initialized'] != 1 or row['uploaded'] != 8192 or
                row['stage'] not in (12, 13) or row['ready_status'] & 0xc0 != 0xc0 or
                row['samples'] == 0 or (ready and row['samples'] <= ready[-1]['samples'])):
            raise ValueError('incomplete initialization or stale acquisition')
        for name in FIELDS[7:13]:
            row[name] = signed(row[name])
            if not -32768 <= row[name] <= 32767:
                raise ValueError('invalid signed sensor counts')
        ready.append(row)
    if len(ready) < 3 or ready[-1]['samples'] - ready[0]['samples'] < 10:
        raise ValueError('insufficient continued acquisition')
    norms = [math.sqrt(sum(row[name]**2 for name in ('acc_x', 'acc_y', 'acc_z'))) / 8192 for row in ready]
    if sum(0.5 <= value <= 1.5 for value in norms) < 3:
        raise ValueError('no repeated gravity-sized acceleration')
    return {'schema': 1, 'scope': 'native sensor-frame acquisition; no motion/axis/calibration qualification',
            'records': len(rows), 'ready_records': len(ready), 'first': ready[0], 'last': ready[-1],
            'observed_acceleration_norm_g': {'min': min(norms), 'max': max(norms)},
            'sample_delta': ready[-1]['samples'] - ready[0]['samples']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    raw = args.log.read_bytes()
    result = check(raw.decode('utf-8', errors='replace'))
    result['log_sha256'] = hashlib.sha256(raw).hexdigest()
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Native IMU continued acquisition passed; sensor-frame raw values only')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check finite ES7210 DMA input and shutdown; no acoustic calibration claim."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('finite_audio', Path(__file__).with_name('check-native-audio.py'))
AUDIO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIO)
FIELDS = ('phase', 'fault', 'dma', 'end', 'parked', 'codec_off', 'stopped', 'returned', 'samples', 'erased')
SIGNAL_FIELDS = ('active', 'clipped', 'peak0', 'peak1', 'peak2', 'peak3', 'span0', 'span1', 'span2', 'span3')
IO_FIELDS = ('register', 'expected', 'actual', 'stage')


def check(log, muted=False):
    if log.count('ESP-ROM:esp32p4') != 1 or 'NIHOS_NATIVE_FAIL' in log or 'NIHOS_NATIVE_TRAP' in log:
        raise ValueError('missing single boot or native failure')
    rows = AUDIO.records(log, 'NIHOS_NATIVE_MICROPHONE', FIELDS)
    io = AUDIO.records(log, 'NIHOS_NATIVE_MICROPHONE_IO', IO_FIELDS)
    signal = AUDIO.records(log, 'NIHOS_NATIVE_MICROPHONE_SIGNAL', SIGNAL_FIELDS)
    if len(signal) != len(rows) or any(row['fault'] or row['phase'] > 5 for row in rows) or any(row['stage'] for row in io):
        raise ValueError('capture/codec error or inconsistent signal count')
    if any(a['phase'] > b['phase'] for a, b in zip(rows, rows[1:])):
        raise ValueError('capture restarted or phase reversed')
    finished = [(row, values) for row, values in zip(rows, signal) if row['phase'] == 5]
    if len(finished) < 2 or rows[-1]['phase'] != 5:
        raise ValueError('missing stable finite completion')
    final, values = finished[-1]
    if (any(pair != finished[-1] for pair in finished) or final['dma'] & 3 != 3 or final['dma'] & 0x7c or
            not 0x4ff00000 <= final['end'] < 0x4ff28000 or final['end'] % 64 or
            any(final[key] != 1 for key in ('parked', 'codec_off', 'stopped', 'returned', 'erased')) or final['samples'] != 512):
        raise ValueError('incomplete EOF/ownership/erase evidence')
    if (values['active'] > 15 or values['clipped'] > 512 or
            any(values['peak' + str(i)] > 32768 or values['span' + str(i)] > 65535 for i in range(4))):
        raise ValueError('invalid PCM statistics')
    active = sum(1 << i for i in range(4) if values['span' + str(i)] != 0)
    if active != values['active'] or any(values['span' + str(i)] > values['peak' + str(i)] * 2 for i in range(4)):
        raise ValueError('inconsistent slot statistics')
    if muted:
        if any(values.values()):
            raise ValueError('muted ADC did not yield all-zero PCM')
    elif bin(active).count('1') < 2 or values['clipped'] > 16:
        raise ValueError('insufficient varying unclipped input slots')
    return {'scope': 'finite ES7210 TDM acquisition; no acoustic/slot mapping qualification',
            'muted_control': muted, 'records': len(rows), 'completed_records': len(finished), 'final': final, 'signal': values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--muted', action='store_true')
    args = parser.parse_args()
    raw = (args.capture / 'serial.log').read_bytes()
    metadata = json.loads((args.capture / 'result.json').read_text())
    audit = json.loads((args.capture / 'candidate/retained-loader-audit.json').read_text())
    option_bytes = (args.capture / 'candidate/native_options.zig').read_bytes()
    options = option_bytes.decode()
    receipt = json.loads((args.capture / 'candidate/network-receipt.json').read_text())
    if (not metadata['written'] or not metadata['restored'] or metadata['native_fail'] or
            metadata['serial_sha256'] != hashlib.sha256(raw).hexdigest() or
            metadata['app_sha256'] != hashlib.sha256((args.capture / 'candidate/nihos-native.bin').read_bytes()).hexdigest() or
            metadata['app_sha256'] != audit['image_sha256'] or
            receipt['artifacts']['nihos-native.bin'] != metadata['app_sha256'] or
            receipt['artifacts']['native_options.zig'] != hashlib.sha256(option_bytes).hexdigest() or
            audit.get('rtos_linked') is not False or audit.get('memory', {}).get('profile') != 'device' or
            'pub const microphone = true;' not in options or
            'pub const microphone_muted = ' + str(args.muted).lower() + ';' not in options):
        raise ValueError('capture/restore/image/mode mismatch')
    result = check(raw.decode('utf-8', errors='replace'), args.muted)
    result.update(evidence='physical-device capture', app_sha256=metadata['app_sha256'], serial_sha256=metadata['serial_sha256'])
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Finite microphone DMA/ownership/erase and {} statistics passed'.format('muted' if args.muted else 'varying input'))


if __name__ == '__main__':
    main()

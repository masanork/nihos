#!/usr/bin/env python3
"""Check finite UART1 loopback/timeout or peer results without conflating them."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('finite_audio', Path(__file__).with_name('check-native-audio.py'))
AUDIO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIO)
FIELDS = ('phase', 'fault', 'tx', 'rx', 'raw', 'tx_idle', 'dir_low', 'stopped', 'matched')
IO_FIELDS = ('stage', 'a', 'b', 'c')
MODES = {'loopback': 1, 'peer': 2, 'no-loopback': 3}


def check(log, mode='loopback'):
    if mode not in MODES or log.count('ESP-ROM:esp32p4') != 1 or 'NIHOS_NATIVE_FAIL' in log or 'NIHOS_NATIVE_TRAP' in log:
        raise ValueError('invalid mode, missing single boot or native failure')
    rows = AUDIO.records(log, 'NIHOS_NATIVE_RS485', FIELDS)
    io = AUDIO.records(log, 'NIHOS_NATIVE_RS485_IO', IO_FIELDS)
    if any(row['stage'] for row in io):
        raise ValueError('native UART register/setup failure')
    if any(a['phase'] > b['phase'] for a, b in zip(rows, rows[1:])):
        raise ValueError('transaction restarted or phase reversed')
    terminal = 8 if mode == 'no-loopback' else 7
    finished = [row for row in rows if row['phase'] == terminal]
    if len(finished) < 2 or rows[-1]['phase'] != terminal or any(row != finished[-1] for row in finished):
        raise ValueError('missing stable terminal state')
    final = finished[-1]
    negative = mode == 'no-loopback'
    if (any(row['phase'] > terminal or (row['fault'] and (not negative or row['fault'] != 4 or row['phase'] != 8)) for row in rows) or
            final['fault'] != (4 if negative else 0) or final['tx'] != 64 or final['rx'] != (0 if negative else 64) or
            final['raw'] != 0 or final['tx_idle'] != 1 or final['dir_low'] != 1 or final['stopped'] != 1 or
            final['matched'] != (0 if negative else 1)):
        raise ValueError('incomplete FIFO/shift-idle/direction/cleanup evidence or unexpected result')
    return {'scope': ('external peer diagnostic reply verified by device; independent peer receipt still required'
                      if mode == 'peer' else 'internal UART controller only; external RS485 transceiver/wire unqualified'),
            'mode': mode, 'records': len(rows), 'terminal_records': len(finished), 'final': final}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--mode', choices=MODES, default='loopback')
    args = parser.parse_args()
    raw = (args.capture / 'serial.log').read_bytes()
    metadata = json.loads((args.capture / 'result.json').read_text())
    audit = json.loads((args.capture / 'candidate/retained-loader-audit.json').read_text())
    options = (args.capture / 'candidate/native_options.zig').read_bytes()
    receipt = json.loads((args.capture / 'candidate/network-receipt.json').read_text())
    if (not metadata['written'] or not metadata['restored'] or metadata['native_fail'] or
            metadata['serial_sha256'] != hashlib.sha256(raw).hexdigest() or
            metadata['app_sha256'] != hashlib.sha256((args.capture / 'candidate/nihos-native.bin').read_bytes()).hexdigest() or
            metadata['app_sha256'] != audit['image_sha256'] or receipt['artifacts']['nihos-native.bin'] != metadata['app_sha256'] or
            receipt['artifacts']['native_options.zig'] != hashlib.sha256(options).hexdigest() or
            audit.get('rtos_linked') is not False or audit.get('memory', {}).get('profile') != 'device' or
            b'pub const rs485 = true;' not in options or
            ('pub const rs485_mode: u32 = {};'.format(MODES[args.mode])).encode() not in options):
        raise ValueError('capture/restore/image/mode mismatch')
    result = check(raw.decode('utf-8', errors='replace'), args.mode)
    result.update(evidence='physical-device capture', app_sha256=metadata['app_sha256'], serial_sha256=metadata['serial_sha256'])
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Finite {} evidence passed; scope: {}'.format(args.mode, result['scope']))


if __name__ == '__main__':
    main()

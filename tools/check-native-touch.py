#!/usr/bin/env python3
"""Check normal pointer/view serial evidence; optical/negative gestures stay separate."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name('check-native-' + name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


TIME = module('time')


def check(log):
    if log.count('ESP-ROM:esp32p4') != 1 or any(word in log for word in ('NIHOS_NATIVE_FAIL', 'NIHOS_NATIVE_TRAP', 'NIHOS_C6_BOOT')):
        raise ValueError('mixed boot or native failure')
    status = TIME.rows(log, 'NIHOS_NATIVE_TOUCH_INPUT', ('status', 'panel', 'width', 'height', 'slots', 'polls', 'fresh', 'errors', 'error_code', 'max_poll_us'))
    ready = [row for row in status if row['status'] == 1]
    if (len(ready) < 2 or status[-1]['status'] != 1 or
            any(row['errors'] or row['error_code'] or row['status'] not in (0, 1) for row in status) or
            any(row['panel'] not in (1, 2, 3) or (row['width'], row['height']) != (720, 1280) or not 1 <= row['slots'] <= 10 for row in ready) or
            any(row['panel'] != ready[0]['panel'] or row['slots'] != ready[0]['slots'] for row in ready) or
            any(a[key] > b[key] for a, b in zip(ready, ready[1:]) for key in ('polls', 'fresh', 'max_poll_us')) or
            ready[-1]['polls'] <= ready[0]['polls'] or not ready[-1]['fresh'] or not ready[-1]['max_poll_us']):
        raise ValueError('touch not ready, stable, sampled or error-free')
    pointer = TIME.rows(log, 'NIHOS_NATIVE_POINTER', ('down', 'move', 'up', 'cancel', 'multi', 'overflow', 'quadrants', 'queued'))
    final = pointer[-1]
    if (final['down'] < 2 or final['up'] < 2 or final['queued'] or
            any(row['overflow'] or row['quadrants'] & ~15 or row['queued'] > 8 for row in pointer) or
            any(a[key] > b[key] for a, b in zip(pointer, pointer[1:]) for key in ('down', 'move', 'up', 'cancel', 'multi', 'overflow')) or
            any(a['quadrants'] & ~b['quadrants'] for a, b in zip(pointer, pointer[1:]))):
        raise ValueError('missing down/up, undrained queue or invalid pointer history')
    ui = TIME.rows(log, 'NIHOS_NATIVE_TOUCH_UI', ('available', 'sources', 'x', 'y', 'width', 'height'))
    if any(row['available'] != 1 or row['sources'] & 17 != 17 or
           (row['x'], row['y'], row['width'], row['height']) != (1120, 16, 144, 64) for row in ui):
        raise ValueError('touch UI unavailable or wrong bounds/capability')
    keys = TIME.rows(log, 'NIHOS_NATIVE_DIAGNOSTIC_KEY', ('sequence', 'source', 'action', 'modifiers', 'usage', 'accepted', 'view'))
    touch = [row for row in keys if row['source'] == 5]
    if (len(touch) < 2 or len(touch) > min(final['down'], final['up']) or
            any(row['accepted'] != 1 or row['modifiers'] or row['usage'] != 1 or
                (row['action'], row['view']) not in ((1, 1), (2, 0)) for row in touch) or
            any(a['sequence'] >= b['sequence'] or a['view'] == b['view'] for a, b in zip(touch, touch[1:]))):
        raise ValueError('missing accepted alternating touch view actions')
    progress = TIME.rows(log, 'NIHOS_NATIVE_NETWORK_UI', ('frames', 'ticks0', 'ticks1'))
    board = TIME.rows(log, 'NIHOS_NATIVE_DEVICES', ('errors', 'samples'))
    imu = TIME.rows(log, 'NIHOS_NATIVE_IMU', ('initialized', 'fault', 'valid', 'samples', 'sensor_error'))
    if (len(progress) < 2 or any(progress[-1][key] <= progress[0][key] for key in ('frames', 'ticks0', 'ticks1')) or
            any(row['errors'] for row in board) or board[-1]['samples'] <= board[0]['samples'] or
            any(row['fault'] or row['sensor_error'] for row in imu) or
            imu[-1]['initialized'] != 1 or imu[-1]['valid'] != 1 or imu[-1]['samples'] <= imu[0]['samples']):
        raise ValueError('board/IMU error or stopped display/hart/sensor')
    return {'scope': 'normal single-contact down/up and alternating view actions; optical correctness and negative gestures require operator evidence',
            'touch_final': ready[-1], 'pointer_final': final, 'touch_actions': touch,
            'ui_first': progress[0], 'ui_final': progress[-1],
            'all_quadrants_observed': final['quadrants'] == 15}


def qualify(root):
    metadata = json.loads((root / 'result.json').read_text())
    candidate = root / 'candidate'
    audit = json.loads((candidate / 'retained-loader-audit.json').read_text())
    receipt = json.loads((candidate / 'network-receipt.json').read_text())
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    if (metadata.get('written') is not True or metadata.get('restored') is not True or metadata.get('error') or
            digest(root / 'serial.log') != metadata['serial_sha256'] or
            digest(candidate / 'nihos-native.bin') != metadata['app_sha256'] or
            digest(candidate / 'nihos-native.elf') != metadata['elf_sha256'] or
            digest(candidate / 'qualification-source.tar.gz') != metadata['source_archive_sha256'] or
            audit['image_sha256'] != metadata['app_sha256'] or audit['elf_sha256'] != metadata['elf_sha256'] or
            receipt['sdk_dirty'] or audit['heap']['bytes'] < 49152 or
            any(digest(candidate / name) != receipt['artifacts'][name] for name in ('nihos-native.bin', 'nihos-native.elf', 'native_options.zig'))):
        raise ValueError('candidate/log/archive/restore identity mismatch')
    options = (candidate / 'native_options.zig').read_text()
    if any('pub const ' + key + ' = true;' not in options for key in ('devices', 'network', 'console_live')):
        raise ValueError('not the normal connected device profile')
    with tarfile.open(candidate / 'qualification-source.tar.gz', 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) != len(receipt['sources']) or {item.name for item in members} != set(receipt['sources']):
            raise ValueError('source archive inventory mismatch')
        for item in members:
            if not item.isfile() or hashlib.sha256(archive.extractfile(item).read()).hexdigest() != receipt['sources'][item.name]:
                raise ValueError('source archive content mismatch')
    result = check((root / 'serial.log').read_text(errors='replace'))
    result.update(evidence='physical-device serial capture', commit=metadata['commit'],
                  image_sha256=metadata['app_sha256'], serial_sha256=metadata['serial_sha256'], restored=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    args.report.write_text(json.dumps(qualify(args.capture), indent=2) + '\n')
    print('Normal touch serial evidence passed; optical/negative gesture confirmation stays separate')


if __name__ == '__main__':
    main()

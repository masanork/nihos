#!/usr/bin/env python3
"""Run the opt-in Tab5 SD stop-notification fixture and restore prior Flash.

No card formatting/writes. Physical card removal and power cycling are separate
manual qualifications. Output contains a full private Flash backup (mode 600).
"""
import argparse
import contextlib
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_bundle(candidate, loader, root):
    bundle = json.loads((candidate / 'qualification-bundle.json').read_text())
    required = {
        'candidate': {'nihos-native.bin', 'nihos-native.elf', 'image-audit.json', 'sqlite-manifest.json', 'native_options.zig', 'native-layout.ld'},
        'loader': {'bootloader.bin', 'bootloader.elf', 'partition-table.bin', 'loader-sdkconfig.h'},
        'source': {'tools/qualify-storage-io.py', 'tools/check-native-log.py', 'tools/check-native-image.py',
                   'tools/native-sqlite-manifest.py', 'tools/native-cold-policy.json'},
    }
    for key, names in required.items():
        if not names <= set(bundle.get(key, {})):
            raise ValueError('Incomplete frozen qualification bundle: ' + key)
    for directory, key in ((candidate, 'candidate'), (loader, 'loader'), (root, 'source')):
        for name, expected in bundle[key].items():
            path = (directory / name).resolve()
            if not path.is_relative_to(directory.resolve()) or digest(path) != expected:
                raise ValueError('Frozen qualification artifact differs: ' + key + '/' + name)
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--loader', type=Path, required=True, help='Frozen audited loader directory')
    parser.add_argument('--output', type=Path, required=True, help='New private directory, must not exist')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    # Validate artifacts and source before taking or resetting the device.
    candidate, loader, out = args.candidate.resolve(), args.loader.resolve(), args.output.resolve()
    validate_bundle(candidate, loader, root)
    audit = json.loads((candidate / 'image-audit.json').read_text())
    if (audit.get('io_lifetimes', {}).get('qualification') is not True or
            audit.get('memory', {}).get('profile') != 'device' or
            digest(candidate / 'nihos-native.bin') != audit.get('image_sha256') or
            digest(candidate / 'nihos-native.elf') != audit.get('elf_sha256') or
            digest(loader / 'loader-sdkconfig.h') != audit.get('loader_config', {}).get('config_sha256') or
            digest(loader / 'bootloader.elf') != audit.get('loader', {}).get('elf_sha256')):
        raise ValueError('Candidate/loader identity or lifetime qualification mismatch')
    for name, expected in audit['io_lifetimes']['sources'].items():
        if digest(root / name) != expected:
            raise ValueError('Source differs from candidate: ' + name)
    spec = importlib.util.spec_from_file_location('native_check', root / 'tools/check-native-log.py')
    check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check)
    out.mkdir(parents=True, mode=0o700, exist_ok=False)
    for name in ('nihos-native.bin', 'nihos-native.elf', 'image-audit.json', 'sqlite-manifest.json', 'native_options.zig'):
        shutil.copy2(candidate / name, out / name)
    for name in ('bootloader.bin', 'bootloader.elf', 'partition-table.bin', 'loader-sdkconfig.h'):
        shutil.copy2(loader / name, out / name)
    # Imports are deferred so --help needs no device dependencies.
    import esptool
    import serial
    from esptool.reset import HardReset
    owners = subprocess.run(['lsof', '-t', args.port], capture_output=True, text=True, check=False)
    if owners.stdout.strip():
        raise RuntimeError('Serial already in use: ' + owners.stdout.strip())
    results = []
    with serial.Serial(args.port, 115200, timeout=.2, exclusive=True) as port:
        def connect():
            port.baudrate = 115200
            return esptool.detect_chip(port=port, baud=115200)

        def command(name, arguments):
            esp = connect()
            print(name, flush=True)
            with (out / (name + '.log')).open('w') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                esptool.main(['--chip', 'esp32p4', '--baud', '460800', '--after', 'no_reset', *arguments], esp=esp)

        esp = connect()
        identity = {'chip': esp.get_chip_description(), 'mac': ':'.join(f'{b:02x}' for b in esp.read_mac())}
        (out / 'device.json').write_text(json.dumps(identity, indent=2) + '\n')
        if identity != {'chip': 'ESP32-P4 (revision v1.3)', 'mac': 'e8:f6:0a:e2:e8:9c'}:
            raise RuntimeError('Unexpected device; no Flash written')
        backup = out / 'flash-before.bin'
        backup.touch(mode=0o600)
        command('backup-before', ['read_flash', '0', '0x1000000', str(backup)])
        if backup.stat().st_size != 16 << 20:
            raise RuntimeError('Incomplete Flash backup')
        raw = backup.read_bytes()
        table = (out / 'partition-table.bin').read_bytes()
        if raw[0x8000:0x8000 + len(table)] != table:
            raise RuntimeError('Partition table differs; no Flash written')
        app_size = (out / 'nihos-native.bin').stat().st_size
        loader_size = (out / 'bootloader.bin').stat().st_size
        if not 0 < loader_size <= 0x6000 or not 0 < app_size < 0x100000:
            raise RuntimeError('Candidate exceeds this qualification layout')
        # Only the erase-aligned spans touched by the candidate need rewriting.
        old_loader, old_app = out / 'loader-before.bin', out / 'app-before.bin'
        for path, data in ((old_loader, raw[0x2000:0x8000]),
                           (old_app, raw[0x10000:0x10000 + ((app_size + 4095) & ~4095)])):
            path.touch(mode=0o600)
            path.write_bytes(data)
        (out / 'backup.json').write_text(json.dumps({'flash_sha256': digest(backup), 'bytes': len(raw)}, indent=2) + '\n')
        changed = False
        try:
            changed = True  # Even a partial write must enter restoration.
            command('write-candidate', ['write_flash', '0x2000', str(out / 'bootloader.bin'),
                                       '0x10000', str(out / 'nihos-native.bin')])
            verify = ['verify_flash', '0x2000', str(out / 'bootloader.bin'), '0x8000', str(out / 'partition-table.bin'),
                      '0x10000', str(out / 'nihos-native.bin')]
            command('verify-candidate-before', verify)
            for run in range(1, 4):
                port.baudrate = 115200
                port.dtr = False
                port.reset_input_buffer()
                HardReset(port, uses_usb=True)()
                began = time.monotonic()
                raw_log = bytearray()
                passed_at = None
                path = out / f'boot{run}.log'
                while time.monotonic() - began < 180:
                    raw_log.extend(port.read(max(1, port.in_waiting)))
                    path.write_bytes(raw_log)
                    if b'NIHOS_NATIVE_FAIL' in raw_log or b'NIHOS_NATIVE_TRAP' in raw_log:
                        raise RuntimeError(f'Native failure; see {path}')
                    if b'NIHOS_NATIVE_FP_PASS' in raw_log and passed_at is None:
                        passed_at = time.monotonic()
                    if passed_at and time.monotonic() - passed_at >= 10:
                        break
                report = check.check(raw_log.decode(errors='replace'), 'sqlite', 32 << 20, audit,
                                     'physical-device', require_sdmmc_fast=True, require_storage=True)
                if passed_at is None or report['io_lifetimes'] is None:
                    raise RuntimeError('Incomplete lifetime qualification')
                results.append({'run': run, 'log_sha256': digest(path), 'report': report})
                (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
                print(f'boot {run}: passed', flush=True)
            command('verify-candidate-after', verify)
        finally:
            if changed:
                command('restore-before', ['write_flash', '0x2000', str(old_loader), '0x10000', str(old_app)])
                command('verify-restored-full-flash', ['verify_flash', '0', str(backup)])
                (out / 'restored.json').write_text(json.dumps({'verified': True, 'sha256': digest(backup)}) + '\n')
                port.baudrate = 115200
                HardReset(port, uses_usb=True)()
        (out / 'complete.json').write_text(json.dumps({'passed': len(results) == 3, 'restored': True,
                'exclusive_serial': True, 'electrical_removal_tested': False, 'power_cycle_tested': False}) + '\n')


if __name__ == '__main__':
    main()

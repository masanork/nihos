#!/usr/bin/env python3
"""Run the dedicated canvas fixture and restore Flash; private backup included."""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from native_serial import capture_serial_class, disable_hangup
from prepare_canvas_candidate import inspect


def digest(data):
    return hashlib.sha256(data).hexdigest()


def restore_spans(raw, loader_size, app_size, partition):
    if len(raw) != 16 * 1024 * 1024:
        raise ValueError('full Flash backup must be exactly 16 MiB')
    if not 0 < len(partition) <= 0x1000 or not 0 < loader_size <= 0x6000 or not 0 < app_size <= 0x100000:
        raise ValueError('candidate exceeds bootloader or factory partition')
    if raw[0x8000:0x8000 + len(partition)] != partition:
        raise ValueError('candidate partition table differs from device; no write allowed')
    app_end = 0x10000 + ((app_size + 4095) & ~4095)
    return raw[0x2000:0x8000], raw[0x10000:app_end]


def with_restoration(operation, restore):
    """Once called, restore even when installation is interrupted or partial."""
    try:
        return operation()
    finally:
        restore()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('build', type=Path)
    parser.add_argument('output', type=Path, help='new private directory; contains full Flash backup')
    parser.add_argument('--observe-seconds', type=int, default=30)
    args = parser.parse_args()
    if not 0 <= args.observe_seconds <= 120:
        parser.error('observe-seconds must be 0..120')
    build = args.build.resolve()
    original_receipt = inspect(build)
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    frozen = out / 'candidate'
    for rel in ('nihos-native.bin', 'nihos-native.elf', 'native_options.zig', 'image-audit.json',
                'loader/bootloader/bootloader.bin', 'loader/partition_table/partition-table.bin'):
        target = frozen / rel
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(build / rel, target)
    receipt = inspect(frozen)
    for name in receipt['artifacts']:
        if receipt['artifacts'][name]['sha256'] != original_receipt['artifacts'][name]['sha256']:
            raise RuntimeError('candidate changed while copying; no device accessed')
    if (receipt['audit_sha256'] != original_receipt['audit_sha256'] or
            receipt['native_options_sha256'] != original_receipt['native_options_sha256']):
        raise RuntimeError('audit/options changed while copying; no device accessed')
    (out / 'candidate.json').write_text(json.dumps(receipt, indent=2) + '\n')
    import esptool
    import serial
    from esptool.reset import HardReset

    aliases = {args.port, args.port.replace('/cu.', '/tty.')}
    spec = importlib.util.spec_from_file_location('canvas_display_check', Path(__file__).with_name('check-native-display-log.py'))
    check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check)
    # This advisory lock coordinates this capture tool; kernel exclusivity also
    # rejects serial openers which do not honor the advisory lock.
    lock_path = Path('/tmp/nihos-tab5-e8f60ae2e89c-write.lock')
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = subprocess.run(['lsof', '-t', *sorted(aliases)], capture_output=True, text=True, check=False)
        if before.returncode not in (0, 1):
            raise RuntimeError('could not check device owners; no device access')
        if before.stdout.strip():
            raise RuntimeError('device serial is in use; no device access')
        with capture_serial_class(serial.Serial)(args.port, 115200, timeout=.2, exclusive=True) as port:
            owners = subprocess.run(['lsof', '-t', *sorted(aliases)], capture_output=True, text=True, check=False)
            if owners.returncode not in (0, 1):
                raise RuntimeError('could not recheck device owners; no device commands')
            if {int(pid) for pid in owners.stdout.split()} - {os.getpid()}:
                raise RuntimeError('another serial owner is present; no device commands')

            identity_verified = False

            def command(name, args_list):
                nonlocal identity_verified
                identity_verified = False
                port.baudrate = 115200
                esp = esptool.detect_chip(port=port, baud=115200)
                identity = {'chip': esp.get_chip_description(), 'mac': ':'.join(f'{b:02x}' for b in esp.read_mac())}
                if identity != {'chip': 'ESP32-P4 (revision v1.3)', 'mac': 'e8:f6:0a:e2:e8:9c'}:
                    raise RuntimeError('device identity mismatch; refusing Flash access')
                identity_verified = True
                with (out / (name + '.log')).open('w') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                    esptool.main(['--chip', 'esp32p4', '--baud', '460800', '--after', 'no_reset', *args_list], esp=esp)
                port.baudrate = 115200
                return identity

            backup = out / 'flash-before.bin'
            backup.touch(mode=0o600)
            try:
                identity = command('backup', ['read_flash', '0', '0x1000000', str(backup)])
                raw = backup.read_bytes()
                loader = frozen / 'loader/bootloader/bootloader.bin'
                partition = frozen / 'loader/partition_table/partition-table.bin'
                image = frozen / 'nihos-native.bin'
                old_loader, old_app = restore_spans(raw, loader.stat().st_size, image.stat().st_size, partition.read_bytes())
                (out / 'device.json').write_text(json.dumps(identity, indent=2) + '\n')
                (out / 'backup.json').write_text(json.dumps({'sha256': digest(raw), 'bytes': len(raw)}, indent=2) + '\n')
                loader_backup = out / 'loader-before.bin'
                app_backup = out / 'app-before.bin'
                loader_backup.write_bytes(old_loader)
                app_backup.write_bytes(old_app)
                command('verify-backup', ['verify_flash', '0', str(backup)])
                latest = inspect(frozen)
                if any(latest['artifacts'][key]['sha256'] != receipt['artifacts'][key]['sha256'] for key in receipt['artifacts']):
                    raise RuntimeError('retained candidate changed before install; no write')
            except BaseException as error:
                # Only reset the same verified device; no candidate write started.
                reset_done = False
                if identity_verified and port.is_open:
                    port.baudrate = 115200
                    HardReset(port, uses_usb=True)()
                    reset_done = True
                (out / 'prewrite-failure.json').write_text(json.dumps({
                    'error': str(error), 'identity_verified': identity_verified,
                    'candidate_write_started': False, 'reset_after_failure': reset_done,
                }, indent=2) + '\n')
                raise
            restored = False

            def run_candidate():
                command('install', ['write_flash', '0x2000', str(loader), '0x10000', str(image)])
                verify = ['verify_flash', '0x2000', str(loader), '0x8000', str(partition), '0x10000', str(image)]
                command('verify-candidate-before', verify)
                port.dtr = False
                port.reset_input_buffer()
                HardReset(port, uses_usb=True)()
                raw_log = bytearray()
                deadline = time.monotonic() + 120
                completed = None
                try:
                    while time.monotonic() < deadline:
                        raw_log.extend(port.read(max(1, port.in_waiting)))
                        if b'NIHOS_NATIVE_DISPLAY_IRQ_PASS ' in raw_log or b'NIHOS_NATIVE_FAIL' in raw_log:
                            if completed is None:
                                completed = time.monotonic()
                                print('Canvas fixture reached its checkpoint; inspect the screen if available.', flush=True)
                            if time.monotonic() - completed >= args.observe_seconds:
                                break
                finally:
                    (out / 'boot.raw.log').write_bytes(raw_log)
                start = raw_log.find(b'ESP-ROM:esp32p4')
                if start < 0:
                    raise RuntimeError('missing ROM banner; raw log retained')
                log = bytes(raw_log[start:]).decode('utf-8', errors='replace')
                (out / 'boot.log').write_text(log)
                audit = json.loads((frozen / 'image-audit.json').read_text())
                result = check.check(log, audit, 2, 80, canvas_demo=True)
                (out / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
                command('verify-candidate-after', verify)

            def restore():
                nonlocal restored
                try:
                    if (backup.read_bytes() != raw or loader_backup.read_bytes() != old_loader or
                            app_backup.read_bytes() != old_app):
                        raise RuntimeError('backup changed; automatic restoration refused')
                    command('restore', ['write_flash', '0x2000', str(loader_backup), '0x10000', str(app_backup)])
                    command('verify-restored-full', ['verify_flash', '0', str(backup)])
                    restored = True
                    (out / 'restored.json').write_text(json.dumps({'verified_full_flash': True, 'sha256': digest(raw)}) + '\n')
                except BaseException as error:
                    (out / 'recovery-required.json').write_text(json.dumps({'error': str(error), 'backup': str(backup), 'reset_performed': False}, indent=2) + '\n')
                    if port.is_open:
                        try:
                            disable_hangup(port)
                        except OSError:
                            pass
                    raise
                finally:
                    # Never reset a device if restoration did not verify.
                    if restored:
                        port.baudrate = 115200
                        HardReset(port, uses_usb=True)()

            with_restoration(run_candidate, restore)
            (out / 'complete.json').write_text(json.dumps({'restored': restored, 'reset': 'warm USB', 'optical': 'not evaluated'}) + '\n')
    finally:
        os.close(lock_fd)


if __name__ == '__main__':
    main()

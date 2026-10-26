#!/usr/bin/env python3
"""Install an audited display candidate and capture it under one serial lease.

Requires ESP-IDF Python (esptool, pyserial). No backup or SD commands.
--install is required to write Flash; otherwise only resets/captures the device.
"""
import argparse
import contextlib
import hashlib
import json
import shutil
from pathlib import Path
import time

import esptool
from esptool.reset import HardReset
import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('output', type=Path)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--loader', type=Path, required=True)
    parser.add_argument('--partitions', type=Path, required=True)
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--seconds', type=int, default=45)
    args = parser.parse_args()
    audit = json.loads(args.audit.read_text())
    assert audit['rtos_linked'] is False and audit['memory']['profile'] == 'device'
    assert hashlib.sha256(args.image.read_bytes()).hexdigest() == audit['image_sha256']
    args.output.mkdir(parents=True, exist_ok=True)
    paths = {'0x2000': args.loader, '0x8000': args.partitions, '0x10000': args.image}
    if args.install:
        retained = args.output / 'installed'
        retained.mkdir(exist_ok=True)
        for address, source in list(paths.items()):
            destination = retained / source.name
            shutil.copy2(source, destination)
            paths[address] = destination
        shutil.copy2(args.audit, retained / 'image-audit.json')
    manifest = {address: {'path': str(path.resolve()), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for address, path in paths.items()}
    (args.output / 'artifacts.json').write_text(json.dumps(manifest, indent=2) + '\n')
    with serial.Serial(args.port, 115200, timeout=0.1, exclusive=True) as console:
        print('Exclusive serial lease acquired', flush=True)
        def tool(action, name):
            with (args.output / name).open('w') as output, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                device = esptool.detect_chip(port=console, baud=115200)
                assert device.CHIP_NAME == 'ESP32-P4'
                argv = ['--chip', 'esp32p4', '--baud', '460800', '--after', 'hard_reset', action]
                if action == 'write_flash':
                    argv += ['--flash_mode', 'dio', '--flash_size', '16MB', '--flash_freq', '80m']
                for address, path in paths.items():
                    argv += [address, str(path)]
                esptool.main(argv, esp=device)
            console.baudrate = 115200
        if args.install:
            tool('write_flash', 'flash.log')
            tool('verify_flash', 'verify-before.log')
            tool('verify_flash', 'verify-after.log')
            print('Candidate installed and byte-verified twice; capturing final boot', flush=True)
        raw = bytearray()
        console.dtr = False
        console.reset_input_buffer()
        HardReset(console, uses_usb=True)()
        deadline = time.monotonic() + args.seconds
        completed = None
        with (args.output / 'boot.raw.log').open('wb') as output:
            while time.monotonic() < deadline:
                chunk = console.read(max(1, console.in_waiting))
                if chunk:
                    raw.extend(chunk); output.write(chunk); output.flush()
                if (b'NIHOS_NATIVE_DISPLAY_SCANOUT' in raw or b'NIHOS_NATIVE_FAIL' in raw) and completed is None:
                    completed = time.monotonic()
                if completed is not None and time.monotonic() - completed > 3:
                    break
        start = raw.find(b'ESP-ROM:esp32p4')
        cleaned = raw[start:] if start >= 0 else raw
        (args.output / 'boot.log').write_bytes(cleaned)
        for line in cleaned.decode(errors='replace').splitlines():
            if any(key in line for key in ('DISPLAY', 'FAIL', 'TRAP', 'FP_PASS', 'SPI_FAST_FLASH_BOOT')):
                print(line, flush=True)
        (args.output / 'lease-complete.json').write_text(json.dumps({
            'exclusive': True, 'installed': args.install, 'postverified': args.install,
            'backup_requested': False, 'rom_banner': start >= 0,
        }, indent=2) + '\n')
        print('Serial lease released', flush=True)


if __name__ == '__main__':
    main()

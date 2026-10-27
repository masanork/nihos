#!/usr/bin/env python3
"""Install an audited display candidate and capture it under one serial lease.

Requires ESP-IDF Python (esptool, pyserial). No backup or SD commands.
--install is required to write Flash; otherwise only resets/captures the device.
"""
import argparse
import contextlib
import errno
import hashlib
import json
import re
import shutil
from pathlib import Path
import time

import esptool
from esptool.reset import HardReset
import serial


def acquire_port(port, wait_seconds):
    deadline = time.monotonic() + wait_seconds
    waiting = False
    while True:
        try:
            return serial.Serial(port, 115200, timeout=0.1, exclusive=True)
        except serial.SerialException as error:
            if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK) or time.monotonic() >= deadline:
                raise
            if not waiting:
                print('Serial busy; waiting for its owner to release the lease', flush=True)
                waiting = True
            time.sleep(min(1, max(0, deadline - time.monotonic())))


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
    parser.add_argument('--complete-marker', default='NIHOS_NATIVE_DISPLAY_SCANOUT')
    parser.add_argument('--linger', type=float, default=3)
    parser.add_argument('--exercise-live', action='store_true', help='Exercise diagnostic serial Esc, splash, pause/resume, and logs')
    parser.add_argument('--exercise-normal', action='store_true', help='After READY, exercise console/splash/console without pausing boot')
    parser.add_argument('--exercise-failure', action='store_true', help='Exercise Esc and rejected splash/resume/pause after an injected failure')
    parser.add_argument('--serial-wait', type=int, default=0, help='Seconds to wait for an existing exclusive owner')
    args = parser.parse_args()
    assert args.serial_wait >= 0
    assert sum((args.exercise_live, args.exercise_normal, args.exercise_failure)) <= 1
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
    with acquire_port(args.port, args.serial_wait) as console:
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
        reset_requested = time.monotonic()
        HardReset(console, uses_usb=True)()
        reset_returned = time.monotonic()
        observations = {}
        markers = (b'ESP-ROM:esp32p4', b'NIHOS_NATIVE_BOOT backend=', b'NIHOS_NATIVE_UI_START ', b'NIHOS_NATIVE_UI_READY ', b'NIHOS_NATIVE_UI_SETTLED ', b'NIHOS_NATIVE_FAIL ')
        deadline = time.monotonic() + args.seconds
        completed = None
        exercise = 0
        due = None
        sent = []
        commands = (b'\x1b', b'\x0c', b'\x02', b'\x12', b'\x0c', b'\x1b')
        failure_commands = (b'\x1b', b'\x0c', b'\x12', b'\x02')
        def key_seen(action):
            return re.search(rb'NIHOS_NATIVE_DIAGNOSTIC_KEY sequence=[0-9a-f]{8} source=00000001 action=' + f'{action:08x}'.encode() + rb' modifiers=[0-9a-f]{8} usage=[0-9a-f]{8} accepted=00000001', raw) is not None
        with (args.output / 'boot.raw.log').open('wb') as output:
            while time.monotonic() < deadline:
                chunk = console.read(max(1, console.in_waiting))
                if chunk:
                    raw.extend(chunk); output.write(chunk); output.flush()
                    for marker in markers:
                        name = marker.decode().strip()
                        if name not in observations and marker in raw:
                            observations[name] = time.monotonic() - reset_requested
                if args.exercise_live and exercise < 6:
                    ready = (b'NIHOS_NATIVE_UI_START ' in raw if exercise == 0 else
                             key_seen(1) if exercise == 1 else key_seen(2) if exercise == 2 else
                             b'NIHOS_NATIVE_UI_PAUSE ' in raw if exercise == 3 else
                             b'NIHOS_NATIVE_UI_READY ' in raw if exercise == 4 else
                             b'NIHOS_NATIVE_UI_SETTLED ' in raw)
                    if ready and due is None: due = time.monotonic() + (0.2 if exercise == 0 else 0.4)
                    if due is not None and time.monotonic() >= due:
                        console.write(commands[exercise]); console.flush()
                        sent.append(commands[exercise].hex()); exercise += 1; due = None
                if args.exercise_normal and exercise < 3:
                    ready = (b'NIHOS_NATIVE_UI_READY ' in raw if exercise == 0 else
                             key_seen(1) if exercise == 1 else b'NIHOS_NATIVE_UI_SETTLED ' in raw)
                    if ready and due is None: due = time.monotonic() + 0.4
                    if due is not None and time.monotonic() >= due:
                        command = (b'\x1b', b'\x0c', b'\x1b')[exercise]
                        console.write(command); console.flush()
                        sent.append(command.hex()); exercise += 1; due = None
                if args.exercise_failure and exercise < len(failure_commands):
                    if b'NIHOS_NATIVE_UI_FAILURE visible=1 scheduler=stopped' in raw and due is None:
                        due = time.monotonic() + 0.4
                    if due is not None and time.monotonic() >= due:
                        console.write(failure_commands[exercise]); console.flush()
                        sent.append(failure_commands[exercise].hex()); exercise += 1; due = None
                if (args.complete_marker.encode() in raw or b'NIHOS_NATIVE_FAIL' in raw) and completed is None:
                    completed = time.monotonic()
                if completed is not None and time.monotonic() - completed > args.linger:
                    break
        start = raw.find(b'ESP-ROM:esp32p4')
        cleaned = raw[start:] if start >= 0 else raw
        (args.output / 'boot.log').write_bytes(cleaned)
        for line in cleaned.decode(errors='replace').splitlines():
            if any(key in line for key in ('DISPLAY', 'FAIL', 'TRAP', 'FP_PASS', 'SPI_FAST_FLASH_BOOT', 'NATIVE_UI', 'NATIVE_KEYBOARD', 'DIAGNOSTIC_KEY')):
                print(line, flush=True)
        (args.output / 'lease-complete.json').write_text(json.dumps({
            'exclusive': True, 'installed': args.install, 'postverified': args.install,
            'backup_requested': False, 'rom_banner': start >= 0,
            'completion_marker': args.complete_marker, 'exercise_live': args.exercise_live, 'exercise_normal': args.exercise_normal, 'keys_sent': sent,
            'marker_receive_seconds_from_reset_request': observations,
            'reset_call_seconds': reset_returned - reset_requested,
            'timing_scope': 'host serial receive timestamps; includes reset pulse and USB buffering; not cold power-on time',
            'exercise_failure': args.exercise_failure,
        }, indent=2) + '\n')
        print('Serial lease released', flush=True)


if __name__ == '__main__':
    main()

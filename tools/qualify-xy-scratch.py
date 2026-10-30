#!/usr/bin/env python3
"""Bounded synthetic RAM-workspace check under exclusive Tab5 ownership.

--install explicitly replaces firmware. No SD formatting/writes or backups.
Serial traces prove document state and completed repaint submission, not pixels.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import time
import normal_fs_manifest
from native_serial import capture_serial_class, disable_hangup

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('build', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    build = args.build.resolve()
    manifest = json.loads((build / 'normal-fs-manifest.json').read_text())
    normal_fs_manifest.verify_files(build, manifest)
    options = (build / 'native_options.zig').read_text()
    if any(f'pub const {flag} = true;' not in options for flag in ('xy_workspace', 'xy_trace')):
        raise ValueError('an xy trace candidate is required')
    audit = json.loads((build / 'image-audit.json').read_text())
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    if audit['memory']['profile'] != 'device' or sha(build / 'nihos-native.elf') != audit['elf_sha256'] or sha(build / 'nihos-native.bin') != audit['image_sha256']:
        raise ValueError('candidate identity mismatch')
    runpy.run_path(str(ROOT / 'tools/check-native-image.py'))['audit']((build / 'nihos-native.elf').read_bytes(), (build / 'nihos-native.bin').read_bytes(), 'integer', 'device', normal_fs_manifest=manifest)
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    frozen = out / 'candidate'
    frozen.mkdir(mode=0o700)
    paths = {'0x2000': build / 'loader/bootloader/bootloader.bin', '0x8000': build / 'loader/partition_table/partition-table.bin', '0x10000': build / 'nihos-native.bin'}
    for address, path in list(paths.items()):
        target = frozen / path.name
        shutil.copyfile(path, target)
        if sha(target) != sha(path):
            raise RuntimeError('candidate changed while freezing')
        paths[address] = target
    for name in ('image-audit.json', 'nihos-native.elf', 'normal-fs-manifest.json', 'native_options.zig'):
        shutil.copyfile(build / name, frozen / name)
    shutil.copyfile(__file__, out / 'qualification-tool.py')
    receipt = {'passed': False, 'evidence': 'physical Tab5 RAM workspace', 'source_base': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'installed': False, 'physical_pixel_comparison_tested': False, 'scheme_vm_tested': False,
        'persistence_tested': False, 'cold_power_cycle_tested': False, 'observations': [],
        'candidate': {p.name: sha(p) for p in frozen.iterdir()}}
    save = lambda: (out / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    save()
    import serial
    import esptool
    from esptool.reset import HardReset
    spec = importlib.util.spec_from_file_location('usb_capture', ROOT / 'tools/capture-native-usb.py')
    usb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(usb)
    lock = os.open('/tmp/nihos-tab5-e8f60ae2e89c-write.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        owners = subprocess.run(['lsof', '-t', args.port, args.port.replace('/cu.', '/tty.')], capture_output=True, text=True)
        if owners.returncode not in (0, 1) or owners.stdout.strip():
            raise RuntimeError('serial ownership unavailable')
        with capture_serial_class(serial.Serial)(args.port, 115200, timeout=.1, exclusive=True) as port:
            disable_hangup(port)
            import contextlib
            with (out / 'identity.log').open('w') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                device = esptool.detect_chip(port=port, baud=115200)
                mac = ':'.join(f'{n:02x}' for n in device.read_mac())
                chip, flash = device.get_chip_description(), device.flash_id()
            receipt['device'] = {'mac': mac, 'chip': chip, 'flash_id': flash}
            if mac != 'e8:f6:0a:e2:e8:9c' or not chip.startswith('ESP32-P4') or flash >> 16 != 0x18:
                raise RuntimeError('unexpected device; no writes permitted')
            if args.install:
                usb.tool(port, out / 'install.log', 'write_flash', paths)
                receipt['installed'] = True
                save()
            usb.tool(port, out / 'verify-before.log', 'verify_flash', paths)
            with (out / 'capture.log').open('wb') as capture:
                raw = bytearray()
                def wait(predicate):
                    deadline = time.monotonic() + 45
                    while time.monotonic() < deadline:
                        data = port.read(max(1, port.in_waiting))
                        if data:
                            raw.extend(data); capture.write(data); capture.flush()
                        if b'NIHOS_NATIVE_FAIL' in raw:
                            raise RuntimeError('native fault; retaining state')
                        found = predicate(raw)
                        if found is not None:
                            return found
                    raise TimeoutError('bounded xy phase timed out')
                def record(data, marker):
                    matches = re.findall(rb'(?m)^' + marker + rb' ([^\r\n]+)\r?\n', data)
                    return {k.decode(): int(v, 16) for k, v in re.findall(rb'(\w+)=([0-9a-f]{8})(?:\s|$)', matches[-1])} if matches else None
                def fnv(data):
                    value = 0x811c9dc5
                    for byte in data: value = ((value ^ byte) * 0x01000193) & 0xffffffff
                    return value
                def expect(label, text, cursor, mode=0, start=0, buffer_kind=0, buffer_hash=None):
                    def matches(data):
                        row = record(data[start:], b'NIHOS_NATIVE_XY_STATE')
                        return row if row and row['bytes'] == len(text) and row['cursor'] == cursor and row['fnv'] == fnv(text) and row['mode'] == mode and row['frames'] > 0 and row['buffer_kind'] == buffer_kind and (not buffer_kind or row['buffer_bytes'] > 0) and (buffer_hash is None or row['buffer_hash'] == buffer_hash) else None
                    row = wait(matches)
                    receipt['observations'].append({'name': label, **row}); save()
                    print(label + ': document and cursor matched', flush=True)
                    return row
                def boot(label):
                    raw.clear(); port.reset_input_buffer(); port.dtr = False
                    HardReset(port, uses_usb=True)()
                    wait(lambda data: record(data, b'NIHOS_NATIVE_XY_READY'))
                    if raw.count(b'ESP-ROM:esp32p4') != 1 or b'NIHOS_NATIVE_SESSION_READY' in raw:
                        raise RuntimeError('unexpected boot or launcher handoff')
                    expect(label, b'', 0)
                def send(label, data, text, cursor, mode=0, buffer_kind=0, buffer_hash=None):
                    start = len(raw)
                    port.write(data); port.flush()
                    return expect(label, text, cursor, mode, start, buffer_kind, buffer_hash)
                boot('xy-boot')
                original = b'ab\ncd'
                send('serial-crlf', b'ab\r\ncd', original, 5)
                send('left', b'\x1b[D', original, 4)
                send('insert', b'X', b'ab\ncXd', 5)
                send('undo', b'\x1a', original, 4)
                cluster = '葛\U000e0100'.encode()
                send('ivs-input', cluster, b'ab\nc' + cluster + b'd', 11)
                send('cluster-delete', b'\x7f', original, 4)
                send('minibuffer', b'\x1b', original, 4, 1)
                send('help', b'help\r', original, 4, 2)
                send('help-return', b'\x1b', original, 4)
                send('literal-colon', b':storage', b'ab\nc:storaged', 12)
                unchanged = b'ab\nc:storaged'
                for kind, command in enumerate((b'log', b'mem', b'tasks'), 1):
                    name = command.decode()
                    send(name + '-minibuffer', b'\x1b', unchanged, 12, 1)
                    row = send(name + '-open', command + b'\r', unchanged, 12, 3, kind)
                    send(name + '-readonly', b'X\x7f\x1a\x04\r', unchanged, 12, 3, kind, row['buffer_hash'])
                    send(name + '-refresh', b'\x0c', unchanged, 12, 3, kind)
                    send(name + '-return', b'\x1b', unchanged, 12)
                boot('warm-reset-empty-ram')
            usb.tool(port, out / 'verify-after.log', 'verify_flash', paths)
            receipt['passed'] = True; save()
            print('Physical xy boot/input/undo/help/warm-reset passed; no pixel or persistence claim', flush=True)
    except BaseException as error:
        receipt['failure'] = str(error); save(); raise
    finally:
        os.close(lock)


if __name__ == '__main__':
    main()

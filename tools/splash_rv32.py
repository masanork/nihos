#!/usr/bin/env python3
"""Compare native RV32 splash frames with an independent pixel model."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time

from canvas_frame import png_rgb565
from canvas_snapshot import ROOT, gdb_binary
from emulator_trace import source_identity
from splash_reference import reference

BUILD = ROOT / 'build/native-emulator'
OUT = BUILD / 'splash-workload'
FRAMES = tuple((f'{layout}-{name}', layout, progress, status)
               for layout in ('portrait', 'landscape')
               for name, progress, status in (('initial', 0, 5), ('intermediate', 128, 5), ('final', 255, 5),
                                               ('failed', 128, 6), ('storage', 128, 7)))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(actual, expected):
    if len(actual) != 720 * 1280 * 2 or len(expected) != len(actual):
        raise ValueError('invalid splash framebuffer length')
    if actual != expected:
        raise ValueError('RV32 splash differs from independent pixel reference')


def main():
    source = source_identity()
    env = os.environ.copy()
    env.update(NIHOS_NATIVE_CANVAS_OFFSCREEN='1', NIHOS_NATIVE_CANVAS_INTERACTIVE='0',
               NIHOS_NATIVE_CANVAS_WORKLOADS='0', NIHOS_NATIVE_CANVAS_SPLASH='1',
               NIHOS_NATIVE_QUALIFICATION='1', NIHOS_NATIVE_DISPLAY='0')
    subprocess.run(['sh', 'tools/build-native.sh', 'emulator', 'integer'], cwd=ROOT, env=env, check=True)
    emulator = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-esp-emu.sh')], text=True).strip()
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'splash.json', *(f'{n}.{ext}' for n, _, _, _ in FRAMES for ext in ('rgb565', 'png'))):
        (OUT / name).unlink(missing_ok=True)
    for name in ('nihos-native.bin', 'nihos-native.elf', 'nihos-native-flash.bin', 'image-audit.json', 'native_options.zig'):
        shutil.copyfile(BUILD / name, OUT / name)
    options = (OUT / 'native_options.zig').read_text().splitlines()
    for flag in ('pub const canvas_splash = true;', 'pub const canvas_workloads = false;', 'pub const canvas_interactive = false;'):
        if options.count(flag) != 1:
            raise RuntimeError('unexpected splash fixture option')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    with (OUT / 'emulator.log').open('wb') as uart, (OUT / 'emulator-stderr.log').open('wb') as diagnostics:
        process = subprocess.Popen([emulator, '--chip', 'esp32p4', '--firmware', str(OUT / 'nihos-native-flash.bin'),
                                    '--elf', str(OUT / 'nihos-native.elf'), '--psram-size', '32M', '--timeout', '480s',
                                    '--gdb', str(port), '--gdb-halt', '--exit-on', 'NIHOS_NATIVE_CANVAS_OFFSCREEN_PASS'],
                                   cwd=ROOT, stdout=uart, stderr=diagnostics)
        try:
            deadline = time.monotonic() + 15
            while b'GDB stub listening' not in (OUT / 'emulator-stderr.log').read_bytes():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('emulator GDB stub did not start')
                time.sleep(.1)
            command = [gdb_binary(), '-q', '-batch', str(OUT / 'nihos-native.elf'), '-ex', 'set remotetimeout 5',
                       '-ex', f'target remote 127.0.0.1:{port}', '-ex', 'break nih_canvas_frame_ready', '-ex', 'continue']
            for name, _, _, _ in FRAMES:
                command.extend(('-ex', 'continue', '-ex', f'dump binary memory {name}.rgb565 0x48030000 0x481f2000'))
            command.extend(('-ex', 'detach'))
            with (OUT / 'gdb.log').open('wb') as log:
                subprocess.run(command, cwd=OUT, stdout=log, stderr=subprocess.STDOUT, timeout=420, check=True)
            if (OUT / 'gdb.log').read_text(errors='replace').count('Breakpoint 1, main.nih_canvas_frame_ready') != len(FRAMES) + 1:
                raise RuntimeError('unexpected frame rendezvous count')
            if process.wait(timeout=30) != 0:
                raise RuntimeError('emulator failed')
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
    subprocess.run(['python3', str(ROOT / 'tools/check-canvas-offscreen.py'), str(OUT)], cwd=ROOT, check=True)
    frames = {}
    for name, layout, progress, status in FRAMES:
        raw = (OUT / (name + '.rgb565')).read_bytes()
        expected = reference(layout, progress, status)
        verify(raw, expected)
        png = png_rgb565(raw, 720, 1280)
        (OUT / (name + '.png')).write_bytes(png)
        frames[name] = {'rgb565_sha256': hashlib.sha256(raw).hexdigest(),
                        'reference_sha256': hashlib.sha256(expected).hexdigest(), 'png_sha256': hashlib.sha256(png).hexdigest()}
    if source_identity() != source:
        raise RuntimeError('source changed during splash workload')
    report = {'evidence': 'esp32p4-emulator-rv32', 'scope': 'splash fixture with independent pixel reference; not panel or physical timing evidence',
              'width': 720, 'height': 1280, 'source': source, 'elf_sha256': sha(OUT / 'nihos-native.elf'),
              'image_sha256': sha(OUT / 'nihos-native.bin'), 'emulator_sha256': sha(Path(emulator)), 'frames': frames}
    (OUT / 'splash.json').write_text(json.dumps(report, indent=2) + '\n')
    print('RV32 splash frames match independent pixel references:', OUT / 'splash.json')


if __name__ == '__main__':
    main()

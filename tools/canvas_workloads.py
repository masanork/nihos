#!/usr/bin/env python3
"""Compare RV32 Canvas workload pixels against independent host references."""
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
from canvas_workload_reference import WIDTH, HEIGHT, verify
from emulator_trace import source_identity

BUILD = ROOT / 'build/native-emulator'
OUT = BUILD / 'canvas-workloads'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source = source_identity()
    env = os.environ.copy()
    env.update(NIHOS_NATIVE_CANVAS_OFFSCREEN='1', NIHOS_NATIVE_CANVAS_INTERACTIVE='0',
               NIHOS_NATIVE_CANVAS_WORKLOADS='1', NIHOS_NATIVE_QUALIFICATION='1', NIHOS_NATIVE_DISPLAY='0')
    subprocess.run(['sh', 'tools/build-native.sh', 'emulator', 'integer'], cwd=ROOT, env=env, check=True)
    emulator = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-esp-emu.sh')], text=True).strip()
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'workloads.json', 'scroll.rgb565', 'indexed.rgb565', 'scroll.png', 'indexed.png'):
        (OUT / name).unlink(missing_ok=True)
    for name in ('nihos-native.bin', 'nihos-native.elf', 'nihos-native-flash.bin', 'image-audit.json', 'native_options.zig'):
        shutil.copyfile(BUILD / name, OUT / name)
    options = (OUT / 'native_options.zig').read_text().splitlines()
    for flag in ('pub const canvas_workloads = true;', 'pub const canvas_interactive = false;'):
        if options.count(flag) != 1:
            raise RuntimeError('unexpected workload fixture option')
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
            command = [gdb_binary(), '-q', '-batch', str(OUT / 'nihos-native.elf'),
                       '-ex', 'set remotetimeout 5', '-ex', f'target remote 127.0.0.1:{port}',
                       '-ex', 'break nih_canvas_frame_ready', '-ex', 'continue',
                       '-ex', 'continue', '-ex', 'dump binary memory scroll.rgb565 0x48030000 0x4804f400',
                       '-ex', 'continue', '-ex', 'dump binary memory indexed.rgb565 0x48030000 0x4804f400',
                       '-ex', 'detach']
            with (OUT / 'gdb.log').open('wb') as log:
                subprocess.run(command, cwd=OUT, stdout=log, stderr=subprocess.STDOUT, timeout=420, check=True)
            if (OUT / 'gdb.log').read_text(errors='replace').count('Breakpoint 1, main.nih_canvas_frame_ready') != 3:
                raise RuntimeError('expected three frame rendezvous')
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
    for kind in ('scroll', 'indexed'):
        raw = (OUT / (kind + '.rgb565')).read_bytes()
        verify(kind, raw)
        png = png_rgb565(raw, WIDTH, HEIGHT)
        (OUT / (kind + '.png')).write_bytes(png)
        frames[kind] = {'rgb565_sha256': hashlib.sha256(raw).hexdigest(), 'png_sha256': hashlib.sha256(png).hexdigest()}
    if source_identity() != source:
        raise RuntimeError('source changed during workload execution')
    report = {'evidence': 'esp32p4-emulator-rv32', 'scope': 'offscreen synthetic workloads; not editor, Quake or physical timing',
              'width': WIDTH, 'height': HEIGHT, 'pixel_format': 'RGB565LE', 'source': source,
              'image_sha256': sha(OUT / 'nihos-native.bin'), 'elf_sha256': sha(OUT / 'nihos-native.elf'),
              'emulator_sha256': sha(Path(emulator)), 'frames': frames}
    (OUT / 'workloads.json').write_text(json.dumps(report, indent=2) + '\n')
    print('RV32 editor-scroll and indexed-scale frames match independent pixel references')
    print('Report:', OUT / 'workloads.json')


if __name__ == '__main__': main()

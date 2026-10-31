#!/usr/bin/env python3
"""Compare a native RV32 console frame with the same host fixture."""
import ctypes
import argparse
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
from console_reference import reference as pixel_reference
from emulator_trace import source_identity

BUILD = ROOT / 'build/native-emulator'
OUT = BUILD / 'console-workload'
FRAME_BYTES = 720 * 1280 * 2


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_frame(actual, reference, label='host fixture'):
    if len(actual) != FRAME_BYTES or len(reference) != FRAME_BYTES:
        raise ValueError('invalid console framebuffer length')
    if actual != reference:
        raise ValueError(f'RV32 console differs from {label}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font', choices=('basic-light', 'jetbrains', 'source-code'), default='basic-light')
    args = parser.parse_args()
    face = {'basic-light': 3, 'jetbrains': 1, 'source-code': 2}[args.font]
    global OUT
    OUT = BUILD / 'console-workload' / args.font
    source = source_identity()
    env = os.environ.copy()
    env.update(NIHOS_NATIVE_CANVAS_OFFSCREEN='1', NIHOS_NATIVE_CANVAS_INTERACTIVE='0',
               NIHOS_NATIVE_CANVAS_WORKLOADS='1', NIHOS_NATIVE_QUALIFICATION='1', NIHOS_NATIVE_DISPLAY='0',
               NIHOS_NATIVE_CONSOLE_FONT=str(face))
    subprocess.run(['sh', 'tools/build-native.sh', 'emulator', 'integer'], cwd=ROOT, env=env, check=True)
    emulator = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-esp-emu.sh')], text=True).strip()
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'console.json', 'console.rgb565', 'console.png'):
        (OUT / name).unlink(missing_ok=True)
    for name in ('nihos-native.bin', 'nihos-native.elf', 'nihos-native-flash.bin', 'image-audit.json', 'native_options.zig'):
        shutil.copyfile(BUILD / name, OUT / name)
    options = (OUT / 'native_options.zig').read_text().splitlines()
    for flag in ('pub const canvas_workloads = true;', 'pub const canvas_interactive = false;', f'pub const console_font: u32 = {face};'):
        if options.count(flag) != 1:
            raise RuntimeError('unexpected console workload fixture option')
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
                       '-ex', 'break nih_canvas_frame_ready', '-ex', 'continue', '-ex', 'continue',
                       '-ex', 'continue', '-ex', 'continue',
                       '-ex', 'dump binary memory console.rgb565 0x48030000 0x481f2000', '-ex', 'detach']
            with (OUT / 'gdb.log').open('wb') as log:
                subprocess.run(command, cwd=OUT, stdout=log, stderr=subprocess.STDOUT, timeout=420, check=True)
            if (OUT / 'gdb.log').read_text(errors='replace').count('Breakpoint 1, main.nih_canvas_frame_ready') != 4:
                raise RuntimeError('expected four frame rendezvous')
            if process.wait(timeout=30) != 0:
                raise RuntimeError('emulator failed')
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
    subprocess.run(['python3', str(ROOT / 'tools/check-canvas-offscreen.py'), str(OUT)], cwd=ROOT, check=True)
    library = OUT / ('console-reference.dylib' if os.uname().sysname == 'Darwin' else 'console-reference.so')
    host_options = OUT / 'host-options.zig'
    host_options.write_text(f'pub const face: u32 = {face};\n')
    subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'build-lib', '-dynamic', '-OReleaseSafe',
                    '--dep', 'fixture', '--dep', 'fixture_options', f'-Mroot={ROOT / "tools/probes/console_workload_host.zig"}',
                    '--dep', 'text_console', f'-Mfixture={ROOT / "src/platform/native/console_workload.zig"}',
                    f'-Mfixture_options={host_options}',
                    '--dep', 'view_config', '--dep', 'canvas', f'-Mtext_console={ROOT / "src/console.zig"}',
                    '--dep', 'surface', f'-Mcanvas={ROOT / "src/graphics/canvas.zig"}',
                    f'-Mview_config={ROOT / "src/xy/view_config.zig"}', f'-Msurface={ROOT / "src/graphics/surface.zig"}', f'-femit-bin={library}'], cwd=ROOT, check=True)
    render = ctypes.CDLL(str(library)).render
    render.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    render.restype = ctypes.c_bool
    reference = ctypes.create_string_buffer(FRAME_BYTES)
    if not render(reference, FRAME_BYTES):
        raise RuntimeError('host console fixture failed')
    raw = (OUT / 'console.rgb565').read_bytes()
    check_frame(raw, reference.raw)
    expected = pixel_reference(args.font)
    check_frame(raw, expected, 'independent pixel reference')
    png = png_rgb565(raw, 720, 1280)
    (OUT / 'console.png').write_bytes(png)
    if source_identity() != source:
        raise RuntimeError('source changed during console workload')
    report = {'evidence': 'esp32p4-emulator-rv32', 'scope': 'console fixture compared with host and independent pixel reference; not physical display or timing evidence',
              'width': 720, 'height': 1280, 'font': args.font, 'source': source, 'elf_sha256': sha(OUT / 'nihos-native.elf'),
              'image_sha256': sha(OUT / 'nihos-native.bin'), 'emulator_sha256': sha(Path(emulator)),
              'rgb565_sha256': hashlib.sha256(raw).hexdigest(), 'reference_sha256': hashlib.sha256(expected).hexdigest(), 'png_sha256': hashlib.sha256(png).hexdigest()}
    (OUT / 'console.json').write_text(json.dumps(report, indent=2) + '\n')
    print('RV32 console frame matches host and independent reference:', OUT / 'console.json')


if __name__ == '__main__':
    main()

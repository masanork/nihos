#!/usr/bin/env python3
"""Capture the RV32 canvas fixture's real emulated PSRAM frame via GDB."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time

from canvas_frame import save_frame

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/native-emulator'
OUT = BUILD / 'canvas-snapshot'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gdb_binary():
    configured = os.environ.get('NIHOS_GDB')
    if configured:
        return configured
    found = shutil.which('riscv32-esp-elf-gdb')
    if found:
        return found
    matches = sorted(Path.home().glob('.espressif/tools/riscv32-esp-elf-gdb/*/riscv32-esp-elf-gdb/bin/riscv32-esp-elf-gdb'))
    if not matches:
        raise RuntimeError('riscv32-esp-elf-gdb not found; set NIHOS_GDB')
    return str(matches[-1])


def main():
    env = os.environ.copy()
    env.update(NIHOS_NATIVE_CANVAS_OFFSCREEN='1', NIHOS_NATIVE_QUALIFICATION='1', NIHOS_NATIVE_DISPLAY='0')
    subprocess.run(['sh', 'tools/build-native.sh', 'emulator', 'integer'], cwd=ROOT, env=env, check=True)
    emulator = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-esp-emu.sh')], text=True).strip()
    gdb = gdb_binary()
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ('frame.rgb565', 'frame.png', 'frame.json', 'report.json'):
        (OUT / name).unlink(missing_ok=True)
    for name in ('nihos-native.bin', 'nihos-native.elf', 'nihos-native-flash.bin', 'image-audit.json', 'native_options.zig'):
        shutil.copyfile(BUILD / name, OUT / name)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    with (OUT / 'emulator.log').open('wb') as uart, (OUT / 'emulator-stderr.log').open('wb') as diagnostics:
        process = subprocess.Popen([emulator, '--chip', 'esp32p4', '--firmware', str(OUT / 'nihos-native-flash.bin'),
                                    '--elf', str(OUT / 'nihos-native.elf'), '--psram-size', '32M',
                                    '--timeout', '240s', '--gdb', str(port), '--gdb-halt',
                                    '--exit-on', 'NIHOS_NATIVE_CANVAS_OFFSCREEN_PASS'], stdout=uart, stderr=diagnostics, cwd=ROOT)
        try:
            deadline = time.monotonic() + 15
            while b'GDB stub listening' not in (OUT / 'emulator-stderr.log').read_bytes():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('emulator GDB stub did not start; see emulator-stderr.log')
                time.sleep(.1)
            command = [gdb, '-q', '-batch', str(OUT / 'nihos-native.elf'),
                       '-ex', 'set remotetimeout 5', '-ex', f'target remote 127.0.0.1:{port}',
                       '-ex', 'break nih_canvas_frame_ready', '-ex', 'continue',
                       '-ex', 'dump binary memory frame.rgb565 0x48030000 0x481f2000', '-ex', 'detach']
            with (OUT / 'gdb.log').open('wb') as log:
                subprocess.run(command, cwd=OUT, stdout=log, stderr=subprocess.STDOUT, timeout=200, check=True)
            debug_output = (OUT / 'gdb.log').read_text(errors='replace')
            if 'Breakpoint 1, main.nih_canvas_frame_ready' not in debug_output:
                raise RuntimeError('frame rendezvous was not reached; see gdb.log')
            if process.wait(timeout=20) != 0:
                raise RuntimeError('emulator failed; see logs')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    subprocess.run(['python3', str(ROOT / 'tools/check-canvas-offscreen.py'), str(OUT)], cwd=ROOT, check=True)
    receipt = save_frame(OUT / 'frame.rgb565', OUT / 'frame.png', OUT / 'frame.json')
    receipt.update({'image_sha256': sha(OUT / 'nihos-native.bin'), 'elf_sha256': sha(OUT / 'nihos-native.elf'),
                    'flash_sha256': sha(OUT / 'nihos-native-flash.bin'), 'log_sha256': sha(OUT / 'emulator.log'),
                    'emulator_sha256': sha(Path(emulator)), 'gdb_sha256': sha(Path(gdb))})
    (OUT / 'frame.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'Emulated framebuffer PNG: {OUT / "frame.png"}')


if __name__ == '__main__':
    main()

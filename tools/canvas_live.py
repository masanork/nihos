#!/usr/bin/env python3
"""Interactive RV32 Canvas fixture via ESP-EMU's halted GDB mailbox."""
import argparse
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import socket
import struct
import subprocess
import threading
import time

from canvas_frame import FRAME_BYTES, fnv1a, png_rgb565
from canvas_snapshot import ROOT, gdb_binary

OUT = ROOT / 'build/native-emulator/canvas-live'


def encode_frame(raw, previous_sha=None, previous_png=None):
    if len(raw) != FRAME_BYTES:
        raise RuntimeError('short emulated framebuffer')
    digest = hashlib.sha256(raw).hexdigest()
    if digest == previous_sha and previous_png is not None:
        return digest, previous_png
    return digest, png_rgb565(raw, 720, 1280)


def acquire_session_lock(path):
    handle = path.open('a+b')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise RuntimeError('another canvas-live session is using this worktree') from None
    return handle


class Mi:
    def __init__(self, binary, elf, log):
        self.p = subprocess.Popen([binary, '-q', '--interpreter=mi2', str(elf)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0, cwd=OUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.p.stdout, selectors.EVENT_READ)
        self.buf = b''
        self.token = 0
        self.stops = []

    def line(self, deadline):
        while b'\n' not in self.buf:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise RuntimeError('GDB response timeout')
            chunk = os.read(self.p.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError('GDB exited')
            self.buf += chunk
        line, self.buf = self.buf.split(b'\n', 1)
        return line.decode(errors='replace').rstrip('\r')

    def command(self, command, timeout=20):
        self.token += 1
        token = str(self.token)
        self.p.stdin.write((token + command + '\n').encode())
        deadline = time.monotonic() + timeout
        while True:
            line = self.line(deadline)
            if line.startswith('*stopped'):
                self.stops.append(line)
            if line.startswith(token + '^'):
                if not (line.startswith(token + '^done') or line.startswith(token + '^connected') or line.startswith(token + '^running') or line.startswith(token + '^exit')):
                    raise RuntimeError('GDB command failed: ' + line)
                return line

    def resume_to_frame(self):
        self.stops.clear()
        self.command('-exec-continue')
        deadline = time.monotonic() + 180
        while not self.stops:
            line = self.line(deadline)
            if line.startswith('*stopped'):
                self.stops.append(line)
        stopped = self.stops.pop(0)
        if 'breakpoint-hit' not in stopped or 'nih_canvas_frame_ready' not in stopped:
            raise RuntimeError('guest stopped away from frame rendezvous: ' + stopped)

    def address(self, name):
        result = self.command('-data-evaluate-expression "(unsigned int)&' + name + '"')
        match = re.search(r'value="(0x[0-9a-fA-F]+|[0-9]+)', result)
        if not match:
            raise RuntimeError('could not resolve emulator mailbox')
        return int(match.group(1), 0)

    def read(self, address, length):
        result = self.command(f'-data-read-memory-bytes 0x{address:x} {length}')
        match = re.search(r'contents="([0-9a-fA-F]+)"', result)
        if not match or len(match.group(1)) != length * 2:
            raise RuntimeError('short emulator mailbox read')
        return bytes.fromhex(match.group(1))

    def write(self, address, data):
        self.command(f'-data-write-memory-bytes 0x{address:x} {data.hex()}')

    def close(self):
        if self.p.poll() is None:
            try:
                self.command('-gdb-exit', timeout=3)
                self.p.wait(timeout=3)
            except (RuntimeError, subprocess.TimeoutExpired):
                self.p.kill()
                self.p.wait()
        self.selector.close()


class Guest:
    def __init__(self):
        self.proc = self.mi = None
        self.handles = []
        self.lock = threading.Lock()
        self.last_time = 0
        self.seq = 0
        OUT.mkdir(parents=True, exist_ok=True)
        self.session_lock = acquire_session_lock(OUT / 'session.lock')
        try:
            self.start()
        except BaseException:
            self.close()
            raise

    def start(self):
        env = os.environ.copy()
        env.update(NIHOS_NATIVE_CANVAS_OFFSCREEN='1', NIHOS_NATIVE_CANVAS_INTERACTIVE='1', NIHOS_NATIVE_QUALIFICATION='1', NIHOS_NATIVE_DISPLAY='0')
        subprocess.run(['sh', 'tools/build-native.sh', 'emulator', 'integer'], cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL)
        emulator = subprocess.check_output(['sh', str(ROOT / 'tools/bootstrap-esp-emu.sh')], text=True).strip()
        OUT.mkdir(parents=True, exist_ok=True)
        for name in ('nihos-native.bin', 'nihos-native.elf', 'nihos-native-flash.bin', 'image-audit.json', 'native_options.zig'):
            shutil.copyfile(ROOT / 'build/native-emulator' / name, OUT / name)
        audit = json.loads((OUT / 'image-audit.json').read_text())
        app = (OUT / 'nihos-native.bin').read_bytes()
        elf = (OUT / 'nihos-native.elf').read_bytes()
        flash = (OUT / 'nihos-native-flash.bin').read_bytes()
        if audit['memory']['profile'] != 'emulator' or audit['image_sha256'] != hashlib.sha256(app).hexdigest() or audit['elf_sha256'] != hashlib.sha256(elf).hexdigest() or flash[0x10000:0x10000+len(app)] != app:
            raise RuntimeError('emulator image audit mismatch')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        uart = (OUT / 'emulator.log').open('wb'); diagnostics = (OUT / 'emulator-stderr.log').open('wb'); log = (OUT / 'gdb-stderr.log').open('wb')
        self.handles = [uart, diagnostics, log]
        try:
            self.proc = subprocess.Popen([emulator, '--chip', 'esp32p4', '--firmware', str(OUT / 'nihos-native-flash.bin'), '--elf', str(OUT / 'nihos-native.elf'), '--psram-size', '32M', '--gdb', str(port), '--gdb-halt'], cwd=ROOT, stdout=uart, stderr=diagnostics)
            deadline = time.monotonic() + 15
            while b'GDB stub listening' not in (OUT / 'emulator-stderr.log').read_bytes():
                if self.proc.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('emulator GDB stub did not start')
                time.sleep(.1)
            self.mi = Mi(gdb_binary(), OUT / 'nihos-native.elf', log)
            self.mi.command('-target-select remote 127.0.0.1:' + str(port))
            self.mi.command('-break-insert nih_canvas_frame_ready')
            self.mi.resume_to_frame()
            self.input_addr = self.mi.address('nih_emulator_input')
            self.output_addr = self.mi.address('nih_emulator_output')
            self.refresh()
            if fnv1a(self.raw) != 0x549e3481:
                raise RuntimeError('initial emulator framebuffer mismatch')
        except BaseException:
            self.close()
            raise

    def refresh(self):
        path = OUT / 'frame.rgb565'
        path.unlink(missing_ok=True)
        # Relative GDB path avoids injecting filesystem paths into its CLI.
        self.mi.command('-interpreter-exec console "dump binary memory frame.rgb565 0x48030000 0x481f2000"', timeout=90)
        self.raw = path.read_bytes()
        sha, self.png = encode_frame(self.raw, getattr(self, 'pixel_sha', None), getattr(self, 'png', None))
        self.pixel_sha = sha
        self.seq += 1
        samples, events, clicks, kind = struct.unpack('<IIII', self.mi.read(self.output_addr, 16))
        self.state = {'frame': self.seq, 'samples': samples, 'events': events, 'clicks': clicks, 'kind': kind,
                      'time_us': self.last_time, 'pixel_sha256': self.pixel_sha, 'evidence': 'esp-emu-rv32-fixture'}

    def sample(self, contacts, x, y, time_us):
        if any(type(v) is not int for v in (contacts, x, y, time_us)) or contacts not in (0, 1, 2) or not 0 <= x < 720 or not 0 <= y < 1280 or not self.last_time <= time_us <= 0xffffffff:
            raise ValueError('invalid touch sample')
        self.last_time = time_us
        self.mi.write(self.input_addr, struct.pack('<IIIII', 1, contacts, x, y, time_us))
        self.mi.resume_to_frame()
        self.refresh()
        return self.state

    def close(self):
        if self.mi:
            self.mi.close()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill(); self.proc.wait()
        for handle in self.handles:
            handle.close()
        self.handles = []
        if self.session_lock is not None:
            self.session_lock.close()
            self.session_lock = None


def serve(guest, port):
    page = Path(__file__).with_name('canvas_live.html').read_bytes()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def send(self, code, data, mime):
            self.send_response(code); self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control', 'no-store'); self.send_header('X-Content-Type-Options', 'nosniff'); self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
                self.send(403, b'{}', 'application/json'); return
            with guest.lock:
                if self.path == '/': self.send(200, page, 'text/html; charset=utf-8')
                elif self.path == '/state': self.send(200, json.dumps(guest.state).encode(), 'application/json')
                elif self.path.split('?')[0] == '/frame.png': self.send(200, guest.png, 'image/png')
                else: self.send(404, b'{}', 'application/json')
        def do_POST(self):
            host = f'127.0.0.1:{self.server.server_port}'
            if self.path != '/sample' or self.headers.get('Host') != host or self.headers.get('Origin') not in (None, f'http://{host}') or self.headers.get('Content-Type') != 'application/json':
                self.send(403, b'{}', 'application/json'); return
            try:
                n = int(self.headers.get('Content-Length', '0'))
                if not 0 < n <= 256: raise ValueError('length')
                sample = json.loads(self.rfile.read(n))
                if set(sample) != {'contacts', 'x', 'y', 'time_us'}: raise ValueError('fields')
                with guest.lock: result = guest.sample(**sample)
                self.send(200, json.dumps(result).encode(), 'application/json')
            except (ValueError, TypeError, KeyError, json.JSONDecodeError):
                self.send(400, b'{}', 'application/json')
            except (RuntimeError, OSError):
                self.send(500, b'{"error":"emulator stopped"}', 'application/json')
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print(f'RV32 Canvas fixture: http://127.0.0.1:{server.server_port}/', flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close(); guest.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8713)
    args = parser.parse_args()
    serve(Guest(), args.port)


if __name__ == '__main__': main()

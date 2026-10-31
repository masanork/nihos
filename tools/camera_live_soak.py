#!/usr/bin/env python3
"""Bounded UART camera soak actor; flashing/backup ownership belongs to caller.

run_capture requires the caller's exclusive serial and verified restore
transaction. Replay saved events without hardware: python3 tools/camera_live_soak.py
EVENTS.jsonl --seconds 120 --restarts 10.
"""
import argparse
import json
import math
from pathlib import Path
import re
import time


class Session:
    def __init__(self, seconds=120, restarts=10):
        if not 1 <= seconds <= 300 or not 1 <= restarts <= 20:
            raise ValueError('duration/restart limit exceeded')
        self.seconds, self.restarts = seconds, restarts
        self.phase, self.phase_at = 'boot', 0.0
        self.commands = []
        self.expected_sequence, self.last_display = 1, -1
        self.cycle, self.times, self.cycles = 0, [], []
        self.pending_stream = None
        self.memory, self.baseline = [], None
        self.snapshots, self.heartbeats, self.repaints = 0, 0, 0
        self.boots, self.ready = 0, False
        self.requests = []
        self.last_frame = None
        self.manuals = 0
        self.distinct = set()
        self.heartbeat_at, self.heartbeat_counters = None, None
        self.manual_accepted = False

    def move(self, phase, now, command=None):
        self.phase, self.phase_at = phase, now
        if phase in ('manual', 'cold_manual'):
            self.manual_accepted = False
        if command is not None:
            self.commands.append(command)

    def start_live(self, now):
        self.times = []
        self.last_frame = None
        self.start_heartbeats = self.heartbeats
        self.move('starting', now, b'camera-live\n')

    def stop(self, now):
        self.stop_at = now
        self.move('stop', now, b'\x1b')

    def tick(self, now):
        if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now):
            raise ValueError('non-finite or invalid event timestamp')
        elapsed = now - self.phase_at
        if elapsed < 0:
            raise ValueError('clock reversed')
        if self.phase == 'live':
            if now - max(self.phase_at, self.heartbeat_at or self.phase_at) > 7.5:
                raise ValueError('network service heartbeat gap exceeds 7.5 seconds')
            if self.last_frame is None and elapsed > 10:
                raise ValueError('first frame timeout')
            if self.last_frame is not None and now - self.last_frame > 2:
                raise ValueError('live frame gap exceeds two seconds')
            if self.cycle == 0 and self.times and now - self.times[0] >= self.seconds:
                self.stop(now)
        elif self.phase == 'idle_cold' and elapsed >= 1:
            self.move('cold_manual', now, b'camera\n')
        elif self.phase == 'idle_done' and elapsed >= 1:
            self.move('done', now)
        elif self.phase != 'done' and elapsed > (30 if self.phase == 'boot' else 10):
            raise ValueError('stage timeout: ' + self.phase)

    def feed(self, line, now):
        self.tick(now)
        if 'ESP-ROM:esp32p4' in line:
            self.boots += 1
            if self.ready or self.boots > 1:
                raise ValueError('unexpected reset')
        if any(s in line for s in ('NIHOS_NATIVE_FAIL ', 'NIHOS_NATIVE_CAMERA_LIVE_FAILURE ', 'Camera unavailable or busy.')):
            raise ValueError('firmware failure: ' + line.strip())
        if self.ready and 'NIHOS_C6_BOOT' in line:
            raise ValueError('C6 restarted during capture')
        if 'NIHOS_NATIVE_SESSION_READY ' in line:
            if self.ready:
                raise ValueError('session restarted')
            self.ready = True
            self.move('guards', now, b':camera-reset-hold\n:camera-recover\n')
        match = re.search(r'(NIHOS_[A-Z_]+) (.*)', line)
        if match:
            tag, body = match.groups()
            fields = {k: int(v, 16) for k, v in re.findall(r'(\w+)=([0-9a-f]{8})(?=\s|$)', body)}
            self.record(tag, fields, now)
        memory = re.search(r'PSRAM reusable heap capacity=(\d+) free=(\d+) used=(\d+)', line)
        if memory:
            self.on_memory(dict(zip(('capacity', 'free', 'used'), map(int, memory.groups()))), now)

    def sequence(self, value):
        if value != self.expected_sequence:
            raise ValueError('capture sequence gap or duplicate')
        self.expected_sequence += 1

    def record(self, tag, f, now):
        if tag == 'NIHOS_NATIVE_NETWORK_UI':
            if not {'frames', 'ticks0', 'ticks1'} <= f.keys():
                raise ValueError('heartbeat counters missing')
            counters = tuple(f[key] for key in ('frames', 'ticks0', 'ticks1'))
            if self.heartbeat_counters is not None and any(a <= b for a, b in zip(counters, self.heartbeat_counters)):
                raise ValueError('network service heartbeat counters stalled')
            self.heartbeat_at, self.heartbeat_counters = now, counters
            self.heartbeats += 1
        elif tag == 'NIHOS_DEVICE_REQUEST':
            kind, accepted = f['kind'], f['accepted']
            expected = [(27, 0), (29, 0)]
            if self.phase == 'guards':
                if len(self.requests) >= 2 or (kind, accepted) != expected[len(self.requests)]:
                    raise ValueError('diagnostic request was not rejected')
            elif (kind, accepted) != (30 if self.phase == 'starting' else 26, 1) or self.phase not in ('starting', 'manual', 'cold_manual'):
                raise ValueError('unexpected camera request')
            self.requests.append((kind, accepted))
            if self.phase == 'guards' and kind == 29:
                self.move('shell', now, b'\x1b')
            elif self.phase == 'starting':
                if self.cycle % 2:
                    self.stop(now)
                else:
                    self.move('live', now)
            elif self.phase in ('manual', 'cold_manual'):
                if self.manual_accepted:
                    raise ValueError('duplicate manual request')
                self.manual_accepted = True
        elif tag == 'NIHOS_NATIVE_SESSION_VIEW' and self.phase == 'shell' and f.get('from') == 0 and f.get('to') == 1:
            self.move('baseline', now, b'mem\n')
        elif tag == 'NIHOS_NATIVE_CAMERA_SNAPSHOT':
            if self.phase not in ('live', 'stop', 'manual', 'cold_manual') or (self.phase == 'stop' and self.cycle % 2):
                raise ValueError('image outside active capture, including after drain')
            if self.phase in ('manual', 'cold_manual') and not self.manual_accepted:
                raise ValueError('manual image without accepted request')
            self.sequence(f['sequence'])
            if f['state'] != 1 or f['mismatches'] != 0 or f['frames'] <= self.last_display:
                raise ValueError('framebuffer mismatch or stalled display')
            self.last_display = f['frames']
            self.snapshots += 1
            self.distinct.add(f['sample_hash'])
            if self.phase in ('live', 'stop'):
                self.times.append(now)
                self.last_frame = now
                if self.phase == 'live' and self.cycle != 0 and len(self.times) >= 5:
                    self.stop(now)
            else:
                self.manuals += 1
                self.move('manual_repaint' if self.phase == 'manual' else 'cold_repaint', now, b'\x1b')
        elif tag == 'NIHOS_NATIVE_CAMERA_STREAM':
            if not {'completed', 'dropped', 'fault', 'incomplete'} <= f.keys():
                raise ValueError('stream counters missing')
            if self.phase != 'stop' or self.pending_stream is not None or f['fault'] != 0:
                raise ValueError('stream fault or unexpected retirement')
            self.pending_stream = f
        elif tag == 'NIHOS_NATIVE_CAMERA_LIVE_DRAIN':
            if self.phase != 'stop' or self.pending_stream is None:
                raise ValueError('drain missing stream completion')
            self.sequence(f['sequence'])
            latency = now - self.stop_at
            if latency > 1:
                raise ValueError('stop/drain exceeds one second')
            if self.cycle == 0 and (len(self.times) < self.seconds * 10 or self.stop_at - self.times[0] < self.seconds):
                raise ValueError('soak duration or minimum cadence not reached')
            if self.pending_stream['completed'] - self.pending_stream['dropped'] < len(self.times):
                raise ValueError('inconsistent stream counters')
            if self.cycle == 0 and self.seconds >= 30 and self.heartbeats - self.start_heartbeats < 2:
                raise ValueError('network service heartbeat stalled')
            self.cycles.append(dict(index=self.cycle, cancelled_while_loading=bool(self.cycle % 2),
                                    frames=len(self.times), snapshot_times=self.times.copy(),
                                    observed_live_seconds=self.stop_at - self.times[0] if self.times else 0,
                                    stop_drain_seconds=latency, stream=self.pending_stream,
                                    heartbeats=self.heartbeats - self.start_heartbeats))
            self.pending_stream = None
            # Loading cancellation never opened the image overlay, so the
            # shell is already visible and no repaint record is expected.
            if self.cycle % 2:
                self.move('memory', now, b'mem\n')
            else:
                self.move('repaint', now)
        elif tag == 'NIHOS_NATIVE_CAMERA_UI_REPAINT':
            if f['kind'] != 1 or f['view'] != 1 or f['line_bytes'] != 0:
                raise ValueError('shell repaint failed')
            next_phase = {'repaint': 'memory', 'manual_repaint': 'manual_memory', 'cold_repaint': 'cold_memory'}.get(self.phase)
            if next_phase is None:
                raise ValueError('unexpected shell repaint')
            self.repaints += 1
            self.move(next_phase, now, b'mem\n')

    def on_memory(self, memory, now):
        if memory['free'] + memory['used'] != memory['capacity']:
            raise ValueError('inconsistent heap counters')
        if self.phase not in ('baseline', 'memory', 'manual_memory', 'cold_memory'):
            raise ValueError('unsolicited memory response')
        self.memory.append(dict(phase=self.phase, cycle=self.cycle, **memory))
        if self.phase == 'baseline':
            self.baseline = memory
            self.start_live(now)
            return
        if memory['capacity'] != self.baseline['capacity'] or memory['used'] != self.baseline['used'] + 2_101_248:
            raise ValueError('camera allocation growth or unexpected reservation')
        if self.phase == 'memory':
            if self.cycle < self.restarts:
                self.cycle += 1
                self.start_live(now)
            else:
                self.move('manual', now, b'camera\n')
        elif self.phase == 'manual_memory':
            self.move('idle_cold', now)
        else:
            self.move('idle_done', now)

    def result(self):
        if self.phase != 'done' or self.manuals != 2 or len(self.cycles) != self.restarts + 1:
            raise ValueError('workflow incomplete: ' + self.phase)
        return dict(seconds=self.seconds, restarts=self.restarts, cycles=self.cycles,
                    memory=self.memory, snapshots=self.snapshots,
                    distinct_sample_hashes=len(self.distinct), repaints=self.repaints,
                    network_heartbeats=self.heartbeats, requests=self.requests)


def run_capture(port, output, *, reconnect):
    """Capture inside the exclusive backup/restore harness.

    reconnect must reopen after USB reset under the held writer lease, reclaim
    kernel exclusion, and reject other serial owners before returning. It is
    supplied by the transaction's protected serial class, not plain Serial.
    """
    import esptool
    port.timeout = .2
    port.baudrate = 115200
    port.reset_input_buffer()
    esp = esptool.detect_chip(port=port, baud=115200)
    if (esp.get_chip_description(), ':'.join(f'{v:02x}' for v in esp.read_mac())) != ('ESP32-P4 (revision v1.3)', 'e8:f6:0a:e2:e8:9c'):
        raise ValueError('device identity mismatch before reset')
    esp.watchdog_reset()
    reconnect()
    port.timeout = .2
    actor = Session()
    started = time.monotonic()
    raw, events = bytearray(), []
    pending = bytearray()
    def save():
        (output / 'serial.raw.log').write_bytes(raw)
        (output / 'serial.log').write_text(raw.decode('ascii', errors='replace').replace('\r', ''))
        (output / 'events.jsonl').write_text(''.join(json.dumps(event) + '\n' for event in events))
        (output / 'progress.json').write_text(json.dumps(dict(phase=actor.phase, cycle=actor.cycle, frames=actor.snapshots), indent=2) + '\n')
    saved = 0
    try:
        while actor.phase != 'done':
            now = time.monotonic() - started
            if now > 240:
                raise ValueError('total qualification deadline exceeded')
            chunk = port.read(max(1, port.in_waiting))
            raw.extend(chunk)
            pending.extend(chunk)
            while b'\n' in pending:
                line, _, pending = pending.partition(b'\n')
                now = time.monotonic() - started
                line = line.decode('ascii', errors='replace').replace('\r', '')
                events.append(dict(t=now, line=line))
                actor.feed(line, now)
            # Tick events make replay reproduce timers, even during UART idle.
            now = time.monotonic() - started
            events.append(dict(t=now))
            actor.tick(now)
            while actor.commands:
                port.write(actor.commands.pop(0))
                port.flush()
            if now - saved >= 10:
                save()
                print(f'CAMERA_SOAK seconds={now:.1f} cycle={actor.cycle} frames={actor.snapshots} phase={actor.phase}', flush=True)
                saved = now
        return actor.result()
    finally:
        save()


def replay(path, seconds=120, restarts=10):
    actor = Session(seconds, restarts)
    previous = 0
    with Path(path).open() as source:
        for line in source:
            event = json.loads(line)
            now = event['t']
            if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now):
                raise ValueError('non-finite or invalid event timestamp')
            if now < previous:
                raise ValueError('event clock reversed')
            previous = now
            if 'line' in event:
                actor.feed(event['line'], now)
            else:
                actor.tick(now)
            actor.commands.clear()
    return actor.result()


def sanitize(source, destination, seconds=120, restarts=10):
    """Retain protocol evidence, replace scene hashes with equality labels."""
    if Path(source).resolve() == Path(destination).resolve():
        raise ValueError('sanitized output must differ from source')
    expected = replay(source, seconds, restarts)
    tags = ('NIHOS_DEVICE_REQUEST ', 'NIHOS_NATIVE_SESSION_READY ',
            'NIHOS_NATIVE_SESSION_VIEW ', 'NIHOS_NATIVE_NETWORK_UI ',
            'NIHOS_NATIVE_CAMERA_SNAPSHOT ', 'NIHOS_NATIVE_CAMERA_STREAM ',
            'NIHOS_NATIVE_CAMERA_LIVE_DRAIN ', 'NIHOS_NATIVE_CAMERA_UI_REPAINT ')
    labels = {}
    with Path(source).open() as src, Path(destination).open('x') as dst:
        for line in src:
            event = json.loads(line)
            original = event.get('line', '')
            event = dict(t=event['t'])
            if any(marker in original for marker in ('NIHOS_NATIVE_FAIL ', 'NIHOS_NATIVE_CAMERA_LIVE_FAILURE ', 'NIHOS_C6_BOOT')):
                raise ValueError('cannot sanitize an exceptional trace')
            if 'ESP-ROM:esp32p4' in original:
                event['line'] = 'ESP-ROM:esp32p4'
            else:
                for tag in tags:
                    if tag in original:
                        text = original[original.index(tag):]
                        if tag == 'NIHOS_NATIVE_CAMERA_SNAPSHOT ':
                            match = re.search(r'sample_hash=([0-9a-f]{8})', text)
                            key = match.group(1)
                            label = labels.setdefault(key, len(labels) + 1)
                            text = text[:match.start(1)] + f'{label:08x}' + text[match.end(1):]
                        event['line'] = text
                        break
                if 'PSRAM reusable heap capacity=' in original:
                    event['line'] = original[original.index('PSRAM reusable heap capacity='):]
            dst.write(json.dumps(event, separators=(',', ':'), allow_nan=False) + '\n')
    if replay(destination, seconds, restarts) != expected:
        raise ValueError('sanitization changed qualification result')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('events', type=Path)
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--restarts', type=int, default=10)
    parser.add_argument('--sanitize-to', type=Path)
    args = parser.parse_args()
    if args.sanitize_to:
        sanitize(args.events, args.sanitize_to, args.seconds, args.restarts)
    result = replay(args.events, args.seconds, args.restarts)
    print(json.dumps(dict(soak_frames=result['cycles'][0]['frames'], cycles=len(result['cycles']),
                          snapshots=result['snapshots'], memory_samples=len(result['memory']))))

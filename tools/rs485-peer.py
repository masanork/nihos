#!/usr/bin/env python3
"""Serve one finite diagnostic response on a separate RS485 bench adapter."""
import argparse
import hashlib
import json
from pathlib import Path
import time

SIZE = 64


def crc16(data):
    value = 0xffff
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ (0x1021 if value & 0x8000 else 0)) & 0xffff
    return value


def frame(response=False):
    data = bytearray(b'NIHOS485' + bytes((2 if response else 1, 1)))
    data += bytes((index * 37 % 256) ^ (0xa5 if response else 0) for index in range(10, SIZE - 2))
    return bytes(data) + crc16(data).to_bytes(2, 'big')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port', help='Separate RS485 adapter, not the Tab5 console')
    parser.add_argument('report', type=Path)
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error('timeout must be between 1 and 600 seconds')
    import serial
    start = time.monotonic()
    request, reply = frame(), frame(True)
    with serial.Serial(args.port, 115200, timeout=.1, exclusive=True) as peer:
        peer.reset_input_buffer()
        incoming = bytearray()
        while len(incoming) < SIZE and time.monotonic() - start < args.timeout:
            incoming += peer.read(SIZE - len(incoming))
        if incoming != request:
            raise SystemExit('Missing or incorrect diagnostic request; no response sent')
        # Give CPU0 time to observe the final stop bit and drop transceiver DE.
        time.sleep(.020)
        written = peer.write(reply)
        peer.flush()
        if written != SIZE:
            raise SystemExit('Partial diagnostic reply write')
    args.report.write_text(json.dumps({'scope': 'separate RS485 peer adapter; must pair with exact device capture',
        'baud': 115200, 'bytes_received': len(incoming), 'bytes_sent': written,
        'request_sha256': hashlib.sha256(incoming).hexdigest(), 'reply_sha256': hashlib.sha256(reply).hexdigest(),
        'request_hex': incoming.hex(), 'reply_hex': reply.hex(),
        'elapsed_seconds': time.monotonic() - start}, indent=2) + '\n')
    print('Exact diagnostic request received and distinct CRC-bound reply sent')


if __name__ == '__main__':
    main()

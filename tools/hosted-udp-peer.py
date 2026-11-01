#!/usr/bin/env python3
"""Bounded receive-only peer for the explicit long UDP diagnostic."""
import argparse
import hashlib
import json
import socket
import time


def expected(length=1200, attempt=None):
    payload = bytearray(i % 256 for i in range(length))
    payload[:8] = b'NIHOSUDP'
    if attempt is not None:
        payload[8] = attempt
    return bytes(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=44444)
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--expect', choices=('long', 'both', 'burst'), default='long')
    parser.add_argument('--echo', action='store_true', help='echo only validated diagnostic payloads to their source')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 0 < args.timeout <= 300:
        parser.error('port must be 1..65535; timeout must be 0..300 seconds')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as peer:
        peer.bind((args.bind, args.port))
        deadline = time.monotonic() + args.timeout
        seen = set()
        attempts = set()
        print(json.dumps({'event': 'ready', 'bind': args.bind, 'port': args.port}), flush=True)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(json.dumps({'event': 'timeout', 'seen': sorted(seen)}))
                return 1
            peer.settimeout(remaining)
            try:
                data, source = peer.recvfrom(65535)
            except socket.timeout:
                print(json.dumps({'event': 'timeout', 'seen': sorted(seen)}))
                return 1
            attempt = data[8] if len(data) == 1200 and 1 <= data[8] <= 32 else None
            valid = len(data) in (64, 1200) and data == expected(len(data), attempt)
            print(json.dumps({'event': 'received', 'source_ip': source[0], 'source_port': source[1],
                              'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                              'attempt': attempt, 'payload_matches': valid}), flush=True)
            if not valid:
                return 1
            if args.echo:
                sent = peer.sendto(data, source)
                print(json.dumps({'event': 'echoed', 'bytes': sent}), flush=True)
            seen.add(len(data))
            if attempt is not None:
                attempts.add(attempt)
            if args.expect == 'burst' and 64 in seen and set(range(1, 17)).issubset(attempts):
                return 0
            if args.expect != 'burst' and 1200 in seen and (args.expect == 'long' or 64 in seen):
                return 0


if __name__ == '__main__':
    raise SystemExit(main())

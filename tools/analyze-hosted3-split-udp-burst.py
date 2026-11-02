#!/usr/bin/env python3
"""Check paired, private single-run evidence; redact network identities."""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re


def analyze(device, peer):
    lines = device.decode('ascii', 'replace').splitlines()
    rows = [line for line in lines if line.startswith('NIHOS_NATIVE_C6 ')]
    if len(rows) != 1 or sum(line.startswith('NIHOS_C6_HOSTED_WIFI_PASS ') for line in lines) != 1:
        raise ValueError('missing or duplicate device result')
    if any(line.startswith(('NIHOS_C6_TRAP', 'NIHOS_C6_FAIL', 'NIHOS_C6_HOSTED_WIFI_FAIL')) for line in lines):
        raise ValueError('device failure')
    fields = {key: int(value, 16) for key, value in re.findall(r'(\w+)=([0-9a-f]{8})(?:\s|$)', rows[0])}
    expected = {'status': 1, 'stage': 12, 'error_code': 0, 'peer_chip': 13,
                'fw_known': 1, 'fw_major': 3, 'fw_minor': 0, 'fw_patch': 10,
                'long_sent': 1254, 'long_attempts': 16, 'long_burst': 1}
    if any(fields.get(k) != v for k, v in expected.items()):
        raise ValueError('device result mismatch')
    mask = fields.get('long_echo_mask', 0)
    if mask >> 16 or fields.get('long_echo', 0) < bin(mask).count('1') or fields.get('long_final_wait_ms', 0) < 8000:
        raise ValueError('invalid echo mask or settling interval')
    source = str(ipaddress.IPv4Address(fields['ip']))
    received = []
    echoed = []
    for item in peer:
        if item.get('event') == 'received':
            attempt = item.get('attempt')
            if not isinstance(attempt, int) or not 1 <= attempt <= 16:
                raise ValueError('unexpected peer attempt')
            payload = bytearray(i % 256 for i in range(1200))
            payload[:8] = b'NIHOSUDP'
            payload[8] = attempt
            if (item.get('source_ip') != source or item.get('source_port') != 49152 or item.get('bytes') != 1200 or
                    not item.get('payload_matches') or item.get('sha256') != hashlib.sha256(payload).hexdigest()):
                raise ValueError('peer payload or source mismatch')
            received.append(attempt)
        elif item.get('event') == 'echoed':
            if item.get('bytes') != 1200 or item.get('attempt') not in range(1, 17):
                raise ValueError('invalid peer echo')
            echoed.append(item['attempt'])
        else:
            raise ValueError('unexpected peer event')
    if sorted(received) != sorted(echoed):
        raise ValueError('peer receipt/echo mismatch')
    peer_mask = sum(1 << (n - 1) for n in set(received))
    if mask & ~peer_mask:
        raise ValueError('P4 echo without peer observation')
    return {'device_capture_sha256': hashlib.sha256(device).hexdigest(),
            'peer_capture_sha256': hashlib.sha256(json.dumps(peer, sort_keys=True).encode()).hexdigest(),
            'sent_count': 16, 'peer_received_count': len(received), 'peer_received_mask': peer_mask,
            'p4_echo_count': fields['long_echo'], 'p4_echo_mask': mask,
            'p4_unique_echoes': bin(mask).count('1'), 'settle_ms': fields['long_final_wait_ms'],
            'scope': 'one bounded diagnostic run; not a population loss estimate'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', type=Path, required=True)
    parser.add_argument('--peer', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.device.read_bytes(), json.loads(args.peer.read_text()))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print('Paired burst evidence validated; address details withheld')


if __name__ == '__main__':
    main()

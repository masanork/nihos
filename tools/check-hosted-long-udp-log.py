#!/usr/bin/env python3
"""Correlate one diagnostic boot with one peer record; does not verify flash."""
import hashlib
import ipaddress
import json
import sys
from pathlib import Path


def check(log, peer_lines):
    if log.count('ESP-ROM:esp32p4') != 1 or log.count('NIHOS_C6_BOOT ') != 1:
        raise ValueError('expected one ROM banner and one diagnostic boot')
    if 'NIHOS_C6_TRAP ' in log or 'NIHOS_C6_HOSTED_WIFI_FAIL' in log:
        raise ValueError('device failure marker')
    if log.count('NIHOS_C6_LONG_DMA build=diagnostic ') != 1 or log.count('NIHOS_C6_HOSTED_WIFI_PASS ') != 1:
        raise ValueError('missing diagnostic or Wi-Fi pass marker')
    rows = [line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_C6 ')]
    if len(rows) != 1:
        raise ValueError('expected one C6 report')
    fields = {}
    for token in rows[0].split()[1:]:
        name, value = token.split('=', 1)
        if name in fields:
            raise ValueError('duplicate report field')
        fields[name] = int(value, 16)
    expected = {'status': 1, 'stage': 12, 'error_code': 0, 'cleanup_failed': 0,
                'fw_known': 1, 'fw_major': 1, 'fw_minor': 4, 'fw_patch': 1,
                'short_sent': 118,
                'long_logical': 1254, 'long_wire': 1536, 'long_sent': 1254,
                'long_dma_state': 0}
    if any(fields.get(key) != value for key, value in expected.items()) or not fields.get('long_hash'):
        raise ValueError('unexpected C6 report')
    records = [json.loads(line) for line in peer_lines.splitlines() if line.strip()]
    received = [record for record in records if record.get('event') == 'received']
    if not received or any(item.get('bytes') not in (64, 1200) for item in received) or {item['bytes'] for item in received} != {64, 1200}:
        raise ValueError('expected short and long peer receipts')
    source_ip = str(ipaddress.IPv4Address(fields['ip']))
    hashes = {}
    for item in received:
        length = item['bytes']
        payload = bytearray(i % 256 for i in range(length))
        payload[:8] = b'NIHOSUDP'
        attempt = item.get('attempt')
        if attempt is not None:
            if length != 1200 or not isinstance(attempt, int) or not 1 <= attempt <= 32:
                raise ValueError('invalid peer attempt')
            payload[8] = attempt
        if (item.get('source_ip') != source_ip or item.get('source_port') != 44444 or
                item.get('payload_matches') is not True or
                item.get('sha256') != hashlib.sha256(payload).hexdigest()):
            raise ValueError('peer payload or source mismatch')
        hashes[str(length)] = item['sha256']
    return {'scope': 'log correlation only; candidate identity requires separate flash verification',
            'source_ip': source_ip, 'payload_sha256_by_bytes': hashes,
            'hosted_packet_fnv1a': '%08x' % fields['long_hash']}


def check_echo(log, peer_lines):
    result = check(log, peer_lines)
    row = next(line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_C6 '))
    fields = {name: int(value, 16) for name, value in (token.split('=', 1) for token in row.split()[1:])}
    if fields.get('short_echo', 0) < 1 or fields.get('long_echo', 0) < 1 or not 1 <= fields.get('long_attempts', 0) <= 5:
        raise ValueError('missing device echo confirmation')
    records = [json.loads(line) for line in peer_lines.splitlines() if line.strip()]
    echoed = {x.get('bytes') for x in records if x.get('event') in ('echoed', 'echoed_retry')}
    if not {64, 1200}.issubset(echoed):
        raise ValueError('missing peer echo sends')
    attempts = {x['attempt'] for x in records if x.get('event') == 'received' and x.get('attempt') is not None}
    if attempts:
        mask = fields.get('long_echo_mask', 0)
        if mask == 0 or mask >> fields['long_attempts'] or not any(mask & (1 << (n - 1)) for n in attempts):
            raise ValueError('device echo attempt does not match peer receipt')
        result.update(peer_attempts=sorted(attempts), long_echo_mask=mask)
    result.update(short_echo=fields['short_echo'], long_echo=fields['long_echo'], long_attempts=fields['long_attempts'])
    return result


if __name__ == '__main__':
    try:
        function = check_echo if len(sys.argv) == 4 and sys.argv[3] == '--echo' else check
        print(json.dumps(function(Path(sys.argv[1]).read_text(), Path(sys.argv[2]).read_text()), indent=2))
    except (ValueError, KeyError, IndexError, OSError) as error:
        sys.exit('Hosted UDP correlation failed: ' + str(error))

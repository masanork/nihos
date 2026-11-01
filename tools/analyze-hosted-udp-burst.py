#!/usr/bin/env python3
"""Summarize a bounded UDP trial; flash verification is a separate gate."""
import hashlib
import ipaddress
import json
import sys
from pathlib import Path


def analyze(log, peer_lines):
    if log.count('ESP-ROM:esp32p4') != 1 or log.count('NIHOS_C6_BOOT ') != 1 or 'NIHOS_C6_TRAP ' in log:
        raise ValueError('invalid boot boundaries')
    if log.count('NIHOS_C6_LONG_DMA build=diagnostic ') != 1 or log.count('NIHOS_C6_HOSTED_WIFI_PASS ') != 1:
        raise ValueError('diagnostic did not complete')
    rows = [line for line in log.splitlines() if line.startswith('NIHOS_NATIVE_C6 ')]
    if len(rows) != 1:
        raise ValueError('expected one report')
    fields = {}
    raw_fields = {}
    for token in rows[0].split()[1:]:
        name, value = token.split('=', 1)
        if name in fields:
            raise ValueError('duplicate field')
        fields[name] = int(value, 16)
        raw_fields[name] = value
    expected = {'status': 1, 'stage': 12, 'error_code': 0, 'cleanup_failed': 0,
                'fw_known': 1, 'fw_major': 1, 'fw_minor': 4, 'fw_patch': 1,
                'short_sent': 118, 'long_logical': 1254, 'long_wire': 1536,
                'long_sent': 1254, 'long_dma_state': 0, 'long_burst': 1}
    if any(fields.get(k) != v for k, v in expected.items()) or fields.get('short_echo', 0) < 1:
        raise ValueError('incomplete trial')
    count = fields.get('long_attempts')
    if count not in (16, 17, 18):
        raise ValueError('unexpected attempt count')
    reverse_lines = [line for line in log.splitlines() if line == 'NIHOS_C6_REVERSE_ATTEMPTS']
    if len(reverse_lines) > 1 or (reverse_lines and count != 16):
        raise ValueError('invalid reverse trace')
    send_order = list(range(count, 0, -1)) if reverse_lines else list(range(1, count + 1))
    if 'long_settle_ms' in fields and (fields['long_settle_ms'] not in (2000, 8000) or
            fields.get('long_final_wait_ms', 0) < fields['long_settle_ms']):
        raise ValueError('final observation window incomplete')
    mask = fields.get('long_echo_mask', 0)
    if mask >> count or fields.get('long_echo', 0) < bin(mask).count('1'):
        raise ValueError('invalid echo mask')
    source = str(ipaddress.IPv4Address(fields['ip']))
    records = [json.loads(line) for line in peer_lines.splitlines() if line.strip()]
    arrived, echoes, peer_times, marker_times = [], set(), [], []
    short_seen = False
    for item in records:
        if item.get('event') == 'received':
            length, attempt = item.get('bytes'), item.get('attempt')
            if length == 64 and attempt is None:
                short_seen = True
            elif length == 65 and attempt is None:
                if 'elapsed_us' not in item or not isinstance(item['elapsed_us'], int) or item['elapsed_us'] < 0:
                    raise ValueError('invalid short tail timestamp')
                marker_times.append(item['elapsed_us'])
            elif length == 1200 and isinstance(attempt, int) and 1 <= attempt <= count:
                arrived.append(attempt)
                if 'elapsed_us' in item:
                    if not isinstance(item['elapsed_us'], int) or item['elapsed_us'] < 0:
                        raise ValueError('invalid peer timestamp')
                    peer_times.append((attempt, item['elapsed_us']))
            else:
                raise ValueError('unexpected datagram')
            payload = bytearray(i % 256 for i in range(length))
            payload[:8] = b'NIHOSUDP'
            if attempt is not None:
                payload[8] = attempt
            if (item.get('source_ip') != source or item.get('source_port') != 44444 or
                    item.get('payload_matches') is not True or item.get('sha256') != hashlib.sha256(payload).hexdigest()):
                raise ValueError('peer identity or payload mismatch')
        elif item.get('event') == 'echoed' and item.get('attempt') is not None:
            echoes.add(item['attempt'])
    if not short_seen or not echoes.issubset(set(arrived)):
        raise ValueError('missing short control or invalid echo source')
    returned = {i + 1 for i in range(count) if mask & (1 << i)}
    if not returned.issubset(echoes):
        raise ValueError('device echo lacks matching peer echo')
    if peer_times and (len(peer_times) != len(arrived) or any(a[1] > b[1] for a, b in zip(peer_times, peer_times[1:]))):
        raise ValueError('incomplete or non-monotonic peer timestamps')
    observed = set(arrived)
    result = {'scope': 'one bounded run; flash verification and transport reliability are separate',
            'sent': count, 'send_order': send_order, 'configured_settle_ms': fields.get('long_settle_ms', 2000),
            'actual_final_wait_ms': fields.get('long_final_wait_ms'), 'peer_arrival_order': arrived, 'peer_unique': len(observed),
            'not_observed_by_peer': sorted(set(range(1, count + 1)) - observed),
            'peer_echo_send_ids': sorted(echoes), 'device_echo_ids': sorted(returned),
            'echo_not_observed_by_device': sorted(echoes - returned)}
    intervals = [line for line in log.splitlines() if line.startswith('NIHOS_C6_INTERVAL ')]
    if intervals:
        if len(intervals) != 1 or intervals[0] != 'NIHOS_C6_INTERVAL ms=000001f4' or count != 16 or reverse_lines:
            raise ValueError('invalid interval trace')
        result['configured_interval_ms'] = 500
    else:
        result['configured_interval_ms'] = 250
    staging_lines = [line for line in log.splitlines() if line.startswith('NIHOS_C6_STAGING ')]
    if staging_lines:
        if len(staging_lines) != 1 or count != 16 or reverse_lines:
            raise ValueError('invalid staging audit')
        fields_staging = dict(token.split('=', 1) for token in staging_lines[0].split()[1:])
        if set(fields_staging) != {'checked', 'matched'}:
            raise ValueError('invalid staging audit fields')
        checked, matched = int(fields_staging['checked'], 16), int(fields_staging['matched'], 16)
        if checked != 0xffff or matched & ~checked:
            raise ValueError('incomplete staging audit')
        result['staging_audit'] = {'checked_mask': checked, 'matched_mask': matched,
                                   'mismatch_attempts': [i + 1 for i in range(16) if not matched & (1 << i)]}
    if peer_times:
        first = peer_times[0][1]
        result['peer_arrival_us_from_first'] = [{'attempt': attempt, 'elapsed_us': timestamp - first} for attempt, timestamp in peer_times]
    tail_lines = [line for line in log.splitlines() if line.startswith('NIHOS_C6_SHORT_TAIL ')]
    if tail_lines:
        if len(tail_lines) != 1:
            raise ValueError('duplicate short tail trace')
        tail = dict(token.split('=', 1) for token in tail_lines[0].split()[1:])
        if set(tail) != {'sent', 'ms'} or int(tail['sent'], 16) != 119 or len(marker_times) > 1:
            raise ValueError('invalid short tail trace')
        result['short_tail'] = {'device_sent_bytes': int(tail['sent'], 16), 'device_sent_ms_from_control': int(tail['ms'], 16),
                                'peer_received': bool(marker_times), 'peer_elapsed_us': marker_times[0] if marker_times else None}
    elif marker_times:
        raise ValueError('unexpected short tail')
    names = ('trace_total', 'trace_credit', 'trace_counter', 'trace_send_ms', 'trace_duration_us', 'trace_stalls')
    if any(name in raw_fields for name in names):
        if any(len(raw_fields.get(name, '')) != count * 8 for name in names):
            raise ValueError('invalid transmit trace size')
        arrays = {name: [int(raw_fields[name][i:i + 8], 16) for i in range(0, count * 8, 8)] for name in names}
        trace = []
        for i in range(count):
            total, credit, counter = (arrays[name][i] for name in names[:3])
            if total > 4095 or counter > 4095 or credit != (total - counter) & 4095 or not 1 <= credit <= 64:
                raise ValueError('invalid transmit credit trace')
            trace.append({'attempt': send_order[i], 'credit_total': total, 'credit_available': credit,
                          'sent_counter_before': counter, 'sent_ms_from_control': arrays['trace_send_ms'][i],
                          'write_and_credit_us': arrays['trace_duration_us'][i], 'zero_credit_polls': arrays['trace_stalls'][i]})
        if any(a['sent_ms_from_control'] > b['sent_ms_from_control'] for a, b in zip(trace, trace[1:])):
            raise ValueError('non-monotonic transmit trace')
        result['device_tx_trace'] = trace
    lines = [line for line in log.splitlines() if line.startswith('NIHOS_C6_CREDIT_TRACE ')]
    if lines:
        if len(lines) != 1 or 'device_tx_trace' in result:
            raise ValueError('duplicate transmit trace')
        words = lines[0].split()[1:]
        if len(words) != count or any(len(word) != 16 for word in words):
            raise ValueError('invalid packed transmit trace size')
        trace = []
        for i, word in enumerate(words):
            credit_word, timing = int(word[:8], 16), int(word[8:], 16)
            total, counter, stalls = credit_word & 4095, (credit_word >> 12) & 4095, credit_word >> 24
            available = (total - counter) & 4095
            if not 1 <= available <= 64:
                raise ValueError('invalid packed transmit credit')
            trace.append({'attempt': send_order[i], 'credit_total': total, 'credit_available': available,
                          'sent_counter_before': counter, 'zero_credit_polls_capped': stalls,
                          'sent_ms_from_control_capped': timing & 65535,
                          'write_and_credit_us_capped': timing >> 16})
        if any(a['sent_ms_from_control_capped'] > b['sent_ms_from_control_capped'] for a, b in zip(trace, trace[1:])):
            raise ValueError('non-monotonic transmit trace')
        result['device_tx_trace'] = trace
    pauses = [line for line in log.splitlines() if line.startswith('NIHOS_C6_BEFORE_17 ')]
    if count == 17:
        if len(pauses) != 1 or 'device_tx_trace' not in result:
            raise ValueError('missing pause trace')
        snapshot = dict(token.split('=', 1) for token in pauses[0].split()[1:])
        if set(snapshot) != {'mask', 'ms'}:
            raise ValueError('invalid pause trace')
        before_mask, before_ms = int(snapshot['mask'], 16), int(snapshot['ms'], 16)
        times = result['device_tx_trace']
        sent16 = times[15].get('sent_ms_from_control_capped', times[15].get('sent_ms_from_control'))
        sent17 = times[16].get('sent_ms_from_control_capped', times[16].get('sent_ms_from_control'))
        if before_mask >> 16 or before_mask & ~mask or before_ms < sent16 + 2000 or before_ms > sent17:
            raise ValueError('invalid pause snapshot')
        result['before_17'] = {'echo_mask': before_mask, 'echo_16': bool(before_mask & (1 << 15)), 'device_ms_from_control': before_ms}
    elif pauses:
        raise ValueError('unexpected pause trace')
    return result


if __name__ == '__main__':
    try:
        print(json.dumps(analyze(Path(sys.argv[1]).read_text(), Path(sys.argv[2]).read_text()), indent=2))
    except (ValueError, KeyError, IndexError, OSError) as error:
        sys.exit('Hosted UDP burst analysis failed: ' + str(error))

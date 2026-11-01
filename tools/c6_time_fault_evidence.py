#!/usr/bin/env python3
"""Validate one bounded Tab5 C6 time-loss capture without printing addresses."""
import hashlib
import json
import re
import sys
from pathlib import Path


def check(data: bytes):
    text = data.decode('ascii', errors='replace')
    if re.search(r'^NIHOS_NATIVE_(?:TRAP|FAIL|PANIC)\b', text, re.MULTILINE):
        raise ValueError('device fault')
    records = {}
    for index, line in enumerate(text.splitlines()):
        parts = line.split()
        if not parts or not parts[0].startswith('NIHOS_NATIVE_'):
            continue
        try:
            fields = {k: int(v, 16) for k, v in (item.split('=', 1) for item in parts[1:])}
        except (ValueError, TypeError):
            continue
        records.setdefault(parts[0], []).append((index, fields))
    def need(name):
        values = records.get('NIHOS_NATIVE_' + name, [])
        if not values:
            raise ValueError('missing ' + name)
        return values
    fault_index, fault = next(((i, v) for i, v in need('C6_TIME_FAULT') if v.get('stage') == 2), (None, {}))
    if fault.get('stage') != 2 or fault.get('dropped', 0) < 1 or fault.get('expired') != 1:
        raise ValueError('fault injection did not complete')
    ntp_index, ntp = next(((i, v) for i, v in need('NTP') if i > fault_index and v.get('replies', 0) >= 1), (None, {}))
    if ntp.get('attempts', 0) < 2 or ntp.get('failures', 0) < 1 or ntp.get('replies', 0) < 1:
        raise ValueError('time retry did not complete')
    rtc_index, rtc = next(((i, v) for i, v in need('RTC_SYNC') if i > ntp_index and v.get('applied', 0) >= 1), (None, {}))
    if (rtc.get('applied', 0) < 1 or rtc.get('failures') != 0 or rtc.get('error_code') != 0 or
            rtc.get('unix_high') != ntp.get('unix_high') or rtc.get('unix_low') != ntp.get('unix_low') or
            not ntp.get('unix_low')):
        raise ValueError('RTC update failed')
    network_records = need('NETWORK')
    if network_records[-1][0] <= rtc_index:
        raise ValueError('missing post-update network report')
    network = [v for _, v in network_records if v.get('ip', 0) != 0]
    if len(network) < 2 or any(v.get('reconnects') != 0 or v.get('failures') != 0 or
                               v.get('acquisitions') != 1 or v.get('ip') != network[0]['ip'] for v in network):
        raise ValueError('station was lost or reset')
    ui_records = need('NETWORK_UI')
    if ui_records[-1][0] <= rtc_index:
        raise ValueError('missing post-update UI report')
    ui = [v for _, v in ui_records]
    if len(ui) < 2 or any(ui[-1].get(k, 0) <= ui[0].get(k, 0) for k in ('frames', 'ticks0', 'ticks1')):
        raise ValueError('UI or core counters did not advance')
    ble_index, ble = need('BLE')[-1]
    if ble_index <= rtc_index:
        raise ValueError('missing post-update BLE report')
    if ble.get('phase') != 4 or ble.get('status') != 0 or ble.get('timeouts') != 0:
        raise ValueError('BLE did not remain ready')
    return {'capture_sha256': hashlib.sha256(data).hexdigest(), 'fault': fault,
            'time_attempts': ntp['attempts'], 'time_failures': ntp['failures'],
            'time_replies': ntp['replies'], 'rtc_applied': rtc['applied'],
            'network_reconnects': network[-1]['reconnects'], 'ble_phase': ble['phase'],
            'ui_frames_delta': ui[-1]['frames'] - ui[0]['frames']}


if __name__ == '__main__':
    try:
        print(json.dumps(check(Path(sys.argv[1]).read_bytes()), indent=2))
    except (IndexError, ValueError, OSError) as exc:
        sys.exit('C6 time fault evidence rejected: ' + str(exc))

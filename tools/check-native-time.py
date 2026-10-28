#!/usr/bin/env python3
"""Validate NTP-to-RTC capture, unavailable-AP control, or no-NTP warm retention."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re


def rows(log, marker, fields):
    result = []
    for line in log.replace('\r', '').splitlines():
        if not line.startswith(marker + ' '):
            continue
        value = line[len(marker) + 1:]
        if not re.fullmatch(r'[a-z0-9_]+=[0-9a-f]{8}(?: [a-z0-9_]+=[0-9a-f]{8})*', value):
            raise ValueError('malformed ' + marker)
        pairs = re.findall(r'([a-z0-9_]+)=([0-9a-f]{8})', value)
        data = {key: int(number, 16) for key, number in pairs}
        if len(data) != len(pairs) or not set(fields).issubset(data):
            raise ValueError('duplicate/missing ' + marker + ' field')
        result.append(data)
    if not result:
        raise ValueError('missing ' + marker)
    return result


def utc(row):
    return int(datetime.datetime(*(row[key] for key in ('year', 'month', 'day', 'hour', 'minute', 'second')),
                                 tzinfo=datetime.timezone.utc).timestamp())


def check(log, mode='sync', seconds=180):
    if log.count('ESP-ROM:esp32p4') != 1 or any(word in log for word in ('NIHOS_NATIVE_FAIL', 'NIHOS_NATIVE_TRAP', 'NIHOS_C6_BOOT')):
        raise ValueError('mixed boot or native failure')
    devices = rows(log, 'NIHOS_NATIVE_DEVICES', ('rtc_present', 'rtc_valid', 'rtc_error', 'rtc_flags', 'year', 'month', 'day', 'hour', 'minute', 'second', 'errors'))
    ui = rows(log, 'NIHOS_NATIVE_NETWORK_UI', ('frames', 'ticks0', 'ticks1'))
    if len(ui) < 2 or any(ui[-1][key] <= ui[0][key] for key in ('frames', 'ticks0', 'ticks1')) or any(row['errors'] for row in devices):
        raise ValueError('I2C failure or stopped UI/hart')
    valid = [row for row in devices if row['rtc_present'] == row['rtc_valid'] == 1 and row['rtc_error'] == 0 and row['rtc_flags'] & 2 == 0]
    if mode == 'unavailable':
        ntp = rows(log, 'NIHOS_NATIVE_NTP', ('attempts', 'replies'))
        sync = rows(log, 'NIHOS_NATIVE_RTC_SYNC', ('applied', 'failures', 'error_code'))
        if any(row['attempts'] or row['replies'] for row in ntp) or any(row['applied'] or row['failures'] or row['error_code'] for row in sync):
            raise ValueError('unavailable AP caused NTP/RTC activity')
        return {'scope': 'unavailable AP; no NTP requests or RTC write attempts', 'ui_final': ui[-1], 'rtc_applied': 0}
    if len(valid) < 2 or utc(valid[-1]) <= utc(valid[0]):
        raise ValueError('missing valid advancing UTC RTC')
    if mode == 'retention':
        if 'NIHOS_NATIVE_NTP ' in log or 'NIHOS_NATIVE_RTC_SYNC ' in log or len(valid) != len(devices):
            raise ValueError('retention must have valid RTC throughout with NTP absent')
        return {'scope': 'UTC RTC advances across warm reset with NTP code absent; cold power-cycle unqualified',
                'rtc_first_unix': utc(valid[0]), 'rtc_last_unix': utc(valid[-1]), 'ui_final': ui[-1]}
    network = rows(log, 'NIHOS_NATIVE_NETWORK', ('acquisitions', 'ip'))
    ntp = rows(log, 'NIHOS_NATIVE_NTP', ('phase', 'attempts', 'replies', 'rejected', 'failures', 'stratum', 'rtt_us', 'unix_high', 'unix_low'))
    sync = rows(log, 'NIHOS_NATIVE_RTC_SYNC', ('applied', 'failures', 'error_code', 'unix_high', 'unix_low'))
    result, applied = ntp[-1], sync[-1]
    stamp = result['unix_high'] << 32 | result['unix_low']
    written = applied['unix_high'] << 32 | applied['unix_low']
    recovered = mode == 'recovered-sync'
    if recovered:
        pending = [index for index, row in enumerate(ntp) if (row['phase'], row['attempts'], row['replies'], row['failures']) == (4, 1, 0, 0)]
        failed = [index for index, row in enumerate(ntp) if (row['phase'], row['attempts'], row['replies'], row['failures']) == (1, 1, 0, 1)]
        finished = [index for index, row in enumerate(ntp) if (row['phase'], row['attempts'], row['replies'], row['failures']) == (1, 2, 1, 1)]
        if (not pending or not failed or not finished or not pending[0] < failed[0] < finished[0] or
                any(row['attempts'] > 2 or row['replies'] > 1 or row['failures'] > 1 for row in ntp) or
                any(a[key] > b[key] for a, b in zip(ntp, ntp[1:]) for key in ('attempts', 'replies', 'failures'))):
            raise ValueError('missing ordered failed request and recovered reply history')
        first_reply = re.search(r'^NIHOS_NATIVE_NTP (?=.*\breplies=00000001\b).*$', log.replace('\r', ''), re.M)
        earlier = rows(log.replace('\r', '')[:first_reply.start()], 'NIHOS_NATIVE_RTC_SYNC', ('applied', 'failures', 'error_code'))
        if any(row['applied'] or row['failures'] or row['error_code'] for row in earlier):
            raise ValueError('RTC write before a valid recovered NTP reply')
    expected_attempts, expected_failures = (2, 1) if recovered else (1, 0)
    if (not network[-1]['acquisitions'] or not network[-1]['ip'] or result['replies'] != 1 or
            result['attempts'] != expected_attempts or result['failures'] != expected_failures or
            any(row['rejected'] or row['failures'] > expected_failures for row in ntp) or
            not 1 <= result['stratum'] <= 15 or not 0 < result['rtt_us'] <= 2_000_000 or
            applied['applied'] != 1 or any(row['failures'] or row['error_code'] for row in sync) or
            not 0 <= written - stamp <= 5 or not written <= utc(valid[-1]) <= written + seconds + 2):
        raise ValueError('missing/mismatched NTP, RTC application, DHCP or cleanup evidence')
    return {'scope': ('one failed SNTP request followed by recovered UTC RTC application' if recovered else
                      'public SNTP response correlated and UTC RTC written/read back; unauthenticated wall time'),
            'ntp': {key: result[key] for key in ('attempts', 'replies', 'failures', 'stratum', 'rtt_us')},
            'ntp_unix': stamp, 'rtc_written_unix': written, 'rtc_final_unix': utc(valid[-1]),
            'rtc_valid_records': len(valid), 'ui_final': ui[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--mode', choices=('sync', 'recovered-sync', 'unavailable', 'retention'), default='sync')
    args = parser.parse_args()
    root = args.capture
    metadata = json.loads((root / 'result.json').read_text())
    candidate = root / 'candidate'
    audit = json.loads((candidate / 'retained-loader-audit.json').read_text())
    receipt = json.loads((candidate / 'network-receipt.json').read_text())
    raw = (root / 'serial.log').read_bytes()
    digest = lambda value: hashlib.sha256(value).hexdigest()
    if (metadata.get('written') is not True or metadata.get('restored') is not True or metadata.get('native_fail') is not False or
            digest(raw) != metadata['serial_sha256'] or receipt['sdk_dirty'] or
            any(digest((candidate / name).read_bytes()) != receipt['artifacts'][name] for name in ('nihos-native.bin', 'nihos-native.elf', 'native_options.zig')) or
            digest((candidate / 'nihos-native.elf').read_bytes()) != audit['elf_sha256'] or
            digest((candidate / 'nihos-native.bin').read_bytes()) != metadata['app_sha256'] or metadata['app_sha256'] != audit['image_sha256'] or
            bool(audit.get('time_text')) != (args.mode != 'retention')):
        raise ValueError('capture/image/profile/restoration identity mismatch')
    result = check(raw.decode('ascii', errors='replace'), args.mode, metadata['seconds'])
    if args.mode == 'retention':
        started = int(datetime.datetime.fromisoformat(metadata['at']).timestamp())
        if not 0 <= result['rtc_first_unix'] - started <= 120:
            raise ValueError('RTC retention differs from capture UTC')
    result.update(image_sha256=metadata['app_sha256'], raw_serial_sha256=metadata['serial_sha256'], restored=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Native time evidence passed: ' + args.mode)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check one idle/overlap/alternation/repeat device exercise, with image identity."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name('check-native-' + name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


AUDIO, MICROPHONE, RS485 = (module(name) for name in ('audio', 'microphone', 'rs485'))
REQUEST_FIELDS = ('kind', 'accepted', 'i2s_owner', 'pinned', 'workspace')
SERVICE_FIELDS = ('available', 'requested', 'i2s_owner', 'pinned', 'workspace')
# :devices, mic+rejected audio, :devices, audio+rejected mic, :devices,
# second mic, :devices, UART loopback twice, :devices.
EXPECTED = ((5, 1, 0), (2, 1, 2), (1, 0, 2), (5, 1, 0), (1, 1, 1), (2, 0, 1),
            (5, 1, 0), (2, 1, 2), (5, 1, 0), (3, 1, 0), (3, 1, 0), (5, 1, 0))


def check(log):
    if log.count('ESP-ROM:esp32p4') != 1 or any(word in log for word in ('NIHOS_NATIVE_FAIL', 'NIHOS_NATIVE_TRAP', 'NIHOS_C6_BOOT')):
        raise ValueError('mixed boot or native failure')
    requests = AUDIO.records(log, 'NIHOS_DEVICE_REQUEST', REQUEST_FIELDS)
    positions = [match.start() for match in re.finditer(r'^NIHOS_DEVICE_REQUEST ', log, re.M)]
    if len(requests) != len(EXPECTED):
        raise ValueError('missing or additional request')
    for index, (row, expected) in enumerate(zip(requests, EXPECTED)):
        if (tuple(row[key] for key in REQUEST_FIELDS[:3]) != expected or row['pinned'] or
                row['workspace'] != (0 if index == 0 else 1536)):
            raise ValueError('request/overlap/cleanup/workspace mismatch at ' + str(index))
    if any(marker in log[:positions[1]] for marker in ('NIHOS_NATIVE_AUDIO ', 'NIHOS_NATIVE_MICROPHONE ', 'NIHOS_NATIVE_RS485 ')):
        raise ValueError('device activity before request')
    idle = AUDIO.records(log[:positions[1]], 'NIHOS_NATIVE_DEVICE_SERVICE', SERVICE_FIELDS)
    if len(idle) < 2 or any(row != dict(zip(SERVICE_FIELDS, (7, 0, 0, 0, 0))) for row in idle):
        raise ValueError('drivers are not idle before explicit request')
    services = AUDIO.records(log, 'NIHOS_NATIVE_DEVICE_SERVICE', SERVICE_FIELDS)
    if (any(row['available'] != 7 or row['pinned'] or row['workspace'] not in (0, 1536) for row in services) or
            services[-1] != dict(zip(SERVICE_FIELDS, (7, 7, 0, 0, 1536)))):
        raise ValueError('final availability/cleanup/workspace mismatch')
    runs = []
    for kind, checker in ((1, AUDIO.check), (2, MICROPHONE.check), (3, RS485.check)):
        starts = [positions[index] for index, row in enumerate(requests) if row['kind'] == kind and row['accepted']]
        for start, end in zip(starts, starts[1:] + [len(log)]):
            runs.append({'kind': kind, 'result': checker('ESP-ROM:esp32p4\n' + log[start:end])})
    ui = AUDIO.records(log, 'NIHOS_NATIVE_NETWORK_UI', ('frames', 'ticks0', 'ticks1'))
    if len(ui) < 3 or any(ui[-1][key] <= ui[0][key] for key in ui[-1]):
        raise ValueError('display or either hart stopped progressing')
    return {'scope': 'combined native idle/overlap/alternation/repeat controller exercise; audible quality and external RS485 unqualified',
            'requests': len(requests), 'operations': runs, 'idle_reports': len(idle),
            'service_final': services[-1], 'ui_first': ui[0], 'ui_final': ui[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    root = args.capture
    metadata = json.loads((root / 'result.json').read_text())
    candidate = root / 'candidate'
    audit = json.loads((candidate / 'retained-loader-audit.json').read_text())
    receipt = json.loads((candidate / 'network-receipt.json').read_text())
    raw = (root / 'serial.log').read_bytes()
    image = (candidate / 'nihos-native.bin').read_bytes()
    elf = (candidate / 'nihos-native.elf').read_bytes()
    options = (candidate / 'native_options.zig').read_bytes()
    digest = lambda data: hashlib.sha256(data).hexdigest()
    if (metadata.get('written') is not True or metadata.get('restored') is not True or metadata.get('native_fail') is not False or
            digest(raw) != metadata['serial_sha256'] or digest(image) != metadata['app_sha256'] or
            digest(elf) != audit['elf_sha256'] or receipt['artifacts']['nihos-native.elf'] != digest(elf) or
            digest(image) != audit['image_sha256'] or receipt['artifacts']['nihos-native.bin'] != digest(image) or
            receipt['artifacts']['native_options.zig'] != digest(options) or receipt['sdk_dirty'] or
            audit.get('device_text', {}).get('foreground_only') is not True or audit['heap']['bytes'] < 49152 or
            any('pub const ' + key + ' = true;' not in options.decode() for key in ('devices', 'network', 'console_live')) or
            any('pub const ' + key + ' = false;' not in options.decode() for key in ('audio', 'microphone', 'rs485'))):
        raise ValueError('candidate/restore/log/profile identity mismatch')
    result = check(raw.decode('ascii', errors='replace').replace('\r', ''))
    result.update(evidence='physical-device', image_sha256=digest(image), serial_sha256=digest(raw), restored=True)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Combined device idle, exclusion, repeat, cleanup and UI progression passed')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Validate an RV32 offscreen Canvas run and its retained artifacts."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_log', ROOT / 'tools/check-native-log.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_records(log):
    records = re.findall(r'^NIHOS_NATIVE_CANVAS_OFFSCREEN checksum=([0-9a-f]{8}) frame_bytes=([0-9a-f]{8}) guard_bytes=([0-9a-f]{8})\r?$', log, re.M)
    marker = 'NIHOS_NATIVE_CANVAS_OFFSCREEN_PASS'
    if records != [('549e3481', '001c2000', '00000010')] or log.count(marker) != 1:
        raise ValueError('missing or invalid canvas record')
    if log.index('NIHOS_NATIVE_FP_PASS') > log.index('NIHOS_NATIVE_CANVAS_OFFSCREEN checksum=') or log.index('NIHOS_NATIVE_CANVAS_OFFSCREEN checksum=') > log.index(marker) or 'NIHOS_NATIVE_FAIL' in log:
        raise ValueError('invalid canvas marker ordering')

def check(log, audit, image, elf, options):
    if audit.get('image_sha256') != digest(image) or audit.get('elf_sha256') != digest(elf):
        raise ValueError('image/ELF hash differs from audit')
    lines = options.read_text().splitlines()
    for flag, value in [('canvas_offscreen', 'true'), ('canvas_demo', 'false'),
                        ('qualification', 'true'), ('display', 'false')]:
        if lines.count(f'pub const {flag} = {value};') != 1:
            raise ValueError('unexpected native option ' + flag)
    validate_records(log)
    core = native.check(log, 'integer', 32 << 20, audit, 'emulator', require_qualification=True, canvas_offscreen=True)
    return {'evidence': 'esp32p4-emulator-offscreen', 'width': 720, 'height': 1280,
            'stride': 1440, 'cpu_fnv1a': '549e3481', 'guard_bytes': 16,
            'image_sha256': digest(image), 'elf_sha256': digest(elf), 'core': core}


if __name__ == '__main__':
    directory = Path(sys.argv[1])
    try:
        result = check((directory / 'emulator.log').read_text(), json.loads((directory / 'image-audit.json').read_text()),
                       directory / 'nihos-native.bin', directory / 'nihos-native.elf', directory / 'native_options.zig')
    except (ValueError, OSError) as exc:
        raise SystemExit('Canvas offscreen failed: ' + str(exc)) from exc
    flash = directory / 'nihos-native-flash.bin'
    app = (directory / 'nihos-native.bin').read_bytes()
    if flash.read_bytes()[0x10000:0x10000 + len(app)] != app:
        raise SystemExit('Canvas offscreen failed: merged flash does not contain audited application')
    result['flash_sha256'] = digest(flash)
    result['log_sha256'] = digest(directory / 'emulator.log')
    (directory / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    print('RV32 canvas offscreen and 16-byte guard passed (emulator only)')

#!/usr/bin/env python3
"""Generate Zig table from pinned Espressif SC202CS register data."""
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'third_party/sc202cs/sc202cs_mipi_1lane_24Minput_1280x720_raw8_30fps.h'
DEST = ROOT / 'src/board/tab5/sc202cs_720p_table.zig'
SHA = 'c30c93bdda9aa66a046e45183c19c5dda5c4a7c50c1b1577ebbe0cf35e4447cf'

def generate():
    raw = SOURCE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SHA:
        raise ValueError('unexpected upstream table')
    rows = []
    for original in raw.decode().splitlines():
        line = original.split('//', 1)[0].strip()
        match = re.fullmatch(r'\{(0x[0-9a-f]+|SC202CS_REG_SLEEP_MODE|SC202CS_REG_END),\s*(0x[0-9a-f]+)\},', line)
        if not match:
            if line.startswith('{'): raise ValueError('unrecognized register row')
            continue
        reg, value = match.groups()
        if reg == 'SC202CS_REG_END': break
        reg = 0x0100 if reg == 'SC202CS_REG_SLEEP_MODE' else int(reg, 16)
        rows.append((reg, int(value, 16)))
    if len(rows) < 100 or rows[:2] != [(0x0103, 1), (0x0100, 0)] or any(r == 0x0100 and v != 0 for r, v in rows):
        raise ValueError('unexpected table or stream-on operation')
    return ('//! Derived from Espressif esp_cam_sensor 2.0.1 SC202CS table.\n'
            '//! Copyright 2025 Espressif Systems (Shanghai) CO LTD. Apache-2.0.\n'
            '//! Source and license: third_party/sc202cs; generated, do not edit.\n'
            'pub const Reg = struct { address: u16, value: u8 };\n'
            'pub const entries = [_]Reg{\n' + ''.join('    .{ .address = 0x%04x, .value = 0x%02x },\n' % row for row in rows) + '};\n')

if __name__ == '__main__':
    import sys
    content = generate()
    if '--check' in sys.argv:
        if DEST.read_text() != content: raise SystemExit('generated register table differs')
    else:
        DEST.write_text(content)

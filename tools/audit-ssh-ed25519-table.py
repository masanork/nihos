#!/usr/bin/env python3
"""Inspect the pinned Zig Ed25519 base table in an ELF; never qualifies code safety."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

SIZE = 2688
SHA256 = '97dfc18d19f9cf8952f9409cffe06bba8804cfdc21a731ff9705dc887e49f75b'


def inspect(path):
    elf = Path(path).read_bytes()
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    if header[0][:6] != b'\x7fELF\x01\x01':
        raise ValueError('expected little-endian ELF32')
    if header[11] != 40 or header[12] == 0:
        raise ValueError('invalid section table')
    sections = [struct.unpack_from('<10I', elf, header[6] + i * header[11]) for i in range(header[12])]
    found = []
    table = None
    for sec in sections:
        if sec[1] != 2 or sec[9] != 16 or sec[6] >= len(sections):
            continue
        strings = sections[sec[6]]
        names = elf[strings[4]:strings[4] + strings[5]]
        for offset in range(sec[4], sec[4] + sec[5], sec[9]):
            name_offset, address, size, _, _, index = struct.unpack_from('<IIIBBH', elf, offset)
            if size != SIZE or index >= len(sections) or name_offset >= len(names):
                continue
            parent = sections[index]
            relative = address - parent[3]
            if parent[1] == 8 or relative < 0 or relative + size > parent[5]:
                continue
            data = elf[parent[4] + relative:parent[4] + relative + size]
            if hashlib.sha256(data).hexdigest() != SHA256:
                continue
            name_end = names.find(b'\0', name_offset)
            if name_end < 0:
                raise ValueError('invalid symbol name')
            table = data
            found.append({'symbol': names[name_offset:name_end].decode('utf-8', 'replace'), 'address': hex(address)})
    copies = []
    if table is not None:
        for sec in sections:
            if sec[1] == 8 or not sec[2] & 2:
                continue
            data = elf[sec[4]:sec[4] + sec[5]]
            start = 0
            while True:
                pos = data.find(table, start)
                if pos < 0:
                    break
                address = sec[3] + pos
                copies.append({'address': hex(address), 'writable': bool(sec[2] & 1),
                               'region': 'sram' if 0x4ff00000 <= address < 0x50000000 else
                                         'mapped_flash' if 0x40000000 <= address < 0x41000000 else 'other'})
                start = pos + 1
    return {'table_sha256': SHA256, 'table_bytes': SIZE, 'symbols': found, 'copies': copies}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf')
    parser.add_argument('--require-flash', action='store_true', help='require exactly one read-only mapped Flash copy and no other copies')
    args = parser.parse_args()
    result = inspect(args.elf)
    print(json.dumps(result, indent=2))
    if args.require_flash and (len(result['copies']) != 1 or result['copies'][0]['region'] != 'mapped_flash' or result['copies'][0]['writable']):
        raise SystemExit('Ed25519 table is missing, duplicated, writable, or outside mapped Flash')


if __name__ == '__main__':
    main()

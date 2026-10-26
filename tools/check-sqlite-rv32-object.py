#!/usr/bin/env python3
"""Inspect compile-only RV32 objects; this is neither a native link nor execution."""
import hashlib
import json
from pathlib import Path
import struct
import sys


def inspect(path):
    data = Path(path).read_bytes()
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('expected little-endian ELF32')
    header = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    if header[0] != 1 or header[1] != 243:
        raise ValueError('expected relocatable RISC-V object')
    sections = [struct.unpack_from('<10I', data, header[5] + i * header[10]) for i in range(header[11])]
    table = sections[header[12]]
    names = data[table[4]:table[4] + table[5]]
    sections_named = [(names[s[0]:names.index(0, s[0])].decode(), s) for s in sections]
    defined, undefined, fingerprint = set(), set(), None
    for section in sections:
        if section[1] != 2:
            continue
        table = sections[section[6]]
        strings = data[table[4]:table[4] + table[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            index, value, size, info, _, target = struct.unpack_from('<IIIBBH', data, offset)
            if not index or not info >> 4:
                continue
            name = strings[index:strings.index(0, index)].decode()
            if target == 0:
                undefined.add(name)
            else:
                defined.add(name)
            if name == 'nih_sqlite_rv32_abi':
                location = sections[target][4] + value
                fingerprint = list(struct.unpack_from('<' + 'I' * (size // 4), data, location))
    return {'path': str(path), 'sha256': hashlib.sha256(data).hexdigest(),
            'elf_flags': header[6], 'float_abi_bits': header[6] & 6,
            'executable_section_bytes': sum(s[5] for s in sections if s[2] & 4),
            'read_only_allocated_bytes': sum(s[5] for s in sections if s[2] & 2 and not s[2] & 5),
            'writable_allocated_bytes': sum(s[5] for s in sections if s[2] & 3 == 3),
            'sections': [{'name': name, 'bytes': s[5], 'flags': s[2], 'type': s[1]} for name, s in sections_named if s[2] & 2],
            'defined_symbols': sorted(defined), 'undefined_symbols': sorted(undefined), 'abi_fingerprint': fingerprint}


def record(directory):
    directory = Path(directory)
    objects = [inspect(directory / name) for name in ('sqlite3.o', 'session.o', 'abi.o')]
    provided = set().union(*(set(item['defined_symbols']) for item in objects))
    unresolved = set().union(*(set(item['undefined_symbols']) for item in objects)) - provided
    abi = objects[2]['abi_fingerprint']
    if abi is None or abi[0] != 0x53514c33 or abi[2:5] != [4, 4, 32] or abi[6:9] != [16, 0, 8]:
        raise ValueError('unexpected target C/SQLite layout')
    integer_only = directory.name.endswith('integer-sql')
    if abi[9:11] != [int(integer_only)] * 2:
        raise ValueError('SQLite omitted-FP public function type mismatch')
    if set(('malloc', 'free', 'realloc', 'calloc')) & unresolved:
        raise ValueError('unexpected system allocator fallback')
    expected_flags = 2 if directory.name.startswith('ilp32f-') else 0
    if any(item['float_abi_bits'] != expected_flags for item in objects):
        raise ValueError('inconsistent ELF floating-point ABI')
    result = {'schema': 1, 'evidence': 'compile-only-rv32-freestanding-objects',
              'headers': 'Zig-pinned musl declaration headers only; no musl runtime linked',
              'native_image_linked': False, 'code_executed': False,
              'unreferenced_sections_removed': False, 'integer_sql_changes_public_fp_types': integer_only,
              'objects': objects, 'remaining_external_symbols': sorted(unresolved)}
    (directory / 'object-report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(directory.name, 'SQLite text', objects[0]['executable_section_bytes'],
          'rodata', objects[0]['read_only_allocated_bytes'], 'external symbols', len(unresolved))


if __name__ == '__main__':
    record(sys.argv[1])

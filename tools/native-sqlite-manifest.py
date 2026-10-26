#!/usr/bin/env python3
"""Capture C object functions explicitly permitted in the SQLite Flash span."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def functions(path):
    data = Path(path).read_bytes()
    if data[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('expected ELF32 object')
    header = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    if header[0] != 1 or header[1] != 243 or header[10] != 40:
        raise ValueError('expected relocatable RISC-V object')
    sections = [struct.unpack_from('<10I', data, header[5] + index * 40)
                for index in range(header[11])]
    result = set()
    for section in sections:
        if section[1] != 2:
            continue
        table = sections[section[6]]
        strings = data[table[4]:table[4] + table[5]]
        for position in range(section[4], section[4] + section[5], 16):
            name, _, _, info, _, target = struct.unpack_from('<IIIBBH', data, position)
            if name and info & 15 == 2 and 0 < target < len(sections):
                result.add(strings[name:strings.index(0, name)].decode())
    return sorted(result)


def main(directory, source):
    objects = {name: {'sha256': sha(directory / name), 'functions': functions(directory / name)}
               for name in ('sql_sqlite3.o', 'sql_session.o', 'sql_vfs.o')}
    profile_path = Path(__file__).resolve().parents[1] / 'src/kernel/size_pool.zig'
    matches = re.findall(r'sqlite_probe = Config\{ \.counts = \.\{([^}]+)\}', profile_path.read_text())
    if len(matches) != 1:
        raise ValueError('missing/ambiguous SQLite pool profile')
    quotas = [int(value.strip()) for value in matches[0].split(',') if value.strip()]
    if len(quotas) != 10 or not all(0 < value <= 65535 for value in quotas):
        raise ValueError('invalid pool quotas')
    result = {'schema': 1, 'pool_quotas': quotas, 'pool_profile_sha256': sha(profile_path),
              'purpose': 'explicit native SQLite Flash function allowlist; not attestation',
              'objects': objects, 'sqlite_source_sha256': sha(source / 'sqlite3.c'),
              'allowed_functions': sorted(set().union(*(set(item['functions']) for item in objects.values())))}
    (directory / 'sqlite-manifest.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main(*map(Path, sys.argv[1:]))

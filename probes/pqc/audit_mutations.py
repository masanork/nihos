#!/usr/bin/env python3
"""Apply independent negative controls to a retained PQC-XIP ELF."""
import importlib.util
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_image', ROOT / 'tools/check-native-image.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)

def rejected(data, label):
    try:
        a.audit(data, None, 'integer', 'device')
    except ValueError as error:
        print(f'{label}: rejected: {error}')
        return
    raise ValueError(label + ' unexpectedly accepted')

def rename(data, old, new):
    old += b'\0'
    new += b'\0'
    if len(old) != len(new) or old not in data:
        raise ValueError('invalid mutation')
    return data.replace(old, new)

def main(path):
    data = Path(path).read_bytes()
    a.audit(data, None, 'integer', 'device')
    rejected(rename(data, b'nih_pqc_arena_alloc', b'nih_pqc_arena_allox'), 'unapproved function')
    rejected(rename(data, b'__native_pqc_xip', b'__native_pqc_xiy'), 'missing profile marker')
    header = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
    shoff, stride, count, strings_index = header[5], header[10], header[11], header[12]
    sections = [struct.unpack_from('<10I', data, shoff + i * stride) for i in range(count)]
    table = sections[strings_index]
    names = data[table[4]:table[4] + table[5]]
    for i, section in enumerate(sections):
        name = names[section[0]:names.index(0, section[0])]
        if name == b'.flash.pqc.rodata':
            changed = bytearray(data)
            struct.pack_into('<I', changed, shoff + i * stride + 8, 6)
            rejected(changed, 'executable read-only data')
            break
    else:
        raise ValueError('PQC rodata section absent')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: audit_mutations.py ELF')
    main(sys.argv[1])

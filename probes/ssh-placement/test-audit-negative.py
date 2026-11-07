#!/usr/bin/env python3
"""Negative controls for the exact-function study; mutates only temporary ELF copies."""
import importlib.util
import struct
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('study_audit', Path(__file__).with_name('audit-link-study.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
original = bytearray(Path(sys.argv[1]).read_bytes())
audit.check_sram_copies(sys.argv[1])
h = struct.unpack_from('<16sHHIIIIIHHHHHH', original)
sections = [struct.unpack_from('<10I', original, h[6]+i*h[11]) for i in range(h[12])]
selected = []
for sec in sections:
    if sec[1] != 2: continue
    st = sections[sec[6]]; names = original[st[4]:st[4]+st[5]]
    for off in range(sec[4], sec[4]+sec[5], sec[9]):
        n, address, size, _, _, idx = struct.unpack_from('<IIIBBH', original, off)
        end = names.find(b'\0', n)
        name = names[n:end].decode('utf-8', 'replace')
        if name in audit.expected and size >= 32:
            selected.append((size, off, address, idx))
size, symbol_offset, address, index = min(selected)
parent = sections[index]
code_offset = parent[4] + address-parent[3]
code = original[code_offset:code_offset+size]
sram = next(s for s in sections if s[1] != 8 and s[2] & 3 == 3 and 0x4ff00000 <= s[3] < 0x50000000 and s[5] >= size)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'negative-do-not-flash.elf'
    moved = original.copy()
    struct.pack_into('<I', moved, symbol_offset+4, sram[3])
    path.write_bytes(moved)
    try:
        audit.check_sram_copies(path)
    except ValueError as err:
        assert 'outside xy Flash' in str(err)
    else:
        raise SystemExit('misplaced function was accepted')
    duplicated = original.copy()
    duplicated[sram[4]:sram[4]+size] = code
    path.write_bytes(duplicated)
    try:
        audit.check_sram_copies(path)
    except ValueError as err:
        assert 'SRAM byte copy' in str(err)
    else:
        raise SystemExit('SRAM code copy was accepted')
print('Study audit rejected a misplaced function and a complete SRAM code copy')

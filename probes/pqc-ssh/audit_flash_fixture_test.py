#!/usr/bin/env python3
"""Negative controls against a real fixture ELF; never execute mutated images."""
import importlib.util
import struct
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('pqc_audit', Path(__file__).with_name('audit_flash_fixture.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
elf = bytearray(Path(sys.argv[1]).read_bytes())
mod.check_no_resident_copies(elf)
header = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
sections = [struct.unpack_from('<10I', elf, header[6] + i * header[11]) for i in range(header[12])]
resident = next(s for s in sections if s[1] == 1 and s[2] & 2 and 0x4ff00000 <= s[3] < 0x50000000 and s[5] >= 256)
strings = next(s for s in sections if s[1] == 2)
strtab = sections[strings[6]]
needle = (b'nih_pqc_ssh_job_roots\0' if 'nih_pqc_ssh_job_roots' in mod.EXPECTED else b'nih_pqc_ssh_roots\0')
start, stop = strtab[4], strtab[4] + strtab[5]
pos = elf.find(needle, start, stop)
assert pos >= 0
bad_name = elf.copy()
bad_name[pos] = ord('X')
try:
    mod.check_no_resident_copies(bad_name)
    raise AssertionError('renamed root was accepted')
except ValueError:
    pass
name = b'mlk_zetas\0'
namepos = elf.find(name, start, stop) - start
assert namepos >= 0
found = None
for off in range(strings[4], strings[4] + strings[5], strings[9]):
    n, value, size, _, _, index = struct.unpack_from('<IIIBBH', elf, off)
    if n == namepos:
        sec = sections[index]
        found = elf[sec[4] + value - sec[3]:sec[4] + value - sec[3] + size]
        break
assert found is not None and len(found) == 256
bad_copy = elf.copy()
bad_copy[resident[4]:resident[4] + len(found)] = found
try:
    mod.check_no_resident_copies(bad_copy)
    raise AssertionError('SRAM constant copy was accepted')
except ValueError:
    pass
print('PQC audit negative controls: missing root and SRAM constant copy rejected')

#!/usr/bin/env python3
"""Inject missing function and an exact SRAM code copy into an ELF."""
import importlib.util
import struct
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('audit_ssh', Path(__file__).with_name('audit_emulator_ssh.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
elf = bytearray(Path(sys.argv[1]).read_bytes())
mod.check_no_copy(elf)
h = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
s = [struct.unpack_from('<10I', elf, h[6] + i * h[11]) for i in range(h[12])]
symtab = next(x for x in s if x[1] == 2)
strtab = s[symtab[6]]
needle = b'ssh_host_key.verify\0'
pos = elf.find(needle, strtab[4], strtab[4] + strtab[5])
assert pos >= 0
nameoff = pos - strtab[4]
found = None
for off in range(symtab[4], symtab[4] + symtab[5], symtab[9]):
    n, value, size, _, _, idx = struct.unpack_from('<IIIBBH', elf, off)
    if n == nameoff:
        parent = s[idx]
        found = elf[parent[4] + value - parent[3]:parent[4] + value - parent[3] + size]
        break
assert found is not None and len(found) >= 32
resident = next(x for x in s if x[1] == 1 and x[2] & 2 and 0x4ff00000 <= x[3] < 0x50000000 and x[5] >= len(found))
for label, bad in [('renamed function', elf.copy()), ('SRAM copy', elf.copy())]:
    if label == 'renamed function': bad[pos] = ord('X')
    else: bad[resident[4]:resident[4] + len(found)] = found
    try:
        mod.check_no_copy(bad)
    except ValueError:
        continue
    raise AssertionError(label + ' accepted')
print('SSH emulator audit negative controls: missing function and SRAM copy rejected')
data_name = b'crypto.25519.edwards25519.Edwards25519.basePointPc\0'
data_pos = elf.find(data_name, strtab[4], strtab[4] + strtab[5])
assert data_pos >= 0
data_off = data_pos - strtab[4]
data_bytes = None
for off in range(symtab[4], symtab[4] + symtab[5], symtab[9]):
    n, value, size, _, _, idx = struct.unpack_from('<IIIBBH', elf, off)
    if n == data_off:
        parent = s[idx]
        data_bytes = elf[parent[4] + value - parent[3]:parent[4] + value - parent[3] + size]
        break
assert data_bytes is not None and len(data_bytes) == 0x0a80
resident = next(x for x in s if x[1] == 1 and x[2] & 2 and 0x4ff00000 <= x[3] < 0x50000000 and x[5] >= len(data_bytes))
bad = elf.copy()
bad[resident[4]:resident[4] + len(data_bytes)] = data_bytes
try:
    mod.check_no_copy(bad)
except ValueError:
    print('SSH emulator audit negative control: SRAM constant copy rejected')
else:
    raise AssertionError('SRAM constant copy accepted')

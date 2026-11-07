#!/usr/bin/env python3
"""Experimental exact-function audit; does not prove cache-off/IRQ safety."""
import importlib.util
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('native_audit', ROOT / 'tools/check-native-image.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
expected_list = json.loads((ROOT / 'probes/ssh-placement/expected-functions.json').read_text())
expected = set(expected_list)
native.require(len(expected) == len(expected_list) and expected, 'invalid study function list')
original_xy_function = native.xy_function
original_xy_audit = native.audit_xy_functions


def xy_function(name):
    return name in expected or original_xy_function(name)


def audit_xy_functions(functions, span):
    report = original_xy_audit(functions, span)
    for name in expected:
        matches = [(start, end) for candidate, start, end in functions if candidate == name]
        native.require(len(matches) == 1 and span[0] <= matches[0][0] < matches[0][1] <= span[1],
                       'study function missing, duplicated or outside Flash: ' + name)
    return report


def check_sram_copies(path):
    elf = Path(path).read_bytes()
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    sections = [struct.unpack_from('<10I', elf, header[6] + i*header[11]) for i in range(header[12])]
    resident = [elf[s[4]:s[4]+s[5]] for s in sections if s[1] != 8 and s[2] & 2 and 0x4ff00000 <= s[3] < 0x50000000]
    found = {}
    for sec in sections:
        if sec[1] != 2: continue
        st = sections[sec[6]]; names = elf[st[4]:st[4]+st[5]]
        for off in range(sec[4], sec[4]+sec[5], sec[9]):
            n, address, size, _, _, idx = struct.unpack_from('<IIIBBH', elf, off)
            end = names.find(b'\0', n)
            native.require(end >= 0, 'invalid ELF symbol name')
            name = names[n:end].decode('utf-8', 'replace')
            if name not in expected: continue
            native.require(name not in found and idx < len(sections), 'duplicate study function: ' + name)
            parent = sections[idx]; relative = address-parent[3]
            native.require(parent[1] != 8 and 0 <= relative and relative+size <= parent[5] and
                           0x40060000 <= address < address+size <= 0x400c0000, 'study code outside xy Flash: ' + name)
            code = elf[parent[4]+relative:parent[4]+relative+size]
            # Very short code sequences can match incidentally; those still
            # require unique symbol placement in audit_xy_functions above.
            if size >= 32:
                native.require(not any(code in block for block in resident), 'SRAM byte copy of study function: ' + name)
            found[name] = size
    native.require(set(found) == expected, 'study functions differ from exact list')
    return found


if __name__ == '__main__':
    native.require(len(sys.argv) >= 6 and sys.argv[4:6] == ['integer', 'device'], 'device integer study only')
    found = check_sram_copies(sys.argv[1])
    native.xy_function = xy_function
    native.audit_xy_functions = audit_xy_functions
    native.main()
    print('Study-only exact function audit passed:', len(found), 'functions;',
          sum(size >= 32 for size in found.values()), 'byte-copy checked; IRQ/cache-off safety unproven')

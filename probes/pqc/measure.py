#!/usr/bin/env python3
"""Compile isolated freestanding RV32 probes; report object sections and entry frames.

Entry frames are lower bounds, not call-chain maxima. These are unlinked objects.
"""
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ZIG = os.environ.get('ZIG', str(ROOT / '.tools/zig-0.17.0/zig'))
OUT = ROOT / 'build/pqc-resource'
OPS = ('verify', 'keygen', 'encaps', 'decaps')

def sections(path):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('expected little-endian ELF32')
    hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    shoff, entsize, count, strings = hdr[6], hdr[11], hdr[12], hdr[13]
    entries = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * entsize) for i in range(count)]
    table = entries[strings]
    names = data[table[4]:table[4]+table[5]]
    result = {'executable_bytes': 0, 'readonly_bytes': 0, 'writable_bytes': 0, 'nobits_bytes': 0}
    for entry in entries:
        _, typ, flags, _, _, length, _, _, _, _ = entry
        if not flags & 2:  # SHF_ALLOC
            continue
        if typ == 8:
            result['nobits_bytes'] += length
        elif flags & 4:
            result['executable_bytes'] += length
        elif flags & 1:
            result['writable_bytes'] += length
        else:
            result['readonly_bytes'] += length
    return result

def entry_frame(assembly, op):
    match = re.search(r'^' + re.escape(op + '.pqc_' + op) + r':\s*$', assembly, re.M)
    if not match:
        raise ValueError('entry function missing')
    body = assembly[match.end():]
    # Only the initial straight-line prologue up to the first branch/call or source marker.
    total = 0
    registers = {}
    found = False
    for line in body.splitlines():
        line = line.strip()
        if re.match(r'(call|tail|j|b\w+)\s', line):
            break
        m = re.fullmatch(r'lui\s+(\w+),\s*(-?\d+)', line)
        if m:
            registers[m[1]] = int(m[2]) * 4096
        m = re.fullmatch(r'addi\s+(\w+),\s*(\w+),\s*(-?\d+)', line)
        if m:
            dest, source, value = m[1], m[2], int(m[3])
            if dest == source == 'sp' and value < 0:
                total -= value
                found = True
            elif source in registers:
                registers[dest] = registers[source] + value
            elif dest != 'sp':
                registers.pop(dest, None)
        m = re.fullmatch(r'sub\s+sp,\s*sp,\s*(\w+)', line)
        if m:
            if m[1] not in registers:
                raise ValueError('unresolved stack adjustment')
            total += registers[m[1]]
            found = True
    if not found:
        raise ValueError('stack prologue not found')
    return total

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {'zig_version': subprocess.check_output([ZIG, 'version'], text=True).strip(),
              'target': 'riscv32-freestanding-none', 'cpu': 'generic_rv32+m+a+c+zicsr+zifencei',
              'optimization': 'ReleaseSafe', 'operations': {}}
    for op in OPS:
        obj, asm = OUT / (op + '.o'), OUT / (op + '.s')
        cmd = [ZIG, 'build-obj', str(ROOT / 'probes/pqc' / (op + '.zig')),
               '-target', report['target'], '-mcpu', report['cpu'], '-O', report['optimization'],
               '-femit-bin=' + str(obj), '-femit-asm=' + str(asm)]
        subprocess.run(cmd, check=True)
        report['operations'][op] = {'entry_frame_bytes': entry_frame(asm.read_text(), op), **sections(obj)}
    output = json.dumps(report, indent=2) + '\n'
    (OUT / 'report.json').write_text(output)
    print(output, end='')

if __name__ == '__main__':
    main()

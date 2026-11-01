#!/usr/bin/env python3
"""Audit an experimental mapped candidate without approving device execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys

if len(sys.argv) not in (6, 7):
    raise SystemExit('usage: ELF BIN C6_IMAGE SHA256 REPORT [update]')
elf_path, bin_path, candidate_path, expected, report_path = sys.argv[1:6]
mode = sys.argv[6] if len(sys.argv) == 7 else 'preflight'
if mode not in ('preflight', 'update'):
    raise SystemExit('unknown audit mode')
elf, image, candidate = (Path(p).read_bytes() for p in (elf_path, bin_path, candidate_path))
if hashlib.sha256(candidate).hexdigest() != expected:
    raise SystemExit('staged candidate differs from reviewed SHA-256')
if len(candidate) % 4:
    raise SystemExit('candidate length must be 4-byte aligned')
# ELF section names and data are independently checked before extending the
# existing audit's read-only metadata allowance to this exact image size.
header = struct.unpack_from('<HHIIIIIHHHHHH', elf, 16)
shoff, shsize, shnum, shstr = header[5], header[10], header[11], header[12]
sections = [struct.unpack_from('<10I', elf, shoff + i * shsize) for i in range(shnum)]
strings = sections[shstr]
names = elf[strings[4]:strings[4] + strings[5]]
matched = []
for sec in sections:
    name = names[sec[0]:names.index(0, sec[0])].decode('ascii')
    if name == '.flash.rodata':
        matched.append(sec)
if len(matched) != 1:
    raise SystemExit('missing or duplicate mapped section')
if mode == 'update':
    symbols = {}
    for table in sections:
        if table[1] != 2:  # SHT_SYMTAB
            continue
        string_table = sections[table[6]]
        symbol_names = elf[string_table[4]:string_table[4] + string_table[5]]
        for pos in range(table[4], table[4] + table[5], table[9]):
            name_at, value, _, _, _, _ = struct.unpack_from('<IIIBBH', elf, pos)
            if name_at:
                name = symbol_names[name_at:symbol_names.index(0, name_at)].decode('ascii')
                symbols[name] = value
    sizes = {'stack0': 8192, 'irq_stack0': 8192, 'stack1': 1024, 'irq_stack1': 1024}
    for name, expected_size in sizes.items():
        bottom, top = symbols.get('__' + name + '_bottom'), symbols.get('__' + name + '_top')
        if bottom is None or top is None or top - bottom != expected_size:
            raise SystemExit('OTA update fixture stack layout mismatch: ' + name)
sec = matched[0]
expected_bytes = struct.pack('<I', 0x4e494853) + candidate
if sec[3] != 0x40010020 or sec[5] != len(expected_bytes) or elf[sec[4]:sec[4] + sec[5]] != expected_bytes:
    raise SystemExit('mapped ELF candidate mismatch')
# Check mapped image segment bytes as well as the ELF bytes.
pos, found = 24, 0
for _ in range(image[1]):
    addr, length = struct.unpack_from('<II', image, pos)
    pos += 8
    if addr == 0x40010020:
        if image[pos:pos + length] != expected_bytes:
            raise SystemExit('mapped flash image does not contain the exact candidate')
        found += 1
    pos += length
if found != 1:
    raise SystemExit('expected exactly one mapped candidate segment')
module_path = Path(__file__).with_name('check-c6-sram-boundary.py')
spec = importlib.util.spec_from_file_location('c6_boundary', module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.FLASH_SECTIONS = {'.flash.appdesc': (0x40000020, 256), '.flash.rodata': (0x40010020, len(expected_bytes))}
required = ('nih_c6_main', 'nih_c6_exception', 'nih_c6_reset', 'nih_c6_pads_init', 'nih_c6_fourbit_pins', 'nih_c6_power_enable', 'c6_probe.exerciseOtaPreflight')
if mode == 'update':
    required += ('c6_probe.exerciseOtaUpdate', 'nih_c6_serial_read')
report = module.audit(elf, image, 'integer', required_functions=required)
report.update(scope='mapped OTA ' + mode + ' build-only; no device operation', candidate_sha256=expected, candidate_bytes=len(candidate), candidate_virtual_address=hex(0x40010024), execution_qualified=False)
Path(report_path).write_text(json.dumps(report, indent=2) + '\n')
print('C6 OTA mapped image audit passed; execution unqualified')

#!/usr/bin/env python3
"""Pinned experimental TCP + KEM + receive-code placement audit; never runtime proof."""
import hashlib
import importlib.util
import json
import os
import struct
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
os.environ['NIHOS_PQC_JOB_AUDIT'] = '1'
spec = importlib.util.spec_from_file_location('pqc_fixture', ROOT / 'probes/pqc-ssh/audit_flash_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
audit = fixture.audit
manifest = json.loads((ROOT / 'probes/pqc-ssh/device-stream-witness.json').read_text())
obj = ROOT / 'build/pqc-ssh-stream-rv32/stream-full.o'
audit.require(hashlib.sha256(obj.read_bytes()).hexdigest() == manifest['object_sha256'], 'stream witness object differs')
expected = manifest['functions']
original_predicate = audit.xy_function

def approved(name):
    return name in expected or original_predicate(name)
audit.xy_function = approved

def audit_fixture(functions, span):
    selected = [(name, start, end) for name, start, end in functions if span[0] <= start < span[1]]
    for name, size in expected.items():
        found = {(start, end) for candidate, start, end in selected if candidate == name}
        audit.require(len(found) == 1 and next(iter(found))[1] - next(iter(found))[0] == size, 'stream function differs: ' + name)
    last = max(end for _, _, end in selected)
    # The witness constant table requires 64-byte section alignment; constrain
    # the tail and let the unchanged auditor check all other code coverage.
    audit.require(0 <= span[1] - last <= 63, 'excess xy alignment tail')
    hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', current_elf)
    sections = [struct.unpack_from('<10I', current_elf, hdr[6] + i * hdr[11]) for i in range(hdr[12])]
    matches = [s for s in sections if s[3] <= last and span[1] <= s[3] + s[5] and s[2] & 4]
    audit.require(len(matches) == 1, 'xy tail section missing')
    sec = matches[0]
    audit.require(not any(current_elf[sec[4] + last - sec[3]:sec[4] + span[1] - sec[3]]), 'nonzero xy alignment tail')
    return fixture.check_fixture(functions, (span[0], min(span[1], last + 16)))
audit.audit_xy_functions = audit_fixture

def sram_sections(elf):
    h = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    sections = [struct.unpack_from('<10I', elf, h[6] + i * h[11]) for i in range(h[12])]
    return [elf[s[4]:s[4]+s[5]] for s in sections if s[1] != 8 and s[2] & 2 and 0x4ff00000 <= s[3] < 0x50000000]

def occurrences(sections, pattern):
    return sum(sum(1 for i in range(len(data) - len(pattern) + 1) if data[i:i+len(pattern)] == pattern) for data in sections)

def check_stream_bytes(elf):
    hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    sections = [struct.unpack_from('<10I', elf, hdr[6] + i * hdr[11]) for i in range(hdr[12])]
    resident = sram_sections(elf)
    baseline = (ROOT / 'build/pqc-device-stream-baseline/nihos-native.elf').read_bytes()
    audit.require(hashlib.sha256(baseline).hexdigest() == manifest['baseline_elf_sha256'], 'baseline differs')
    before = sram_sections(baseline)
    wanted = {**expected, **manifest['constants']}
    found = {}
    for sec in sections:
        if sec[1] != 2: continue
        strings = sections[sec[6]]
        names = elf[strings[4]:strings[4]+strings[5]]
        for off in range(sec[4], sec[4]+sec[5], sec[9]):
            n, value, size, info, _, idx = struct.unpack_from('<IIIBBH', elf, off)
            end = names.find(b'\0', n)
            audit.require(end >= 0, 'invalid symbol')
            name = names[n:end].decode('ascii')
            if name not in wanted or not (0x40060000 <= value < 0x40400000): continue
            audit.require(name not in found and idx < len(sections) and size == wanted[name], 'stream symbol differs: ' + name)
            parent = sections[idx]
            offset = value - parent[3]
            audit.require(0 <= offset and offset + size <= parent[5], 'stream symbol outside section')
            if size >= 64:
                pattern = elf[parent[4]+offset:parent[4]+offset+size]
                audit.require(occurrences(resident, pattern) <= occurrences(before, pattern), 'new stream byte copy in SRAM: ' + name)
            found[name] = size
    audit.require(set(found) == set(wanted), 'missing stream symbol')

if __name__ == '__main__':
    if len(sys.argv) < 6 or sys.argv[4:6] != ['integer', 'device']:
        raise SystemExit('study restricted to integer device profile')
    current_elf = Path(sys.argv[1]).read_bytes()
    raw = current_elf
    fixture.check_no_resident_copies(raw)
    check_stream_bytes(raw)
    audit.main()

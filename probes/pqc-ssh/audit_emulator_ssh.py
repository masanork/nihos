#!/usr/bin/env python3
"""Bounded audit for emulator-only SSH fixture; does not prove cache-off safety."""
import importlib.util
import os
import struct
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('nihos_image_audit', ROOT / 'tools/check-native-image.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
SHA512 = 'crypto.sha2.Sha2x64(.{ 7640891576956012808, 13503953896175478587, 4354685564936845355, 11912009170470909681, 5840696475078001361, 11170449401992604703, 2270897969802886507, 6620516959819538809 },512).round'
SHA256 = 'crypto.sha2.Sha2x32(.{ 1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225 },256).round'
EXTRA = {'ssh_host_key.verify', SHA512, SHA256, 'ssh_hybrid_driver.Driver.abort'}
for suffix in ('prepare', 'submit', 'complete', 'reclaim'):
    if suffix == 'submit' and os.environ.get('NIHOS_NATIVE_PQC_SSH_NEGATIVE') == '3': continue
    EXTRA.add('nih_ssh_driver_fixture_' + suffix)
    EXTRA.add('ssh_hybrid_fixture.nih_ssh_driver_fixture_' + suffix)
DATA = {'__anon_13617': 0x0a47, 'crypto.25519.edwards25519.Edwards25519.basePointPc': 0x0a80}
original = audit.audit_pmp_flash

def check_functions(functions, span):
    for name in EXTRA:
        matches = [(a, b) for n, a, b in functions if n == name]
        audit.require(len(matches) == 1 and span[0] <= matches[0][0] < matches[0][1] <= span[1],
                      'SSH fixture function missing, duplicated or outside mapped Flash: ' + name)
    return original(functions, span)

def check_no_copy(elf):
    hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', elf)
    sections = [struct.unpack_from('<10I', elf, hdr[6] + i * hdr[11]) for i in range(hdr[12])]
    resident = [elf[s[4]:s[4] + s[5]] for s in sections if s[1] != 8 and s[2] & 2 and 0x4ff00000 <= s[3] < 0x50000000]
    found = {}
    for sec in sections:
        if sec[1] != 2: continue
        strings = sections[sec[6]]
        names = elf[strings[4]:strings[4] + strings[5]]
        for off in range(sec[4], sec[4] + sec[5], sec[9]):
            n, value, size, _, _, idx = struct.unpack_from('<IIIBBH', elf, off)
            end = names.find(b'\0', n)
            audit.require(end >= 0, 'invalid symbol name')
            name = names[n:end].decode('ascii')
            if name not in EXTRA: continue
            audit.require(name not in found and idx < len(sections), 'duplicate fixture symbol')
            parent = sections[idx]
            offset = value - parent[3]
            audit.require(0 <= offset and offset + size <= parent[5] and 0x40000120 <= value < 0x40010000 and size >= 32,
                          'fixture function outside mapped Flash')
            pattern = elf[parent[4] + offset:parent[4] + offset + size]
            audit.require(not any(pattern in data for data in resident), 'SSH fixture function copied to SRAM: ' + name)
            found[name] = size
    audit.require(set(found) == EXTRA, 'SSH fixture functions missing')
    data_found = {}
    for sec in sections:
        if sec[1] != 2: continue
        strings = sections[sec[6]]
        names = elf[strings[4]:strings[4] + strings[5]]
        for off in range(sec[4], sec[4] + sec[5], sec[9]):
            n, value, size, _, _, idx = struct.unpack_from('<IIIBBH', elf, off)
            end = names.find(b'\0', n)
            audit.require(end >= 0, 'invalid symbol name')
            name = names[n:end].decode('ascii')
            if name not in DATA: continue
            audit.require(name not in data_found and idx < len(sections) and size == DATA[name], 'fixture data differs')
            parent = sections[idx]
            offset = value - parent[3]
            audit.require(0 <= offset and offset + size <= parent[5] and 0x40010000 <= value < 0x40020000, 'fixture data outside mapped Flash')
            pattern = elf[parent[4] + offset:parent[4] + offset + size]
            audit.require(not any(pattern in data for data in resident), 'SSH fixture data copied to SRAM: ' + name)
            data_found[name] = size
    audit.require(data_found == DATA, 'SSH fixture data missing')

if __name__ == '__main__':
    if len(sys.argv) < 6 or sys.argv[4:6] != ['integer', 'emulator']:
        raise SystemExit('SSH fixture audit is restricted to the emulator integer profile')
    check_no_copy(Path(sys.argv[1]).read_bytes())
    audit.PMP_FLASH_FUNCTIONS |= EXTRA
    audit.audit_pmp_flash = check_functions
    audit.main()

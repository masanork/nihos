#!/usr/bin/env python3
"""Mutation checks against the already-built device placement witness."""
import importlib.util
import struct
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('device_stream_audit', ROOT / 'probes/pqc-ssh/audit_device_stream.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)

def sections(data):
    h = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    return [struct.unpack_from('<10I', data, h[6] + i * h[11]) for i in range(h[12])]

def symbol_bytes(data, name):
    ss = sections(data)
    for t in ss:
        if t[1] != 2: continue
        st = ss[t[6]]
        names = data[st[4]:st[4]+st[5]]
        for off in range(t[4], t[4] + t[5], t[9]):
            n, addr, size, _, _, idx = struct.unpack_from('<IIIBBH', data, off)
            end = names.find(b'\0', n)
            if names[n:end].decode('ascii') != name or not 0x40060000 <= addr < 0x40400000: continue
            sec = ss[idx]
            return data[sec[4]+addr-sec[3]:sec[4]+addr-sec[3]+size]
    raise AssertionError('symbol missing: ' + name)

def inject(data, pattern):
    for sec in sections(data):
        if sec[1] != 8 and sec[2] & 2 and 0x4ff00000 <= sec[3] < 0x50000000 and sec[5] >= len(pattern):
            data[sec[4]:sec[4]+len(pattern)] = pattern
            return
    raise AssertionError('resident section missing')

class TestPlacementAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = (ROOT / 'build/pqc-device-stream-final/nihos-native.elf').read_bytes()

    def test_expected_candidate(self):
        a.fixture.check_no_resident_copies(self.original)
        a.check_stream_bytes(self.original)

    def test_stream_sram_copy_is_rejected(self):
        changed = bytearray(self.original)
        inject(changed, symbol_bytes(changed, 'nih_stream_feed'))
        with self.assertRaisesRegex(ValueError, 'new stream byte copy'):
            a.check_stream_bytes(changed)

    def test_kem_sram_copy_is_rejected(self):
        changed = bytearray(self.original)
        inject(changed, symbol_bytes(changed, 'nih_kem_decaps'))
        with self.assertRaisesRegex(ValueError, 'copied to SRAM'):
            a.fixture.check_no_resident_copies(changed)

    def test_missing_stream_symbol_is_rejected(self):
        changed = bytearray(self.original)
        ss = sections(changed)
        symtab = next(sec for sec in ss if sec[1] == 2)
        strings = ss[symtab[6]]
        start, end = strings[4], strings[4] + strings[5]
        old = b'\0nih_stream_feed\0'
        pos = changed.find(old, start, end)
        self.assertGreater(pos, start)
        changed[pos + 1] ^= 1
        with self.assertRaises(ValueError):
            a.check_stream_bytes(changed)

if __name__ == '__main__':
    unittest.main()

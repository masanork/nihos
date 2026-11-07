import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('table_audit', Path(__file__).with_name('audit-ssh-ed25519-table.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
TABLE = bytes(range(256)) * 10 + bytes(range(128))
audit.SHA256 = hashlib.sha256(TABLE).hexdigest()


def fixture(regions):
    """Minimal ELF32 with one table symbol and requested allocated copies."""
    sections = [bytes(40)]
    body = bytearray(bytes(52))
    for address, writable in regions:
        offset = len(body)
        body.extend(TABLE)
        sections.append(struct.pack('<10I', 0, 1, 3 if writable else 2, address, offset, len(TABLE), 0, 0, 1, 0))
    strings = b'\0table\0'
    string_offset = len(body)
    body.extend(strings)
    string_index = len(sections)
    sections.append(struct.pack('<10I', 0, 3, 0, 0, string_offset, len(strings), 0, 0, 1, 0))
    symbol_offset = len(body)
    symbols = bytes(16)
    if regions:
        symbols += struct.pack('<IIIBBH', 1, regions[0][0], len(TABLE), 1, 0, 1)
    body.extend(symbols)
    sections.append(struct.pack('<10I', 0, 2, 0, 0, symbol_offset, len(symbols), string_index, 1, 4, 16))
    offset = len(body)
    body.extend(b''.join(sections))
    struct.pack_into('<16sHHIIIIIHHHHHH', body, 0, b'\x7fELF\x01\x01\x01' + bytes(9), 2, 243, 1, 0, 0, offset, 0, 52, 0, 0, 40, len(sections), 0)
    return body


class TableAuditTest(unittest.TestCase):
    def inspect(self, regions):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.elf'
            path.write_bytes(fixture(regions))
            return audit.inspect(path)

    def test_missing_and_single_regions(self):
        self.assertEqual([], self.inspect([])['copies'])
        result = self.inspect([(0x40011000, False)])
        self.assertEqual([{'address': '0x40011000', 'writable': False, 'region': 'mapped_flash'}], result['copies'])
        self.assertEqual('sram', self.inspect([(0x4ff01000, False)])['copies'][0]['region'])

    def test_detects_unsymbolized_sram_duplicate(self):
        result = self.inspect([(0x40011000, False), (0x4ff01000, True)])
        self.assertEqual(['mapped_flash', 'sram'], [copy['region'] for copy in result['copies']])
        self.assertEqual(1, len(result['symbols']))


if __name__ == '__main__':
    unittest.main()

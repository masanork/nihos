"""Fail-before-write tests for the standalone pristine library image contract."""
from dataclasses import replace
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

sys.dont_write_bytecode = True
path = Path(__file__).resolve().parents[1] / 'probes/graphics/library_image.py'
spec = importlib.util.spec_from_file_location('pristine_library_image', path)
IMAGE = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = IMAGE
spec.loader.exec_module(IMAGE)


def fixture(rogue=False, bad_bank=False, bad_backing=False, omit_load=False):
    records = [('', 0, 0, 0, b'', 0), ('.text', 1, 6, 0x41000000, b'\x13\0\0\0', 4),
               ('.library.data', 1, 3, 0x51000000, b'\x23\x91\x56\x17', 4),
               ('.library.bss', 8, 3, 0x51008000 if bad_bank else 0x51000040, b'', 4),
               ('.backing.data', 1, 3, 0x51008000, b'KERN', 4),
               ('.backing.bss', 8, 3, 0x51000080 if bad_backing else 0x51008040, b'', 4)]
    if rogue:records.append(('.rogue', 1, 3, 0x51000100, b'bad!', 4))
    records.append(('.shstrtab', 3, 0, 0, b'', 0))
    names = b'\0'; offsets = {'': 0}
    for name, *_ in records[1:]:
        offsets[name] = len(names); names += name.encode()+b'\0'
    records[-1] = ('.shstrtab', 3, 0, 0, names, len(names))
    blob = bytearray(52+3*32); sections = []; file_offsets = {}
    for name, kind, flags, address, data, size in records:
        at = len(blob); blob.extend(data); file_offsets[name] = at
        sections.append((offsets[name], kind, flags, address, at, size, 0, 0, 1, 0))
    shoff = len(blob)
    for section in sections:blob.extend(struct.pack('<10I', *section))
    ident = b'\x7fELF\x01\x01\x01'+b'\0'*9
    struct.pack_into('<16sHHIIIIIHHHHHH', blob, 0, ident, 2, 243, 1, 0x41000000, 52, shoff, 0, 52, 32, 3, 40, len(sections), len(sections)-1)
    for index, (name, address, size, flags) in enumerate((('.text', 0x41000000, 4, 5), ('.library.data', 0x51000000, 68, 6), ('.backing.data', 0x51008000, 68, 6))):
        struct.pack_into('<8I', blob, 52+index*32, 0 if omit_load and index == 1 else 1, file_offsets[name], address, address, 4, size, flags, 4)
    return bytes(blob)


class LibraryImageTests(unittest.TestCase):
    def test_full_initializer_and_zero_bss_exclude_kernel_backing(self):
        image = IMAGE.Image(fixture())
        writes = []
        image.template.restore(lambda at, data: writes.append((at, data)), image.sha256, True)
        self.assertEqual(writes[0][0], 0x51000000)
        self.assertEqual(len(writes[0][1]), 32768)
        self.assertEqual(writes[0][1][:4], b'\x23\x91\x56\x17')
        self.assertEqual(writes[0][1][4:], bytes(32764))
        self.assertNotIn(b'KERN', writes[0][1])

    def test_wrong_elf_refuses_before_any_write(self):
        image = IMAGE.Image(fixture()); writes = []
        with self.assertRaisesRegex(ValueError, 'identity'):
            image.template.restore(lambda *args: writes.append(args), 'wrong', True)
        self.assertEqual(writes, [])

    def test_live_library_refuses_before_any_write(self):
        image = IMAGE.Image(fixture()); writes = []
        with self.assertRaisesRegex(ValueError, 'live'):
            image.template.restore(lambda *args: writes.append(args), image.sha256, False)
        self.assertEqual(writes, [])

    def test_corrupt_template_refuses_before_any_write(self):
        image = IMAGE.Image(fixture()); writes = []
        bad = replace(image.template, data=b'\xff'+image.template.data[1:])
        with self.assertRaisesRegex(ValueError, 'corrupt'):
            bad.restore(lambda *args: writes.append(args), image.sha256, True)
        self.assertEqual(writes, [])

    def test_mutable_sections_require_bank_isolation_and_load_coverage(self):
        for options in ({'rogue': True}, {'bad_bank': True}, {'bad_backing': True}, {'omit_load': True}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                IMAGE.Image(fixture(**options))

    def test_truncated_elf_is_rejected(self):
        with self.assertRaises(ValueError):IMAGE.Image(fixture()[:-1])

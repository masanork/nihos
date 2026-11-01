#!/usr/bin/env python3
"""Mutation checks against a real linked fixture: python test.py ELF."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("check-hosted-long-link.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ELF = Path(sys.argv.pop(1)).read_bytes()


def symbol_offset(name):
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", ELF)
    sections = [struct.unpack_from("<10I", ELF, header[6] + i * 40) for i in range(header[12])]
    for section in sections:
        if section[1] != 2:
            continue
        strings_section = sections[section[6]]
        strings = ELF[strings_section[4]:strings_section[4] + strings_section[5]]
        for offset in range(section[4], section[4] + section[5], 16):
            name_index = struct.unpack_from("<I", ELF, offset)[0]
            if strings[name_index:].split(b"\0", 1)[0].decode() == name:
                return offset, sections
    raise AssertionError(name)


class AuditTest(unittest.TestCase):
    def check(self, data, error=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidate.elf"
            path.write_bytes(data)
            if error:
                with self.assertRaisesRegex(ValueError, error):
                    module.audit(path)
            else:
                module.audit(path)

    def test_valid_link(self):
        self.check(ELF)

    def test_wrong_rom_address(self):
        data = bytearray(ELF)
        offset, _ = symbol_offset("nih_rom_cache_writeback")
        struct.pack_into("<I", data, offset + 4, 0x4FC003F8)
        self.check(data, "unexpected absolute symbol")

    def test_unresolved_rom(self):
        data = bytearray(ELF)
        offset, _ = symbol_offset("nih_rom_cache_invalidate")
        struct.pack_into("<H", data, offset + 14, 0)
        self.check(data, "unresolved symbol")

    def test_bad_descriptor_placement(self):
        data = bytearray(ELF)
        offset, sections = symbol_offset("nih_hosted_long_dma_layout")
        _, address, _, _, _, index = struct.unpack_from("<IIIBBH", ELF, offset)
        section = sections[index]
        manifest = section[4] + address - section[3]
        struct.pack_into("<I", data, manifest + 8, 0x48000001)
        self.check(data, "unaligned/overlapping DMA storage")


if __name__ == "__main__":
    unittest.main()

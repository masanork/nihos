"""Instruction-boundary checks for the restricted RV32IMAF/C native audit."""
import importlib.util
from pathlib import Path
import unittest
import struct

SPEC = importlib.util.spec_from_file_location("native_image", Path(__file__).with_name("check-native-image.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeInstructionTests(unittest.TestCase):
    def test_descriptor_must_select_the_audited_mmu_page_size(self):
        data = bytearray(256)
        struct.pack_into("<I", data, 0, 0xABCD5432)
        data[180] = 16
        MODULE.audit_app_descriptor(data)
        for changed in (data[:255], b"bad!" + data[4:], data[:180] + b"\x0f" + data[181:]):
            with self.assertRaises(ValueError):
                MODULE.audit_app_descriptor(changed)

    def test_flash_tables_are_bounded_read_only_progbits(self):
        MODULE.audit_flash_section(".flash.appdesc", 1, 2, 0x40000020, 256)
        for size in (1, 1986, 65504):
            MODULE.audit_flash_section(".flash.rodata", 1, 2, 0x40010020, size)
        for kind, flags, address, size in ((8, 2, 0x40010020, 64), (1, 3, 0x40010020, 64),
                                            (1, 6, 0x40010020, 64), (1, 2, 0x40010024, 64),
                                            (1, 2, 0x40010020, 0), (1, 2, 0x40010020, 65505)):
            with self.subTest(kind=kind, flags=flags, size=size), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.rodata", kind, flags, address, size)
        with self.assertRaises(ValueError):
            MODULE.audit_flash_section(".flash.text", 1, 2, 0x40010020, 64)

    def test_flash_checksum_uses_known_fnv1a_vectors(self):
        for data, checksum in ((b"", 0x811c9dc5), (b"a", 0xe40c292c), (b"foobar", 0xbf9cf968)):
            with self.subTest(data=data):
                self.assertEqual(MODULE.fnv1a(data), checksum)

    def test_heap_is_the_unloaded_tail_after_stacks(self):
        for low, high, _ in MODULE.SRAM_PROFILES.values():
            start = high - 65536
            symbols = {"__irq_stack1_top": start - 16, "__heap_start": start, "__heap_end": high}
            sections = [{"name": ".stacks", "address": hex(start - 32768 - 16), "bytes": 32768},
                        {"name": ".heap", "address": hex(start), "bytes": 65536}]
            self.assertEqual(MODULE.audit_heap_layout(symbols, sections, low, high)["bytes"], 65536)
            for field, value in (("__heap_start", start - 4096), ("__heap_start", start + 1),
                                 ("__heap_end", 0x48020000), ("__heap_start", high - 4096)):
                with self.subTest(field=field, value=hex(value)), self.assertRaises(ValueError):
                    MODULE.audit_heap_layout({**symbols, field: value}, sections, low, high)
            with self.assertRaisesRegex(ValueError, "overlaps"):
                MODULE.audit_heap_layout(symbols, sections + [{"name": ".bad", "address": hex(start), "bytes": 64}], low, high)
            with self.assertRaisesRegex(ValueError, "differs"):
                MODULE.audit_heap_layout(symbols, sections[:1], low, high)

    def test_loader_allocations_are_audited_including_unloaded_bss(self):
        report = {"memory": {"origin": "0x4ff00000", "end": "0x4ff28000"}}
        elf = loader_elf([(1, 2, 0x4ff2abd0, 8192), (8, 2, 0x4ff33bd0, 256), (1, 0, 0x4ff10000, 64)])
        result = MODULE.audit_loader(report, elf)
        self.assertEqual(result["gap_bytes"], 0x2bd0)
        self.assertEqual(len(result["allocated"]), 2)

    def test_loader_overlap_at_either_edge_or_nobits_is_rejected(self):
        report = {"memory": {"origin": "0x4ff20000", "end": "0x4ff48000"}}
        for kind in (1, 8):
            for address in (0x4ff1fffc, 0x4ff47ffc, 0x4ff30000):
                with self.subTest(kind=kind, address=address), self.assertRaisesRegex(ValueError, "overlaps"):
                    MODULE.audit_loader(report, loader_elf([(kind, 2, address, 64)]))

    def test_loader_requires_expected_elf_and_a_higher_live_allocation(self):
        report = {"memory": {"origin": "0x4ff00000", "end": "0x4ff28000"}}
        with self.assertRaisesRegex(ValueError, "ELF32"):
            MODULE.audit_loader(report, b"invalid")
        with self.assertRaisesRegex(ValueError, "missing live"):
            MODULE.audit_loader(report, loader_elf([(1, 0, 0x4ff30000, 64)]))

    def test_loader_cache_and_revision_must_match_the_native_contract(self):
        common = "#define CONFIG_CACHE_L2_CACHE_SIZE 0x20000\n#define CONFIG_CACHE_L2_CACHE_LINE_SIZE 64\n"
        device = common + "#define CONFIG_ESP32P4_SELECTS_REV_LESS_V3 1\n"
        self.assertEqual(MODULE.audit_loader_config(common, "emulator")["l2_bytes"], 0x20000)
        self.assertEqual(MODULE.audit_loader_config(device, "device")["line_bytes"], 64)
        for config, profile in ((common.replace("0x20000", "0x40000"), "emulator"),
                                (common.replace("SIZE 64", "SIZE 128"), "emulator"),
                                (device, "emulator"), (common, "device")):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                MODULE.audit_loader_config(config, profile)

    def test_fp_load_store_arithmetic_and_fma(self):
        for instruction in (0x00052507, 0x00a52027, 0x00b57553, 0x00000043):
            with self.subTest(instruction=hex(instruction)):
                self.assertTrue(MODULE.is_fp_instruction(instruction, 4))

    def test_only_fp_status_csrs_are_classified(self):
        self.assertTrue(MODULE.is_fp_instruction(0x00302573, 4))  # frcsr
        self.assertTrue(MODULE.is_fp_instruction(0x00101073, 4))  # fsflags
        self.assertFalse(MODULE.is_fp_instruction(0x30002573, 4))  # mstatus
        self.assertFalse(MODULE.is_fp_instruction(0x10500073, 4))  # wfi

    def test_rv32_compressed_fp_is_not_integer_stack_access(self):
        for instruction in (0x6000, 0x6002, 0xe000, 0xe002):
            self.assertTrue(MODULE.is_fp_instruction(instruction, 2))
        for instruction in (0x4000, 0x4002, 0xc000, 0xc002, 0x0001):
            self.assertFalse(MODULE.is_fp_instruction(instruction, 2))


def loader_elf(sections):
    elf = bytearray(52 + 40 * len(sections))
    elf[:7] = b"\x7fELF\x01\x01\x01"
    struct.pack_into("<HHIIIIIHHHHHH", elf, 16, 2, 243, 1, 0, 0, 52, 0, 52, 0, 0, 40, len(sections), 0)
    for index, (kind, flags, address, size) in enumerate(sections):
        struct.pack_into("<10I", elf, 52 + index * 40, 0, kind, flags, address, 0, size, 0, 0, 4, 0)
    return bytes(elf)


if __name__ == "__main__":
    unittest.main()

"""Instruction-boundary checks for the restricted RV32IMAF/C native audit."""
import importlib.util
from pathlib import Path
import unittest
import struct

SPEC = importlib.util.spec_from_file_location("native_image", Path(__file__).with_name("check-native-image.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeInstructionTests(unittest.TestCase):
    def test_stack_symbols_array_and_section_have_exact_reservations(self):
        base = 0x4ff60000
        symbols = {"__stacks_start": base, "__stacks_end": base + 57344,
                   "__task_stacks_start": base + 32768, "__task_stacks_end": base + 57344,
                   "native_tasks.stacks": base + 32768}
        for prefix, offset in (("stack0", 0), ("stack1", 8192), ("irq_stack0", 16384), ("irq_stack1", 24576)):
            symbols["__" + prefix + "_bottom"] = base + offset
            symbols["__" + prefix + "_top"] = base + offset + 8192
        sizes = {"native_tasks.stacks": 24576}
        sections = [{"name": ".stacks", "address": hex(base), "bytes": 57344}]
        self.assertEqual(MODULE.audit_stack_layout(symbols, sizes, sections)["bytes"], 57344)
        for name in symbols:
            with self.subTest(symbol=name), self.assertRaisesRegex(ValueError, "stack"):
                MODULE.audit_stack_layout({**symbols, name: symbols[name] + 16}, sizes, sections)
        with self.assertRaisesRegex(ValueError, "array"):
            MODULE.audit_stack_layout(symbols, {"native_tasks.stacks": 16384}, sections)
        for bad in ([], sections + sections, [{**sections[0], "bytes": 57328}]):
            with self.assertRaisesRegex(ValueError, "stack"):
                MODULE.audit_stack_layout(symbols, sizes, bad)

    def test_stack_bank_is_non_executable_unloaded_and_bounded(self):
        MODULE.audit_stack_section(8, 3, 0x4ff60000, 57344)
        for values in ((1, 3, 0x4ff60000, 57344), (8, 7, 0x4ff60000, 57344),
                       (8, 2, 0x4ff60000, 57344), (8, 3, 0x4ff60010, 57344), (8, 3, 0x4ff60000, 32768)):
            with self.subTest(values=values), self.assertRaisesRegex(ValueError, "stack"):
                MODULE.audit_stack_section(*values)

    def test_loader_audits_both_regions_while_allowing_the_reserved_hole(self):
        report = {"memory": {"origin": "0x4ff00000", "end": "0x4ff28000", "regions": [
            {"name": "resident", "origin": "0x4ff00000", "end": "0x4ff28000"},
            {"name": "stacks", "origin": "0x4ff60000", "end": "0x4ff6e000"}]}}
        result = MODULE.audit_loader(report, loader_elf([(1, 2, 0x4ff2abd0, 8192)]))
        self.assertEqual([gap["name"] for gap in result["regions_checked"]], ["resident", "stacks"])
        self.assertIsNone(result["regions_checked"][1]["gap_above"])
        self.assertGreater(result["regions_checked"][1]["gap_below"], 0)

    def test_loader_collisions_with_stack_bank_include_both_edges_and_nobits(self):
        report = {"memory": {"origin": "0x4ff20000", "end": "0x4ff48000", "regions": [
            {"name": "resident", "origin": "0x4ff20000", "end": "0x4ff48000"},
            {"name": "stacks", "origin": "0x4ff60000", "end": "0x4ff6e000"}]}}
        for kind in (1, 8):
            for address in (0x4ff5fffc, 0x4ff68000, 0x4ff6dffc):
                with self.subTest(kind=kind, address=hex(address)), self.assertRaisesRegex(ValueError, "stacks"):
                    MODULE.audit_loader(report, loader_elf([(1, 2, 0x4ffac2c0, 64), (kind, 2, address, 16)]))

    def test_flash_boot_code_requires_execute_read_permissions_and_one_page(self):
        MODULE.audit_flash_section(".flash.boot", 1, 6, 0x40000120, 65248)
        for kind, flags, address, size in ((8, 6, 0x40000120, 64), (1, 2, 0x40000120, 64),
                                            (1, 7, 0x40000120, 64), (1, 6, 0x40000124, 64),
                                            (1, 6, 0x40000120, 0), (1, 6, 0x40000120, 65249)):
            with self.subTest(kind=kind, flags=flags, size=size), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.boot", kind, flags, address, size)

    def test_only_two_named_boot_functions_may_leave_sram(self):
        functions = [("resident", 0x4ff20000, 0x4ff20100), ("nih_rom_putc", 0x4fc00054, 0x4fc00058),
                     ("psram.probe", 0x40000120, 0x40000920),
                     ("psram_memory.prepare__func_43", 0x40000920, 0x40001120)]
        def check(values):
            return MODULE.audit_boot_functions(values, 0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000)
        self.assertEqual(set(check(functions)), {"probe", "mapping"})
        cases = [functions[:3], functions + [("unexpected", 0x40000140, 0x40000180)],
                 functions + [("psram_memory.prepare__func_44", 0x40000920, 0x40001120)],
                 functions[:2] + [("psram.probe", 0x40000120, 0x40000922), functions[3]],
                 functions[:2] + [("psram.probe", 0x40000122, 0x40000920), functions[3]],
                 functions[:2] + [("psram.probe", 0x40000120, 0x40010002), functions[3]],
                 functions + [("oversized_resident", 0x4ff47ffe, 0x4ff48002)]]
        for values in cases:
            with self.subTest(functions=values), self.assertRaises(ValueError):
                check(values)

    def test_sd_boot_move_requires_one_exact_named_extent_and_no_hidden_code(self):
        base = [("psram.probe", 0x40000120, 0x40000920),
                ("psram_memory.prepare__func_43", 0x40000920, 0x40001120)]
        moved = ("sdmmc_probe.run", 0x40001120, 0x40003920)
        def check(functions, span=(0x40001120, 0x40003920)):
            return MODULE.audit_boot_functions(functions, 0x40000120, 0x40003920,
                                                0x4ff20000, 0x4ff48000, sdmmc_span=span)
        self.assertEqual(check(base + [moved])["sdmmc"]["start"], "0x40001120")
        for values, span in [(base + [moved], None), (base, (0x40001120, 0x40003920)),
                             (base + [moved], (0x40001122, 0x40003920)),
                             (base + [moved, ("hidden_irq", 0x40001130, 0x40001140)], (0x40001120, 0x40003920)),
                             (base + [moved, moved], (0x40001120, 0x40003920)),
                             (base + [("sdmmc_probe.run", 0x40001140, 0x40003920)], (0x40001140, 0x40003920))]:
            with self.subTest(functions=values, span=span), self.assertRaises(ValueError):
                check(values, span)

    def test_sd_runtime_callbacks_and_dma_buffers_remain_internal_and_aligned(self):
        low, high = 0x4ff00000, 0x4ff28000
        symbols = {"nih_storage_read":low + 128, "nih_storage_controller_begin":low + 256,
                   "nih_storage_controller_end":low + 384,
                   "sdmmc_probe.dma_data":low + 512, "sdmmc_probe.dma_descriptor":low + 1024}
        sizes = {"sdmmc_probe.dma_data":512,"sdmmc_probe.dma_descriptor":64}
        MODULE.audit_sdmmc_resident(symbols, sizes, low, high)
        for name in symbols:
            for address in (0x40001120,0x48004000,high):
                with self.subTest(name=name,address=address),self.assertRaises(ValueError):
                    MODULE.audit_sdmmc_resident({**symbols,name:address},sizes,low,high)
        for name in sizes:
            for address in (low + 1, high - 64):
                if address == high - 64 and sizes[name] == 64:continue
                with self.subTest(name=name,address=address),self.assertRaises(ValueError):
                    MODULE.audit_sdmmc_resident({**symbols,name:address},sizes,low,high)
            with self.subTest(name=name),self.assertRaises(ValueError):
                MODULE.audit_sdmmc_resident(symbols,{**sizes,name:sizes[name]+4},low,high)
            changed=symbols.copy();del changed[name]
            with self.assertRaises(ValueError):MODULE.audit_sdmmc_resident(changed,sizes,low,high)

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

    def test_heap_is_the_unloaded_tail_after_primary_bss(self):
        for low, high, _ in MODULE.SRAM_PROFILES.values():
            start = high - 65536
            symbols = {"__bss_end": start - 16, "__heap_start": start, "__heap_end": high}
            sections = [{"name": ".bss", "address": hex(start - 32768 - 16), "bytes": 32768},
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


class SQLiteBoundaryTests(unittest.TestCase):
    def test_flash_sql_requires_opt_in_and_no_writable_or_outside_sections(self):
        MODULE.audit_flash_section(".flash.sqltext", 1, 6, 0x40020000, 64, True)
        MODULE.audit_flash_section(".flash.sqlrodata", 1, 50, 0x40020100, 64, True)
        for name, flags, address, enabled in ((".flash.sqltext", 6, 0x40020000, False),
                (".flash.sqltext", 7, 0x40020000, True), (".flash.sqlrodata", 3, 0x40020100, True),
                (".flash.sqltext", 6, 0x400c0000, True)):
            with self.subTest(name=name, flags=flags), self.assertRaises(ValueError):
                MODULE.audit_flash_section(name, 1, flags, address, 64, enabled)

    def test_sql_manifest_cannot_silently_admit_a_resident_function(self):
        funcs = [("psram.probe", 0x40000120, 0x40000140),
                 ("psram_memory.prepare__func_1", 0x40000140, 0x40000160),
                 ("heap.allocTask", 0x40020000, 0x40020020)]
        with self.assertRaisesRegex(ValueError, "non-manifest"):
            MODULE.audit_boot_functions(funcs, 0x40000120, 0x40000160, 0x4ff20000, 0x4ff48000,
                                        (0x40020000, 0x40020100), ["sqlite3_open"])
        funcs[-1] = ("sqlite3_open", 0x40020000, 0x40020020)
        result = MODULE.audit_boot_functions(funcs, 0x40000120, 0x40000160, 0x4ff20000, 0x4ff48000,
                                            (0x40020000, 0x40020100), ["sqlite3_open"])
        self.assertEqual(set(result), {"probe", "mapping"})

    def test_c_static_stack_metadata_has_bounded_checked_records(self):
        funcs = [("sqlite3_open", 0x40020000, 0x40020020)]
        result = MODULE.decode_stack_sizes(struct.pack("<I", 0x40020000) + bytes([0x80, 0x06]), funcs)
        self.assertEqual(result["maximum_reported_frame_bytes"], 768)
        for data in (b"x", struct.pack("<I", 0x40020000) + b"\x80", struct.pack("<I", 0x40020020) + b"\0"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                MODULE.decode_stack_sizes(data, funcs)


def loader_elf(sections):
    elf = bytearray(52 + 40 * len(sections))
    elf[:7] = b"\x7fELF\x01\x01\x01"
    struct.pack_into("<HHIIIIIHHHHHH", elf, 16, 2, 243, 1, 0, 0, 52, 0, 52, 0, 0, 40, len(sections), 0)
    for index, (kind, flags, address, size) in enumerate(sections):
        struct.pack_into("<10I", elf, 52 + index * 40, 0, kind, flags, address, 0, size, 0, 0, 4, 0)
    return bytes(elf)


if __name__ == "__main__":
    unittest.main()

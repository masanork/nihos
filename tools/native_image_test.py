"""Instruction-boundary checks for the restricted RV32IMAF/C native audit."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("native_image", Path(__file__).with_name("check-native-image.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeInstructionTests(unittest.TestCase):
    def test_heap_is_the_unloaded_tail_after_stacks(self):
        symbols = {"__irq_stack1_top": 0x4ff17ff0, "__heap_start": 0x4ff18000, "__heap_end": 0x4ff20000}
        sections = [{"name": ".stacks", "address": "0x4ff0fff0", "bytes": 32768},
                    {"name": ".heap", "address": "0x4ff18000", "bytes": 32768}]
        self.assertEqual(MODULE.audit_heap_layout(symbols, sections)["bytes"], 32768)
        for field, value in (("__heap_start", 0x4ff17000), ("__heap_start", 0x4ff18001),
                             ("__heap_end", 0x48020000), ("__heap_start", 0x4ff1f000)):
            with self.subTest(field=field, value=hex(value)), self.assertRaises(ValueError):
                MODULE.audit_heap_layout({**symbols, field: value}, sections)
        with self.assertRaisesRegex(ValueError, "overlaps"):
            MODULE.audit_heap_layout(symbols, sections + [{"name": ".bad", "address": "0x4ff18000", "bytes": 64}])
        with self.assertRaisesRegex(ValueError, "differs"):
            MODULE.audit_heap_layout(symbols, sections[:1])

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


if __name__ == "__main__":
    unittest.main()

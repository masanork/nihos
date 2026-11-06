#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location('irq_edges', Path(__file__).with_name('inspect-irq-edges.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EdgeTest(unittest.TestCase):
    def test_resolves_pc_relative_call_and_tail_but_keeps_dynamic_jump(self):
        asm = '''
1000 <nih_native_trap>:
1000: auipc ra,0x0
1004: jalr 16(ra) # 1010 <first>
1008: jalr a5
100a: ret
1010 <first>:
1010: auipc t1,0x0
1014: jr 16(t1) # 1020 <ssh_target>
1020 <ssh_target>:
1020: ret
1030 <nih_native_dispatch>:
1030: ret
'''
        result = module.analyze(asm, placed_addresses={0x1020: ['ssh_target', 'alias']})
        self.assertEqual([{'address': '0x1020', 'symbols': ['ssh_target', 'alias']}], result['directly_reachable_placed_functions'])
        self.assertEqual(['ssh_target'], result['directly_reachable_ssh_crypto_names'])
        self.assertEqual(1, result['unresolved_indirect_count'])
        self.assertEqual('jalr', result['unresolved_indirect_sites'][0]['op'])

    def test_register_mismatch_and_nonadjacent_pair_are_unresolved(self):
        asm = '''
1000 <nih_native_trap>:
1000: auipc t0,0x0
1004: jalr 16(t1) # 1010 <ssh_target>
1008: auipc t1,0x0
100c: nop
1010: jr 16(t1) # 1018 <ssh_target>
1018 <ssh_target>:
1018: ret
1020 <nih_native_dispatch>:
1020: ret
'''
        result = module.analyze(asm)
        self.assertEqual([], result['directly_reachable_ssh_crypto_names'])
        self.assertEqual(2, result['unresolved_indirect_count'])

    def test_jump_table_hint_stays_unresolved(self):
        asm = """
1000 <nih_native_trap>:
1000: lui a1,0x4ff13
1004: addi a1,a1,-1788 # 4ff12904 <.LJTI383_0>
1008: lw a0,0(a0)
100c: jr a0
1010 <nih_native_dispatch>:
1010: ret
"""
        result = module.analyze(asm)
        self.assertEqual(1, result['possible_jump_table_hints'])
        self.assertEqual(1, result['unresolved_indirect_count'])
        self.assertTrue(result['unresolved_indirect_sites'][0]['possible_jump_table_hint'])

    @staticmethod
    def switch_program():
        return """
1000 <nih_native_trap>:
1000: li a1,1
1002: bltu a1,a0,1020 <nih_native_trap+0x20>
1006: slli a0,a0,0x2
1008: lui a2,0x1
100c: addi a2,a2,0 # 1000 <.LJTI0_0>
1010: add a0,a0,a2
1012: lw a0,0(a0)
1014: jr a0
1016: nop
1018: ret
1020: ret
1030 <nih_native_dispatch>:
1030: ret
"""

    def test_guarded_internal_table_resolves_only_with_valid_entries(self):
        calls = []
        def read_words(address, count):
            calls.append((address, count))
            return (0x1016, 0x1018)
        result = module.analyze(self.switch_program(), read_words=read_words)
        self.assertEqual([(0x1000, 2)], calls)
        self.assertEqual(1, result['resolved_internal_jump_table_count'])
        self.assertEqual(0, result['unresolved_indirect_count'])
        result = module.analyze(self.switch_program(), read_words=lambda a, n: (0x1016, 0x2000))
        self.assertEqual(0, result['resolved_internal_jump_table_count'])
        self.assertEqual(1, result['unresolved_indirect_count'])

    def test_table_remains_unresolved_if_guard_can_be_bypassed(self):
        asm = self.switch_program().replace('1000: li a1,1', '0ffc: j 1006 <nih_native_trap+0x6>\n1000: li a1,1')
        result = module.analyze(asm, read_words=lambda a, n: (0x1016, 0x1018))
        self.assertEqual(0, result['resolved_internal_jump_table_count'])
        self.assertEqual(1, result['unresolved_indirect_count'])
        asm = self.switch_program().replace('bltu a1,a0,1020', 'bltu a0,a1,1020')
        result = module.analyze(asm, read_words=lambda a, n: (0x1016, 0x1018))
        self.assertEqual(0, result['resolved_internal_jump_table_count'])
        self.assertEqual(1, result['unresolved_indirect_count'])

    def test_inverted_guard_and_intervening_stack_store(self):
        asm = self.switch_program().replace(
            '1000: li a1,1\n1002: bltu a1,a0,1020 <nih_native_trap+0x20>\n1006: slli',
            '0ffc: li a1,1\n0ffe: sw s1,4(sp)\n1000: bgeu a1,a0,1006 <nih_native_trap+0x6>\n1004: j 1020 <nih_native_trap+0x20>\n1006: slli')
        result = module.analyze(asm, read_words=lambda a, n: (0x1016, 0x1018))
        self.assertEqual(1, result['resolved_internal_jump_table_count'])
        self.assertEqual(0, result['unresolved_indirect_count'])
        # Another jump to the guarded body can bypass the bound entirely.
        asm = asm.replace('0ffc: li a1,1', '0ff8: j 1006 <nih_native_trap+0x6>\n0ffc: li a1,1')
        result = module.analyze(asm, read_words=lambda a, n: (0x1016, 0x1018))
        self.assertEqual(0, result['resolved_internal_jump_table_count'])
        self.assertEqual(1, result['unresolved_indirect_count'])

    def test_untrusted_store_does_not_qualify_table(self):
        asm = self.switch_program().replace('1014: jr a0\n1016: nop\n1018: ret', '1014: sw a2,0(a3)\n1016: jr a0\n1018: nop\n101a: ret')
        result = module.analyze(asm, read_words=lambda a, n: (0x1018, 0x101a))
        self.assertEqual(0, result['resolved_internal_jump_table_count'])
        self.assertEqual(1, result['unresolved_indirect_count'])

    def test_table_reader_rejects_writable_and_out_of_bounds(self):
        path = Path(__file__).resolve().parents[2] / 'tools/audit_ssh_ed25519_table_test.py'
        spec = importlib.util.spec_from_file_location('table_fixture', path)
        table_fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(table_fixture)
        with tempfile.TemporaryDirectory() as directory:
            elf = Path(directory) / 'case.elf'
            elf.write_bytes(table_fixture.fixture([(0x40011000, False)]))
            read = module.readonly_elf_reader(elf)
            self.assertEqual((0x03020100, 0x07060504), read(0x40011000, 2))
            self.assertIsNone(read(0x40011001, 2))
            self.assertIsNone(read(0x40011000, 257))
            elf.write_bytes(table_fixture.fixture([(0x4ff01000, True)]))
            read = module.readonly_elf_reader(elf)
            self.assertIsNone(read(0x4ff01000, 2))

    def test_flash_witness_preserves_branch_and_call_sites(self):
        asm = """
4ff01000 <nih_native_trap>:
4ff01000: jal 40060000 <render>
4ff01004: ret
4ff02000 <nih_native_dispatch>:
4ff02000: ret
40060000 <render>:
40060000: ret
"""
        path = module.analyze(asm)['example_existing_xy_flash_path']
        self.assertEqual(['nih_native_trap', 'render'], [item['symbol'] for item in path])
        self.assertEqual('0x4ff01000', path[1]['incoming_edge']['pc'])
        self.assertEqual('jal', path[1]['incoming_edge']['op'])

    def test_missing_root_fails_closed(self):
        with self.assertRaises(ValueError):
            module.analyze('1000 <nih_native_trap>:\n1000: ret\n')


if __name__ == '__main__':
    unittest.main()

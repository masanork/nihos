#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

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

    def test_missing_root_fails_closed(self):
        with self.assertRaises(ValueError):
            module.analyze('1000 <nih_native_trap>:\n1000: ret\n')


if __name__ == '__main__':
    unittest.main()

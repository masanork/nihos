"""Structural inventory must not promote partial paths to stack qualification."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('call_stack', Path(__file__).with_name('check-native-call-stack.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def nodes():
    return {0x40000100: {'names': ['root'], 'end': 0x40000140, 'frame': 32},
            0x40000200: {'names': ['callee'], 'end': 0x40000240, 'frame': 1248},
            0x40000300: {'names': ['leaf'], 'end': 0x40000340, 'frame': 16}}


class NativeCallStackTests(unittest.TestCase):
    def parse(self, text, data=None):
        data = data or nodes()
        edges, unknown = MODULE.transfers(text, data)
        return MODULE.analyze(data, edges, unknown, 0x40000100)

    def test_calls_and_tail_transfers_accumulate_but_do_not_qualify_execution(self):
        result = self.parse('''
40000100: jalr 256(ra) # 40000200 <callee>
40000104: j 40000110 <root+0x10>
40000200: jr 256(t1) # 40000300 <leaf>
40000300: ret
''')
        self.assertTrue(result['graph_closed'])
        self.assertEqual(result['known_frames_on_largest_structural_chain_bytes'], 1296)
        self.assertEqual(len(result['structural_chain']), 3)
        self.assertFalse(result['whole_call_stack_qualified'])

    def test_missing_frame_is_explicit_and_never_closes_graph(self):
        data = nodes(); data[0x40000200]['frame'] = None
        result = self.parse('40000100: jal 40000200 <callee>\n40000200: ret\n40000300: ret', data)
        self.assertFalse(result['graph_closed'])
        self.assertIsNone(result['missing_frames'][0]['frame_bytes'])
        self.assertEqual(result['missing_frames'][0]['functions'], ['callee'])
        self.assertFalse(result['whole_call_stack_qualified'])

    def test_indirect_call_jump_and_syscall_boundaries_remain_open(self):
        for instruction, kind in [('jalr a5', 'indirect-transfer'), ('jr a3', 'indirect-transfer'),
                                  ('ecall', 'syscall-stack-boundary'), ('mret', 'context-return-boundary')]:
            with self.subTest(instruction=instruction):
                result = self.parse('40000100: ' + instruction)
                self.assertFalse(result['graph_closed'])
                self.assertEqual(result['unresolved_transfers'][0]['sites'][0]['kind'], kind)

    def test_cross_function_conditional_transfer_is_included(self):
        result = self.parse('40000100: bnez a0,40000200 <callee>\n40000200: ret')
        self.assertEqual(result['known_frames_on_largest_structural_chain_bytes'], 1280)
        self.assertTrue(result['graph_closed'])

    def test_return_is_not_misclassified_as_indirect_call(self):
        self.assertTrue(self.parse('40000100: jr ra')['graph_closed'])
        self.assertTrue(self.parse('40000100: ret')['graph_closed'])

    def test_unmeasured_rom_or_mid_function_targets_remain_open(self):
        for target in ('4fc00054', '40000204'):
            result = self.parse('40000100: jal ' + target + ' <unknown>')
            self.assertFalse(result['graph_closed'])
            self.assertEqual(result['unresolved_transfers'][0]['sites'][0]['kind'], 'unmeasured-target')

    def test_recursion_is_reported_instead_of_silently_cut_to_zero(self):
        result = self.parse('''
40000100: jal 40000200 <callee>
40000200: jal 40000300 <leaf>
40000300: jal 40000200 <callee>
''')
        self.assertFalse(result['graph_closed'])
        self.assertEqual([row['functions'] for row in result['recursive_functions']], [['callee'], ['leaf']])

    def test_missing_or_unparsed_disassembly_does_not_count_as_leaf(self):
        result = self.parse('40000100 <root>:')
        self.assertFalse(result['graph_closed'])
        self.assertEqual(result['unresolved_transfers'][0]['sites'][0]['kind'], 'no-disassembly')

    def test_real_large_frames_remain_visible_in_call_chain(self):
        data = nodes(); data[0x40000200]['frame'] = 7008
        result = self.parse('40000100: jal 40000200 <callee>\n40000200: ret', data)
        self.assertEqual(result['known_frames_on_largest_structural_chain_bytes'], 7040)
        self.assertFalse(result['whole_call_stack_qualified'])

    def test_candidate_callback_is_included_without_assuming_exclusivity(self):
        data = nodes()
        edges, unknown = MODULE.transfers('40000100: jalr a3\n40000200: ret\n40000300: ret', data)
        candidates = MODULE.add_candidate_edges(data, edges, unknown, ['root:callee'])
        result = MODULE.analyze(data, edges, unknown, 0x40000100)
        self.assertEqual(result['reachable_functions'], 2)
        self.assertEqual(result['known_frames_on_largest_structural_chain_bytes'], 1280)
        self.assertFalse(candidates[0]['target_exclusivity_proven'])
        self.assertFalse(result['graph_closed'])
        self.assertEqual(result['unresolved_transfers'][0]['sites'][0]['candidate_callees'], ['callee'])
        for specification in ['missing:callee', 'callee:leaf']:
            with self.assertRaises(ValueError): MODULE.add_candidate_edges(data, edges, unknown, [specification])

    def test_invalid_elf_and_missing_root_fail_closed(self):
        with self.assertRaises(ValueError): MODULE.elf_functions(b'invalid ELF')
        with self.assertRaises(ValueError): MODULE.analyze({}, {}, {}, 0)


if __name__ == '__main__':
    unittest.main()

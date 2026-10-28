"""Reject SP-flow shortcuts that previously made missing frames look harmless."""
import struct
import unittest
import riscv_stack_flow as FLOW

BASE = 0x40000000


def word(value):
    return struct.pack('<I', value)


def addi_sp(delta):
    return word(((delta & 4095) << 20) | (2 << 15) | (2 << 7) | 0x13)


def run(rows):
    code = b''
    lines = []
    for raw, text in rows:
        lines.append(format(BASE + len(code), '08x') + ': ' + text)
        code += raw
    return FLOW.local_sp_bound(BASE, code, FLOW.instructions('\n'.join(lines)))


class NativeStackFlowTests(unittest.TestCase):
    def test_balanced_return_and_shrink_wrapped_paths(self):
        r = run([(addi_sp(-16), 'addi sp,sp,-16'), (addi_sp(16), 'addi sp,sp,16'), (b'\x82\x80', 'ret')])
        self.assertEqual(r['local_sp_decrease_bytes'], 16)
        self.assertEqual(r['balanced_returns'], 1)
        r = run([(word(0x00050863), 'beqz a0,40000010 <exit>'), (addi_sp(-16), 'addi sp,sp,-16'),
                 (addi_sp(16), 'addi sp,sp,16'), (b'\x82\x80', 'ret'), (b'\x01\x00', 'nop'), (b'\x82\x80', 'ret')])
        self.assertEqual(r['local_sp_decrease_bytes'], 16)
        self.assertEqual(r['balanced_returns'], 2)
        self.assertFalse(r['stack_memory_footprint_proven'])

    def test_compressed_sp_arithmetic_and_memory_store_of_sp(self):
        self.assertEqual(run([(b'\x41\x11', 'addi sp,sp,-16'), (b'\x41\x01', 'addi sp,sp,16'),
                              (b'\x82\x80', 'ret')])['local_sp_decrease_bytes'], 16)
        self.assertFalse(FLOW.writes_sp(word(0x00252023))[0])  # sw sp,0(a0)
        self.assertTrue(FLOW.writes_sp(b'\x02\x41')[0])  # lw sp,0(sp)
        self.assertTrue(FLOW.writes_sp(b'\x2a\x81')[0])  # mv sp,a0
        self.assertTrue(FLOW.writes_sp(b'\x2a\x91')[0])  # add sp,sp,a0

    def test_dynamic_and_loaded_sp_are_rejected(self):
        for raw, text in [(word(0x40a10133), 'sub sp,sp,a0'), (b'\x02\x41', 'lw sp,0(sp)'),
                          (b'\x2a\x81', 'mv sp,a0'), (b'\x2a\x91', 'add sp,sp,a0')]:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, 'SP assignment'):
                run([(raw, text), (b'\x82\x80', 'ret')])

    def test_stack_growing_loop_and_conflicting_join_fail(self):
        with self.assertRaisesRegex(ValueError, 'CFG join'):
            run([(addi_sp(-16), 'addi sp,sp,-16'), (word(0xffdff06f), 'j 40000000 <loop>')])
        with self.assertRaises(ValueError):
            run([(word(0x00050463), 'beqz a0,40000008 <exit>'), (addi_sp(-16), 'addi sp,sp,-16'), (b'\x82\x80', 'ret')])

    def test_unbalanced_return_tail_and_upward_sp_fail(self):
        for ending in [(b'\x82\x80', 'ret'), (word(0x1000006f), 'j 40000100 <outside>')]:
            with self.assertRaisesRegex(ValueError, 'unrestored'):
                run([(addi_sp(-16), 'addi sp,sp,-16'), ending])
        with self.assertRaisesRegex(ValueError, 'above entry'):
            run([(addi_sp(16), 'addi sp,sp,16'), (b'\x82\x80', 'ret')])

    def test_unsupported_width_opcode_and_missing_instruction_fail(self):
        for raw in (b'\x1f\x00\x00\x00', word(0x00000007), b'\x13'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                run([(raw, 'unknown'), (b'\x82\x80', 'ret')])
        with self.assertRaisesRegex(ValueError, 'missing disassembly'):
            FLOW.local_sp_bound(BASE, addi_sp(-16) + b'\x82\x80', FLOW.instructions('40000000: addi sp,sp,-16'))

    def test_no_assumed_return_after_terminal_call(self):
        with self.assertRaisesRegex(ValueError, 'leaves body'):
            run([(word(0x00000097), 'auipc ra,0'), (word(0x000080e7), 'jalr ra')])

    def test_terminal_call_is_derived_only_after_binary_nonreturn_summary(self):
        caller = addi_sp(-16) + word(0x00000097) + word(0x000080e7)
        callee = word(0x0000006f)
        nodes = {BASE: {'names': ['caller'], 'frame': None, 'code': caller},
                 BASE + 0x100: {'names': ['callee'], 'frame': None, 'code': callee}}
        text = '40000000: addi sp,sp,-16\n40000004: auipc ra,0\n40000008: jalr ra # 40000100 <callee>\n40000100: j 40000100 <loop>'
        results = FLOW.derive_missing(nodes, {BASE: {BASE+0x100}}, [BASE], text)
        self.assertTrue(all(row['derived'] for row in results))
        self.assertEqual(nodes[BASE]['frame'], 16)
        self.assertTrue(results[0]['normal_return_impossible_under_call_abi'])
        self.assertEqual(results[0]['nonreturning_call_dependencies'][0]['callee_code_sha256'], results[1]['code_sha256'])
        # A normal-return path, unknown tail or trap does not establish noreturn.
        for body, instruction in [(b'\x82\x80', 'ret'), (word(0x1000006f), 'j 40000200 <outside>'), (b'\x00\x00', 'unimp')]:
            nodes[BASE]['frame'] = None
            nodes[BASE+0x100].update(frame=None, code=body)
            changed = text.replace('j 40000100 <loop>', instruction)
            result = FLOW.derive_missing(nodes, {BASE: {BASE+0x100}}, [BASE], changed)
            self.assertFalse(result[0]['derived'])
            self.assertIsNone(nodes[BASE]['frame'])

    def test_callee_assumption_and_context_boundary_are_explicit(self):
        r = run([(word(0x100000ef), 'jal 40000100 <callee>'), (b'\x82\x80', 'ret')])
        self.assertEqual(r['calls_assumed_to_restore_sp'], 1)
        self.assertFalse(r['callee_stacks_proven'])
        with self.assertRaisesRegex(ValueError, 'misaligned'):
            run([(addi_sp(-8), 'addi sp,sp,-8'), (word(0x100000ef), 'jal 40000100 <callee>'),
                 (addi_sp(8), 'addi sp,sp,8'), (b'\x82\x80', 'ret')])
        with self.assertRaisesRegex(ValueError, 'context-return'):
            run([(word(0x30200073), 'mret')])


if __name__ == '__main__':
    unittest.main()

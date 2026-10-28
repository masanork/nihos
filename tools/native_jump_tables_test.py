"""Guard domination and immutable target enumeration, using synthetic CFGs."""
import copy
import struct
import unittest
import riscv_jump_tables as JUMP
import riscv_stack_flow as FLOW

BASE, TABLE = 0x40000000, 0x40001000


def fixture(relative=False):
    # Decode inputs model the two compiler forms; real-ELF tests use objdump.
    lines = ['40000000: li a1,2', '40000004: bltu a1,a0,40000070 <default>',
             '40000008: slli a0,a0,2', '4000000c: lui a2,0x40001',
             '40000010: add a0,a0,a2', '40000014: lw a3,0(a0)']
    if relative: lines += ['40000018: add a3,a2,a3', '4000001c: jr a3']
    else: lines += ['40000018: jr a3']
    lines += ['40000040: ret', '40000050: ret', '40000060: ret', '40000070: ret']
    text = '\n'.join(lines)
    words = [BASE+0x40, BASE+0x50, BASE+0x60]
    if relative: words = [(v-TABLE) & 0xffffffff for v in words]
    data = struct.pack('<3I', *words)
    nodes = {BASE: {'names': ['function'], 'end': BASE+0x80, 'frame': 16, 'code': bytes(128)}}
    site = BASE + (0x1c if relative else 0x18)
    return nodes, FLOW.instructions(text), [(TABLE, data)], site, text


class NativeJumpTableTests(unittest.TestCase):
    def test_absolute_and_base_relative_tables_stay_inside_function(self):
        for relative in (False, True):
            nodes, decoded, regions, site, _ = fixture(relative)
            r = JUMP.verify(nodes, decoded, regions, BASE, site)
            self.assertEqual(r['table_entries'], 3)
            self.assertEqual(r['targets'], ['0x40000040', '0x40000050', '0x40000060'])
            self.assertFalse(r['interprocedural_stack_qualified'])
            self.assertTrue(r['normal_call_abi_assumed'])

    def test_missing_signed_or_excessive_guard_is_rejected(self):
        nodes, decoded, regions, site, _ = fixture()
        for replacement in [('bgt', 'a1,a0,40000070 <default>', 'a1,a0,40000070 <default>'),
                            ('blt', 'a1,a0,40000070 <default>', 'a1,a0,40000070 <default>')]:
            bad = dict(decoded); bad[BASE+4] = replacement
            with self.assertRaises(ValueError): JUMP.verify(nodes, bad, regions, BASE, site)
        for bound in ('64', '-1'):
            bad = dict(decoded); bad[BASE] = ('li', 'a1,'+bound, 'a1,'+bound)
            with self.assertRaises(ValueError): JUMP.verify(nodes, bad, regions, BASE, site)

    def test_guard_bypass_or_other_indirect_entry_is_rejected(self):
        nodes, decoded, regions, site, _ = fixture()
        for extra in [('j', '40000008 <bypass>', '40000008 <bypass>'), ('jr', 'a4', 'a4')]:
            bad = dict(decoded); bad[BASE+0x74] = extra
            with self.assertRaises(ValueError): JUMP.verify(nodes, bad, regions, BASE, site)
        bad_nodes = copy.deepcopy(nodes);bad_nodes[BASE+8] = {'names':['alias'],'end':BASE+0x20,'frame':0,'code':bytes(24)}
        with self.assertRaises(ValueError): JUMP.verify(bad_nodes, decoded, regions, BASE, site)

    def test_other_function_middle_instruction_and_dispatch_targets_are_rejected(self):
        nodes, decoded, regions, site, _ = fixture()
        for value in (0x4ff001c2, BASE+0x42, BASE+8):
            bad = [(TABLE, struct.pack('<3I', value, BASE+0x50, BASE+0x60))]
            with self.assertRaises(ValueError): JUMP.verify(nodes, decoded, bad, BASE, site)

    def test_mutable_unmapped_short_or_ambiguous_table_fails_closed(self):
        nodes, decoded, regions, site, _ = fixture()
        for bad in ([], [(TABLE, regions[0][1][:-1])]):
            with self.assertRaises(ValueError): JUMP.verify(nodes, decoded, bad, BASE, site)
        bad = dict(decoded);bad[BASE+0x14] = ('lw','a3,4(a0)','a3,4(a0)')
        with self.assertRaises(ValueError): JUMP.verify(nodes, bad, regions, BASE, site)

    def test_unsupported_dispatch_write_and_unknown_index_fail_closed(self):
        nodes, decoded, regions, site, _ = fixture()
        for instruction in [('sub','a0,a0,a2','a0,a0,a2'), ('mv','a0,s1','a0,s1')]:
            bad = dict(decoded);bad[BASE+8] = instruction
            with self.assertRaises(ValueError): JUMP.verify(nodes, bad, regions, BASE, site)

    def test_resolution_retains_callback_and_other_unknown_sites(self):
        nodes, decoded, regions, site, text = fixture()
        unknown = {BASE:[{'pc':hex(site),'kind':'indirect-transfer','instruction':'jr a3'},
                         {'pc':hex(BASE+0x78),'kind':'syscall-stack-boundary','instruction':'ecall'}]}
        r = JUMP.resolve(nodes, unknown, text, regions)
        self.assertEqual(len(r['resolved']), 1)
        self.assertEqual(len(unknown[BASE]), 1)
        self.assertEqual(unknown[BASE][0]['kind'], 'syscall-stack-boundary')

    def test_only_readonly_allocated_progbits_are_loaded(self):
        # Minimal ELF header/section metadata needed by readonly_regions.
        data = bytearray(0x100)
        struct.pack_into('<HHIIIIIHHHHHH',data,16,2,243,1,BASE,0,52,0,52,0,0,40,1,0)
        for flags in (0, 1, 3, 6):
            struct.pack_into('<10I',data,52,0,1,flags,TABLE,0xe0,4,0,0,4,0)
            self.assertEqual(JUMP.readonly_regions(data), [])
        struct.pack_into('<10I',data,52,0,1,2,TABLE,0xe0,4,0,0,4,0)
        self.assertEqual(len(JUMP.readonly_regions(data)),1)


if __name__ == '__main__':
    unittest.main()

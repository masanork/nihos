import unittest
from inspect_xip_calls import inspect

class CallsTest(unittest.TestCase):
    def test_direct_incoming_and_unresolved_indirect_are_separate(self):
        asm = '''4ff00000 <caller>:
 4ff00002: 000000ef jal 40009000 <target>
 4ff00006: 000080e7 jalr 0(ra) # 40009004 <helper>
 4ff0000a: 9282 jalr t0
40009000 <target>:
 40009000: 000000ef jal 40009004 <helper>
'''
        report = inspect(asm, 0x40009000, 0x40009100)
        self.assertEqual([x['target'] for x in report['incoming_annotated_branches']], ['target', 'helper'])
        self.assertEqual(report['unresolved_indirect_jalr'][0]['caller'], 'caller')
        self.assertEqual(len(report['unresolved_indirect_jalr']), 1)

if __name__ == '__main__':
    unittest.main()

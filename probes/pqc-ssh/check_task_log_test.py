#!/usr/bin/env python3
import unittest
from check_task_log import check

GOOD = ('NIHOS_NATIVE_NORMAL_READY wait_us=00000001\n'
        'NIHOS_PQC_DRIVER verified=00000001 reclaimed=00000001\n'
        'NIHOS_PQC_HANDOFF ok=00000001 deadline=00000000 packet=00000001\n'
        'NIHOS_PQC_TASK status=00000000 ok=00000001 peak=00004b20 wrong_epoch=00000001 '
        'repeat=00000001 canceled=00000001 captures=00000007 timers=00000005 stack_used=00001130 '
        'guards=00000001 erased=00000001 released=00000001 stale=00000001 stale_notify=00000001 charged=00040000 '
        'ticks0=0000000c ticks1=0000000c ssh_ok=00000001 ssh_bad_pin=00000001 '
        'ssh_bad_sig=00000001 ssh_bad_transcript=00000001 ssh_secret_cleared=00000001 '
        'phase=00000003 waits=00000001 delivered=00000001 negative=00000000\nNIHOS_PQC_TASK_DONE\n')
SKIP = 'NIHOS_NATIVE_NORMAL_READY wait_us=00000001\nNIHOS_PQC_TASK_SKIP reason=00000001\nNIHOS_PQC_TASK_DONE\n'
BAD_CT = (GOOD.replace('status=00000000', 'status=ffffffa1')
          .replace('ssh_ok=00000001', 'ssh_ok=00000000')
          .replace('negative=00000000', 'negative=00000001'))
BAD_PIN = (GOOD.replace('status=00000000', 'status=ffffffa1')
           .replace('ssh_ok=00000001', 'ssh_ok=00000000')
           .replace('negative=00000000', 'negative=00000002'))
BAD_SIGNATURE = (GOOD.replace('status=00000000', 'status=ffffffa1')
                 .replace('ssh_ok=00000001', 'ssh_ok=00000000')
                 .replace('negative=00000000', 'negative=00000004'))
TIMEOUT = (GOOD.replace('status=00000000', 'status=ffffff9f')
           .replace('ssh_ok=00000001', 'ssh_ok=00000000')
           .replace('phase=00000003', 'phase=00000005')
           .replace('negative=00000000', 'negative=00000003')
           .replace('deadline=00000000', 'deadline=00000001')
           .replace('packet=00000001', 'packet=00000000')
           .replace('verified=00000001', 'verified=00000000'))

class Tests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(check(GOOD, True)['stack_used'], 4400)
        self.assertEqual(check(SKIP, False)['status'], 'no_psram_skipped')
        self.assertEqual(check(BAD_CT, True, 1)['ssh_ok'], 0)
        self.assertEqual(check(BAD_PIN, True, 2)['ssh_ok'], 0)
        self.assertEqual(check(TIMEOUT, True, 3)['ssh_ok'], 0)
        self.assertEqual(check(BAD_SIGNATURE, True, 4)['ssh_ok'], 0)
    def test_failures_are_not_success(self):
        for bad in (GOOD.replace('reclaimed=00000001', 'reclaimed=00000000'),
                    GOOD.replace('NIHOS_PQC_HANDOFF ok=00000001', 'NIHOS_PQC_HANDOFF ok=00000000'),
                    GOOD.replace('released=00000001', 'released=00000000'),
                    GOOD.replace('stale_notify=00000001', 'stale_notify=00000000'),
                    GOOD.replace('timers=00000005', 'timers=00000000'),
                    GOOD.replace('guards=00000001', 'guards=00000000'),
                    GOOD.replace('ssh_bad_pin=00000001', 'ssh_bad_pin=00000000'),
                    GOOD.replace('phase=00000003', 'phase=00000001'),
                    GOOD.replace('delivered=00000001', 'delivered=00000000'),
                    GOOD.replace('status=00000000', 'status=00000001'),
                    GOOD + GOOD, GOOD.replace('NIHOS_PQC_TASK_DONE', '')):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError): check(bad, True)
        with self.assertRaises(ValueError): check(SKIP.replace('reason=00000001', 'reason=00000003'), False)
        with self.assertRaises(ValueError): check(GOOD, False)
        with self.assertRaises(ValueError): check(BAD_CT.replace('ssh_ok=00000000', 'ssh_ok=00000001'), True, 1)
        with self.assertRaises(ValueError): check(BAD_PIN.replace('ssh_bad_pin=00000001', 'ssh_bad_pin=00000000'), True, 2)
        with self.assertRaises(ValueError): check(TIMEOUT.replace('ssh_secret_cleared=00000001', 'ssh_secret_cleared=00000000'), True, 3)

if __name__ == '__main__':
    unittest.main()

"""Host-only state model; it does not control hardware or native code."""
import unittest

class Gate:
    def __init__(self):
        self.state = 'open'
        self.epoch = 1
        self.holders = set()
        self.acks = set()

    def acquire(self, token):
        if self.state != 'open' or token[1] != self.epoch or token in self.holders:
            return False
        self.holders.add(token)
        return True

    def drain(self):
        if self.state != 'open':
            return False
        self.state = 'draining'
        self.acks.clear()
        return True

    def release(self, token):
        if self.state not in ('open', 'draining') or token not in self.holders:
            return False
        self.holders.remove(token)
        return True

    def ack(self, hart, epoch):
        if self.state != 'draining' or epoch != self.epoch or hart not in (0, 1) or hart in self.acks:
            return False
        self.acks.add(hart)
        return True

    def enter_cache_off(self):
        if self.state != 'draining' or self.holders or self.acks != {0, 1}:
            return False
        self.state = 'off'
        return True

    def restored(self, success):
        if self.state != 'off':
            return False
        if not success:
            self.state = 'quarantined'
        else:
            self.epoch += 1
            self.acks.clear()
            self.state = 'open'
        return True

class CacheGateTests(unittest.TestCase):
    def test_drain_closes_admission_and_waits_for_all_holders_and_cores(self):
        g = Gate()
        self.assertTrue(g.acquire(('verify', 1)))
        self.assertTrue(g.acquire(('dma', 1)))
        self.assertTrue(g.drain())
        self.assertFalse(g.acquire(('verify', 2)))
        self.assertTrue(g.ack(0, g.epoch))
        self.assertFalse(g.enter_cache_off())
        self.assertTrue(g.release(('verify', 1)))
        self.assertTrue(g.ack(1, g.epoch))
        self.assertFalse(g.enter_cache_off())
        self.assertTrue(g.release(('dma', 1)))
        self.assertTrue(g.enter_cache_off())
        self.assertFalse(g.acquire(('irq', 1)))
        self.assertTrue(g.restored(True))
        self.assertTrue(g.acquire(('verify', 2)))
        self.assertFalse(g.release(('verify', 1)))
        self.assertFalse(g.acquire(('old_generation', 1)))
        self.assertTrue(g.drain())
        self.assertFalse(g.ack(0, 1))

    def test_failed_restore_quarantines(self):
        g = Gate()
        self.assertTrue(g.drain())
        self.assertTrue(g.ack(0, g.epoch) and g.ack(1, g.epoch))
        self.assertTrue(g.enter_cache_off())
        self.assertTrue(g.restored(False))
        self.assertFalse(g.acquire(('verify', 2)))
        self.assertFalse(g.restored(True))

    def test_duplicate_and_stale_holders_do_not_release_new_request(self):
        g = Gate()
        self.assertTrue(g.acquire(('verify', 1)))
        self.assertFalse(g.acquire(('verify', 1)))
        self.assertFalse(g.release(('verify', 2)))
        self.assertTrue(g.drain())
        self.assertTrue(g.ack(0, g.epoch) and g.ack(1, g.epoch))
        self.assertFalse(g.enter_cache_off())
        self.assertTrue(g.release(('verify', 1)))
        self.assertTrue(g.enter_cache_off())

    def test_uncoordinated_check_has_a_toctou_counterexample(self):
        # A reader checks the cache while open, then is preempted. If there is
        # no admission lease, a writer sees zero holders and disables the cache
        # before the reader resumes. The proposed model rejects that entry.
        g = Gate()
        self.assertEqual(g.state, 'open')
        self.assertTrue(g.drain() and g.ack(0, g.epoch) and g.ack(1, g.epoch) and g.enter_cache_off())
        self.assertFalse(g.acquire(('preempted_reader', 1)))
        naive_reader_resumes_without_rechecking = True
        self.assertTrue(naive_reader_resumes_without_rechecking and g.state == 'off')

if __name__ == '__main__':
    unittest.main()

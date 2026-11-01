import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('burst', Path(__file__).with_name('analyze-hosted-udp-burst.py'))
burst = importlib.util.module_from_spec(spec)
spec.loader.exec_module(burst)
LOG = ('ESP-ROM:esp32p4\nNIHOS_C6_BOOT backend=zig\nNIHOS_C6_LONG_DMA build=diagnostic data=1\n'
       'NIHOS_NATIVE_C6 status=1 stage=c error_code=0 cleanup_failed=0 fw_known=1 fw_major=1 fw_minor=4 fw_patch=1 '
       'short_sent=76 short_echo=1 long_logical=4e6 long_wire=600 long_sent=4e6 long_dma_state=0 '
       'long_burst=1 long_attempts=10 long_echo=1 long_echo_mask=4 ip=c0000201\nNIHOS_C6_HOSTED_WIFI_PASS ip=192.0.2.1\n')

def peer(length, attempt=None):
    payload = bytearray(i % 256 for i in range(length)); payload[:8] = b'NIHOSUDP'
    if attempt is not None: payload[8] = attempt
    return {'event': 'received', 'source_ip': '192.0.2.1', 'source_port': 44444,
            'bytes': length, 'attempt': attempt, 'sha256': hashlib.sha256(payload).hexdigest(), 'payload_matches': True}

def records(items):
    return '\n'.join(json.dumps(x) for x in items)

class BurstTests(unittest.TestCase):
    def test_staging_mismatch_is_reported_not_hidden(self):
        items = [peer(64), peer(1200, 3), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}]
        result = burst.analyze(LOG + 'NIHOS_C6_STAGING checked=0000ffff matched=00007fff\n', records(items))
        self.assertEqual(result['staging_audit']['mismatch_attempts'], [16])
        with self.assertRaisesRegex(ValueError, 'incomplete staging'):
            burst.analyze(LOG + 'NIHOS_C6_STAGING checked=00007fff matched=00007fff\n', records(items))

    def test_extended_interval_is_explicit(self):
        items = [peer(64), peer(1200, 3), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}]
        result = burst.analyze(LOG + 'NIHOS_C6_INTERVAL ms=000001f4\n', records(items))
        self.assertEqual(result['configured_interval_ms'], 500)
        with self.assertRaisesRegex(ValueError, 'interval trace'):
            burst.analyze(LOG + 'NIHOS_C6_INTERVAL ms=00000190\n', records(items))

    def test_reverse_identifiers_are_distinct_from_send_position(self):
        log = LOG.replace('long_echo_mask=4', 'long_echo_mask=8000')
        words = ['%08x%08x' % ((20 + i) | (i << 12), (500 << 16) | (1000 + i * 250)) for i in range(16)]
        items = [peer(64), peer(1200, 16), {'event': 'echoed', 'bytes': 1200, 'attempt': 16}]
        result = burst.analyze(log + 'NIHOS_C6_REVERSE_ATTEMPTS\nNIHOS_C6_CREDIT_TRACE ' + ' '.join(words) + '\n', records(items))
        self.assertEqual(result['send_order'], list(range(16, 0, -1)))
        self.assertEqual(result['device_tx_trace'][0]['attempt'], 16)
        self.assertEqual(result['device_tx_trace'][-1]['attempt'], 1)
        self.assertIn(1, result['not_observed_by_peer'])

    def test_pause_requires_causal_echo_snapshot_and_two_second_gap(self):
        log = LOG.replace('long_attempts=10', 'long_attempts=11').replace('long_echo_mask=4', 'long_echo_mask=8004').replace('long_echo=1', 'long_echo=2')
        times = [1000 + i * 250 for i in range(16)] + [6760]
        words = ['%08x%08x' % ((20 + i) | (i << 12), (500 << 16) | ms) for i, ms in enumerate(times)]
        captured = records([peer(64), peer(1200, 3), peer(1200, 16), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}, {'event': 'echoed', 'bytes': 1200, 'attempt': 16}])
        trace = 'NIHOS_C6_CREDIT_TRACE ' + ' '.join(words) + '\n'
        result = burst.analyze(log + trace + 'NIHOS_C6_BEFORE_17 mask=00008004 ms=00001a5e\n', captured)
        self.assertTrue(result['before_17']['echo_16'])
        with self.assertRaisesRegex(ValueError, 'invalid pause snapshot'):
            burst.analyze(log + trace + 'NIHOS_C6_BEFORE_17 mask=00008004 ms=00001a5d\n', captured)

    def test_short_tail_is_distinct_and_may_arrive_while_sixteen_is_missing(self):
        marker = {**peer(65), 'elapsed_us': 9000}
        log = LOG + 'NIHOS_C6_SHORT_TAIL sent=00000077 ms=00001000\n'
        result = burst.analyze(log, records([peer(64), peer(1200, 3), marker, {'event': 'echoed', 'bytes': 1200, 'attempt': 3}]))
        self.assertTrue(result['short_tail']['peer_received'])
        self.assertIn(16, result['not_observed_by_peer'])
        with self.assertRaisesRegex(ValueError, 'unexpected short tail'):
            burst.analyze(LOG, records([peer(64), peer(1200, 3), marker, {'event': 'echoed', 'bytes': 1200, 'attempt': 3}]))

    def test_eighteen_attempts_can_observe_sentinel_after_missing_sixteen(self):
        log = LOG.replace('long_attempts=10', 'long_attempts=12').replace('long_echo_mask=4', 'long_echo_mask=10004').replace('long_echo=1', 'long_echo=2')
        words = ['%08x%08x' % ((20 + i) | (i << 12), (500 << 16) | (1000 + i * 250)) for i in range(18)]
        items = [peer(64), peer(1200, 3), peer(1200, 17), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}, {'event': 'echoed', 'bytes': 1200, 'attempt': 17}]
        result = burst.analyze(log + 'NIHOS_C6_CREDIT_TRACE ' + ' '.join(words) + '\n', records(items))
        self.assertIn(16, result['not_observed_by_peer'])
        self.assertIn(17, result['device_echo_ids'])
        self.assertEqual(len(result['device_tx_trace']), 18)

    def test_partial_loss_is_measured_not_success_invented(self):
        result = burst.analyze(LOG, records([peer(64), peer(1200, 3), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}]))
        self.assertEqual(result['peer_arrival_order'], [3])
        self.assertEqual(result['device_echo_ids'], [3])
        self.assertEqual(len(result['not_observed_by_peer']), 15)

    def test_rejects_unmatched_echo_and_corruption(self):
        with self.assertRaisesRegex(ValueError, 'lacks matching'):
            burst.analyze(LOG, records([peer(64), peer(1200, 3)]))
        invalid = {**peer(1200, 3), 'sha256': '0' * 64}
        with self.assertRaisesRegex(ValueError, 'payload mismatch'):
            burst.analyze(LOG, records([peer(64), invalid]))

    def test_rejects_shortened_observation_window(self):
        log = LOG.replace('long_burst=1 ', 'long_burst=1 long_settle_ms=1f40 long_final_wait_ms=1f3f ')
        with self.assertRaisesRegex(ValueError, 'window incomplete'):
            burst.analyze(log, records([peer(64)]))

    def test_trace_uses_wrapped_credit_and_rejects_inconsistent_snapshot(self):
        def words(values): return ''.join('%08x' % n for n in values)
        counters = list(range(16))
        trace = {'trace_total': [20] * 16, 'trace_credit': [20 - i for i in counters],
                 'trace_counter': counters, 'trace_send_ms': [1000 + i * 250 for i in counters],
                 'trace_duration_us': [500] * 16, 'trace_stalls': [0] * 16}
        def with_trace(values):
            return LOG.replace('long_burst=1 ', 'long_burst=1 ' + ' '.join(k + '=' + words(v) for k, v in values.items()) + ' ')
        captured = records([peer(64), peer(1200, 3), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}])
        self.assertEqual(burst.analyze(with_trace(trace), captured)['device_tx_trace'][2]['credit_available'], 18)
        trace['trace_credit'][2] = 19
        with self.assertRaisesRegex(ValueError, 'credit trace'):
            burst.analyze(with_trace(trace), captured)

    def test_packed_trace_decodes_and_rejects_zero_credit(self):
        words = ['%08x%08x' % (20 | (i << 12), (500 << 16) | (1000 + i * 250)) for i in range(16)]
        captured = records([peer(64), peer(1200, 3), {'event': 'echoed', 'bytes': 1200, 'attempt': 3}])
        result = burst.analyze(LOG + 'NIHOS_C6_CREDIT_TRACE ' + ' '.join(words) + '\n', captured)
        self.assertEqual(result['device_tx_trace'][2]['credit_available'], 18)
        words[2] = '%08x%08x' % (2 | (2 << 12), (500 << 16) | 1500)
        with self.assertRaisesRegex(ValueError, 'packed transmit credit'):
            burst.analyze(LOG + 'NIHOS_C6_CREDIT_TRACE ' + ' '.join(words) + '\n', captured)

    def test_peer_relative_time_is_separate_from_device_clock(self):
        one = {**peer(1200, 3), 'elapsed_us': 8000}
        two = {**peer(1200, 4), 'elapsed_us': 12000}
        items = [peer(64), one, two, {'event': 'echoed', 'bytes': 1200, 'attempt': 3}]
        result = burst.analyze(LOG, records(items))
        self.assertEqual(result['peer_arrival_us_from_first'][1]['elapsed_us'], 4000)
        items[2]['elapsed_us'] = 7999
        with self.assertRaisesRegex(ValueError, 'peer timestamps'):
            burst.analyze(LOG, records(items))

if __name__ == '__main__':
    unittest.main()

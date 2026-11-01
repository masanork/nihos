import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('check', Path(__file__).with_name('check-hosted-long-udp-log.py'))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
payload = bytearray(i % 256 for i in range(1200))
payload[:8] = b'NIHOSUDP'
LOG = ('ESP-ROM:esp32p4\nNIHOS_C6_BOOT backend=zig\nNIHOS_C6_LONG_DMA build=diagnostic data=1\n'
       'NIHOS_NATIVE_C6 status=00000001 stage=0000000c error_code=00000000 cleanup_failed=00000000 '
       'fw_known=00000001 fw_major=00000001 fw_minor=00000004 fw_patch=00000001 '
       'short_sent=00000076 '
       'long_logical=000004e6 long_wire=00000600 long_sent=000004e6 long_dma_state=00000000 '
       'long_hash=01234567 ip=c0000201\nNIHOS_C6_HOSTED_WIFI_PASS ip=192.0.2.1\n')
PEER = {'event': 'received', 'source_ip': '192.0.2.1', 'source_port': 44444, 'bytes': 1200,
        'payload_matches': True, 'sha256': hashlib.sha256(payload).hexdigest()}
SHORT = dict(PEER, bytes=64, sha256=hashlib.sha256(payload[:64]).hexdigest())
def records(short=SHORT, long=PEER):
    return json.dumps(short) + '\n' + json.dumps(long)


class CorrelationTests(unittest.TestCase):
    def test_matched(self):
        self.assertIn('1200', checker.check(LOG, records())['payload_sha256_by_bytes'])

    def test_rejects_incomplete_transfer_and_reboot(self):
        for altered in (LOG.replace('long_sent=000004e6', 'long_sent=00000000'),
                        LOG.replace('fw_patch=00000001', 'fw_patch=00000002'), LOG + LOG):
            with self.assertRaises(ValueError):
                checker.check(altered, records())

    def test_rejects_wrong_peer_and_payload(self):
        for change in ({'source_ip': '192.0.2.2'}, {'sha256': '0' * 64}, {'payload_matches': False}):
            with self.assertRaises(ValueError):
                checker.check(LOG, records(long={**PEER, **change}))

    def test_echo_requires_peer_sends_and_device_confirmation(self):
        log = LOG.replace('short_sent=00000076 ', 'short_sent=00000076 short_echo=00000001 long_echo=00000001 long_attempts=00000003 ')
        peer = records() + '\n' + json.dumps({'event': 'echoed', 'bytes': 64}) + '\n' + json.dumps({'event': 'echoed', 'bytes': 1200})
        self.assertEqual(checker.check_echo(log, peer)['long_attempts'], 3)
        with self.assertRaises(ValueError):
            checker.check_echo(log.replace('long_echo=00000001', 'long_echo=00000000'), peer)
        with self.assertRaises(ValueError):
            checker.check_echo(log, records())

    def test_attempt_mask_must_match_received_attempt(self):
        log = LOG.replace('short_sent=00000076 ', 'short_sent=00000076 short_echo=00000001 long_echo=00000001 long_attempts=00000003 long_echo_mask=00000004 ')
        tagged = bytearray(payload)
        tagged[8] = 3
        long = {**PEER, 'attempt': 3, 'sha256': hashlib.sha256(tagged).hexdigest()}
        peer = records(long=long) + '\n' + json.dumps({'event': 'echoed', 'bytes': 64}) + '\n' + json.dumps({'event': 'echoed', 'bytes': 1200})
        self.assertEqual(checker.check_echo(log, peer)['peer_attempts'], [3])
        with self.assertRaises(ValueError):
            checker.check_echo(log.replace('long_echo_mask=00000004', 'long_echo_mask=00000001'), peer)


if __name__ == '__main__':
    unittest.main()

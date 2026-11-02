import hashlib
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('split_burst', Path(__file__).with_name('analyze-hosted3-split-udp-burst.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def capture(mask=5):
    values = dict(status=1, stage=12, error_code=0, peer_chip=13, fw_known=1, fw_major=3,
                  fw_minor=0, fw_patch=10, long_sent=1254, long_attempts=16, long_burst=1,
                  long_echo=2, long_echo_mask=mask, long_final_wait_ms=8000, ip=0xc0000201)
    return ('NIHOS_NATIVE_C6 ' + ' '.join(f'{k}={v:08x}' for k, v in values.items()) +
            '\nNIHOS_C6_HOSTED_WIFI_PASS ip=private\n').encode()


def peer():
    out = []
    for attempt in (1, 3):
        data = bytearray(i % 256 for i in range(1200))
        data[:8] = b'NIHOSUDP'
        data[8] = attempt
        out += [{'event': 'received', 'attempt': attempt, 'source_ip': '192.0.2.1', 'source_port': 49152,
                 'bytes': 1200, 'payload_matches': True, 'sha256': hashlib.sha256(data).hexdigest()},
                {'event': 'echoed', 'attempt': attempt, 'bytes': 1200}]
    return out


class BurstEvidence(unittest.TestCase):
    def test_paired_counts_and_mask(self):
        result = module.analyze(capture(), peer())
        self.assertEqual((result['sent_count'], result['peer_received_mask'], result['p4_echo_mask']), (16, 5, 5))
        self.assertNotIn('192.0.2.1', str(result))

    def test_rejects_unobserved_echo_and_bad_payload(self):
        with self.assertRaises(ValueError):
            module.analyze(capture(7), peer())
        bad = peer()
        bad[0]['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            module.analyze(capture(), bad)

    def test_rejects_short_wait_and_bad_destination_port(self):
        short = capture().replace(b'long_final_wait_ms=00001f40', b'long_final_wait_ms=00001f3f')
        with self.assertRaises(ValueError):
            module.analyze(short, peer())
        wrong_port = peer()
        wrong_port[0]['source_port'] = 44444
        with self.assertRaises(ValueError):
            module.analyze(capture(), wrong_port)

    def test_rejects_incomplete_or_uncorrelated_peer(self):
        with self.assertRaises(ValueError):
            module.analyze(capture(), peer()[:-1])
        with self.assertRaises(ValueError):
            module.analyze(capture() + b'NIHOS_C6_TRAP\n', peer())


if __name__ == '__main__':
    unittest.main()

import unittest
from c6_hosted3_preflight_evidence import InvalidEvidence, analyze
from c6_hosted3_upgrade_evidence import CANDIDATE_SHA

BOOT = b'NIHOS_C6_MAP_BOOT\n'
MAP = f'NIHOS_C6_MAP_RESULT bytes=00155170 sha256={CANDIDATE_SHA}\n'.encode()
ORIGIN = b'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000002 minor=0000000d patch=00000001\n'
READY = b'NIHOS_C6_OTA_READY\n'


class PreflightEvidenceTest(unittest.TestCase):
    def test_pre_token_capture(self):
        result = analyze(BOOT + MAP + ORIGIN + READY)
        self.assertEqual(result['candidate_bytes'], 1_397_104)
        self.assertIn('no OTA', result['meaning'])

    def test_missing_duplicate_wrong_origin_and_update_fail(self):
        for capture in (
            BOOT + MAP + ORIGIN,
            BOOT + MAP + ORIGIN + READY + READY,
            BOOT + ORIGIN + MAP + READY,
            BOOT + MAP.replace(CANDIDATE_SHA.encode(), b'0' * 64) + ORIGIN + READY,
            BOOT + MAP + ORIGIN.replace(b'minor=0000000d', b'minor=00000004') + READY,
            BOOT + MAP + ORIGIN + READY + b'NIHOS_C6_OTA_PROGRESS\n',
            BOOT + MAP + ORIGIN + READY + b'NIHOS_C6_OTA_SIMULATED\n',
            BOOT + MAP + ORIGIN + READY + b'NIHOS_C6_MAP_TRAP cause=00000001\n',
        ):
            with self.subTest(capture=capture), self.assertRaises(InvalidEvidence):
                analyze(capture)


if __name__ == '__main__':
    unittest.main()

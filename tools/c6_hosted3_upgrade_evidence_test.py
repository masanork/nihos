import unittest
from c6_hosted3_upgrade_evidence import CANDIDATE_SHA, InvalidEvidence, analyze

TOKEN = ('OTA1 ' + CANDIDATE_SHA + '\n').encode('ascii')
CAPTURE = (f'NIHOS_C6_MAP_BOOT\n'
           f'NIHOS_C6_MAP_RESULT bytes=00155170 sha256={CANDIDATE_SHA}\n'
           f'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000002 minor=0000000d patch=00000001\n'
           f'NIHOS_C6_OTA_READY\n'
           f'NIHOS_C6_OTA_RESULT status=00000001 stage=00000008 error_code=00000000 acknowledged_bytes=00155170\n'
           f'NIHOS_C6_OTA_POST status=00000001 stage=00000006 error_code=00000000 peer_chip=0000000d version_known=00000001 major=00000003 minor=00000000 patch=0000000a\n'
           f'NIHOS_C6_OTA_TARGET_VERSION_OK\n').encode('ascii')


class Hosted3UpgradeEvidenceTest(unittest.TestCase):
    def test_synthetic_success(self):
        self.assertEqual(analyze(CAPTURE, TOKEN)['acknowledged_bytes'], 1_397_104)

    def test_simulation_partial_wrong_version_and_bad_order_fail(self):
        for data in (
            CAPTURE + b'NIHOS_C6_OTA_SIMULATED\n',
            CAPTURE.replace(b'acknowledged_bytes=00155170', b'acknowledged_bytes=0015516f'),
            CAPTURE.replace(b'major=00000003 minor=00000000 patch=0000000a', b'major=00000002 minor=0000000d patch=00000001'),
            CAPTURE.replace(b'NIHOS_C6_OTA_TARGET_VERSION_OK\n', b''),
            CAPTURE + b'NIHOS_C6_OTA_TARGET_VERSION_OK\n',
            CAPTURE + b'NIHOS_C6_MAP_TRAP cause=00000001\n',
            CAPTURE.replace(b'NIHOS_C6_OTA_READY\n', b'NIHOS_C6_OTA_READY\nNIHOS_C6_MAP_BOOT\n'),
        ):
            with self.subTest(data=data), self.assertRaises(InvalidEvidence):
                analyze(data, TOKEN)
        with self.assertRaises(InvalidEvidence):
            analyze(CAPTURE, b'wrong token\n')


if __name__ == '__main__':
    unittest.main()

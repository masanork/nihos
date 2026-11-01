import unittest
from c6_ota_evidence import InvalidEvidence
from c6_ota_recovery_evidence import analyze, CANDIDATE_SHA, ORIGIN
TOKEN = ('OTA1 ' + CANDIDATE_SHA + '\n').encode()
def trace():
    return ('NIHOS_C6_MAP_BOOT\n'
            f'NIHOS_C6_MAP_RESULT bytes=00107750 sha256={CANDIDATE_SHA}\n'
            f'{ORIGIN}\nNIHOS_C6_OTA_READY\n'
            'NIHOS_C6_OTA_RESULT status=00000001 stage=00000008 error_code=00000000 acknowledged_bytes=00107750\n'
            'NIHOS_C6_OTA_POST status=00000001 stage=00000006 error_code=00000000 peer_chip=0000000d version_known=00000001 major=00000001 minor=00000004 patch=00000001 diag_known=00000001 diag_uptime=00000001 diag_heap=0003db70\n').encode()
class RecoveryEvidenceTests(unittest.TestCase):
    def test_valid_trace(self):
        self.assertEqual(analyze(trace(), TOKEN, CANDIDATE_SHA)['acknowledged_bytes'], 1_079_120)
    def test_rejects_wrong_origin_and_simulation(self):
        for content in (trace().replace(ORIGIN.encode(), b'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000001 minor=00000004 patch=00000001'), trace() + b'NIHOS_C6_OTA_SIMULATED\n', trace().replace(b'diag_known=00000001', b'diag_known=00000000')):
            with self.assertRaises(InvalidEvidence): analyze(content, TOKEN, CANDIDATE_SHA)
if __name__ == '__main__': unittest.main()

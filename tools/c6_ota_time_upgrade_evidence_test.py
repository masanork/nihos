import unittest
from c6_ota_evidence import InvalidEvidence
from c6_ota_time_upgrade_evidence import analyze, CANDIDATE_SHA, CANDIDATE_BYTES

TOKEN = ('OTA1 ' + CANDIDATE_SHA + '\n').encode()
def good():
    return ('NIHOS_C6_MAP_BOOT\n'
            f'NIHOS_C6_MAP_RESULT bytes={CANDIDATE_BYTES:08x} sha256={CANDIDATE_SHA}\n'
            'NIHOS_C6_OTA_ORIGIN chip=0000000d major=00000001 minor=00000004 patch=00000001\n'
            'NIHOS_C6_OTA_READY\n'
            f'NIHOS_C6_OTA_RESULT status=00000001 stage=00000008 error_code=00000000 acknowledged_bytes={CANDIDATE_BYTES:08x}\n'
            'NIHOS_C6_OTA_POST status=00000001 stage=00000006 error_code=00000000 peer_chip=0000000d version_known=00000001 major=00000002 minor=0000000d patch=00000001\n'
            'NIHOS_C6_OTA_TARGET_VERSION_OK\n').encode()

class EvidenceTests(unittest.TestCase):
    def test_accepts_only_correlated_fixture_trace(self):
        self.assertEqual(analyze(good(), TOKEN, CANDIDATE_SHA)['acknowledged_bytes'], CANDIDATE_BYTES)
    def test_rejects_simulated_and_wrong_post_version(self):
        for trace in (good().replace(b'chip=0000000d major=00000001', b'chip=0000000d major=00000002'), good() + b'NIHOS_C6_OTA_SIMULATED\n', good().replace(b'minor=0000000d', b'minor=00000004'), good().replace(b'NIHOS_C6_OTA_TARGET_VERSION_OK', b'NIHOS_C6_OTA_TARGET_VERSION_FAIL')):
            with self.assertRaises(InvalidEvidence): analyze(trace, TOKEN, CANDIDATE_SHA)
    def test_rejects_token_count_order_and_duplicates(self):
        for trace, token in ((good(), b'bad'), (good().replace(b'acknowledged_bytes=00138060', b'acknowledged_bytes=00000001'), TOKEN), (good() + b'NIHOS_C6_OTA_READY\n', TOKEN), (b'NIHOS_C6_OTA_TARGET_VERSION_OK\n' + good().replace(b'NIHOS_C6_OTA_TARGET_VERSION_OK\n', b''), TOKEN)):
            with self.assertRaises(InvalidEvidence): analyze(trace, token, CANDIDATE_SHA)

if __name__ == '__main__': unittest.main()

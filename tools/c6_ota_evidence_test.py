import unittest
from c6_ota_evidence import analyze, InvalidEvidence

SHA = 'ab' * 32
TOKEN = ('OTA1 ' + SHA + '\n').encode()
def good():
    return ('NIHOS_C6_MAP_BOOT\r\n'
            f'NIHOS_C6_MAP_RESULT bytes=00107750 sha256={SHA}\r\n'
            'NIHOS_C6_OTA_READY\r\n'
            'NIHOS_C6_OTA_PROGRESS\r\n'
            'NIHOS_C6_OTA_RESULT status=00000001 stage=00000008 error_code=00000000 acknowledged_bytes=00107750\r\n'
            'NIHOS_C6_OTA_POST status=00000001 stage=00000006 last_command=00000035 last_interrupts=0000001c error_code=00000000 peer_chip=0000000d version_known=00000001 major=00000001 minor=00000004 patch=00000001 diag_known=00000001 diag_uptime=00000005 diag_heap=00012345\r\n').encode()

class EvidenceTest(unittest.TestCase):
    def test_success_is_only_p4_reported(self):
        result = analyze(good(), SHA, TOKEN)
        self.assertEqual(result['acknowledged_bytes'], 1_079_120)
        self.assertIn('no C6 flash readback', result['meaning'])
    def test_wrong_or_ambiguous_evidence_is_rejected(self):
        examples = [
            (good(), b'\n'),
            (good().replace(b'acknowledged_bytes=00107750', b'acknowledged_bytes=00100000'), TOKEN),
            (good().replace(b'diag_known=00000001', b'diag_known=00000000'), TOKEN),
            (good().replace(b'diag_heap=00012345', b'diag_heap=00000000'), TOKEN),
            (good() + b'NIHOS_C6_MAP_BOOT\r\n', TOKEN),
            (good() + b'NIHOS_C6_OTA_ERROR Timeout\r\n', TOKEN),
            (good().replace(b'NIHOS_C6_OTA_READY\r\n', b''), TOKEN),
            (good().replace(b'status=00000001 stage=00000008', b'status=00000001 status=00000001 stage=00000008'), TOKEN),
        ]
        for capture, token in examples:
            with self.subTest(capture=capture[-120:]):
                with self.assertRaises(InvalidEvidence):
                    analyze(capture, SHA, token)

if __name__ == '__main__':
    unittest.main()

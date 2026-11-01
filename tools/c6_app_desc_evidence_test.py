import hashlib
import struct
import unittest

from c6_app_desc_evidence import InvalidEvidence, analyze


def image():
    data = bytearray(288)
    data[0] = 0xe9
    struct.pack_into('<H', data, 12, 13)
    struct.pack_into('<I', data, 32, 0xabcd5432)
    data[48:55] = b'2.13.1\0'
    data[80:96] = b'network_adapter\0'
    data[144:151] = b'v5.5.2\0'
    return bytes(data)


BOOT = b'NIHOS_C6_BOOT backend=zig-sram rtos=none cpu1=parked\n'
DESC = b'NIHOS_C6_APP_DESC version=322e31332e31 project=6e6574776f726b5f61646170746572 idf=76352e352e32 elf_sha256=-\n'
REPORT = (b'NIHOS_C6_OTA_INFO status=00000000 stage=00000005 peer_chip=0000000d '
          b'fw_known=00000001 major=00000002 minor=0000000d patch=00000001 '
          b'desc_known=00000001 ack_known=00000001 ack_status=00000105 result_known=00000000\n')


class DescriptionEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.binary = image()
        self.digest = hashlib.sha256(self.binary).hexdigest()

    def test_matching_self_report_is_accepted(self):
        result = analyze(BOOT + DESC + REPORT, self.binary, self.digest)
        self.assertEqual(result['metadata']['idf'], 'v5.5.2')
        self.assertIn('no C6 flash identity', result['meaning'])

    def test_incomplete_duplicate_and_wrong_values_fail(self):
        for capture in (
            BOOT + REPORT,
            BOOT + DESC + DESC + REPORT,
            BOOT + REPORT + DESC,
            BOOT + DESC.replace(b'76352e352e32', b'76352e352e33') + REPORT,
            BOOT + DESC + REPORT.replace(b'ack_status=00000105', b'ack_status=00000000'),
            BOOT + DESC + REPORT.replace(b'result_known=00000000', b'result_known=00000001'),
            BOOT + DESC.replace(b'elf_sha256=-', b'elf_sha256=00') + REPORT,
            BOOT + DESC + REPORT + b'NIHOS_C6_TRAP cause=00000001\n',
        ):
            with self.subTest(capture=capture), self.assertRaises(InvalidEvidence):
                analyze(capture, self.binary, self.digest)

    def test_wrong_candidate_and_digest_fail(self):
        with self.assertRaises(InvalidEvidence):
            analyze(BOOT + DESC + REPORT, self.binary, '0' * 64)
        other = bytearray(self.binary)
        other[12] = 0
        with self.assertRaises(InvalidEvidence):
            analyze(BOOT + DESC + REPORT, bytes(other), hashlib.sha256(other).hexdigest())


if __name__ == '__main__':
    unittest.main()

import unittest
from c6_ota_evidence import InvalidEvidence
from c6_time_evidence import analyze

def sample():
    return (b'NIHOS_C6_TIME status=00000001 stage=00000006 error_code=00000000 '
            b'peer_chip=0000000d fw_known=00000001 major=00000002 minor=0000000d patch=00000001 '
            b'station_connected=00000001 split_address_known=00000001 acknowledged=00000001 '
            b'got_result=00000001 synced=00000001 last_rpc_id=00000314 last_rpc_kind=00000003 '
            b'seconds_low=6ae7260d seconds_high=00000000 age_seconds=00000000 attempts=00000019\n')
class TimeEvidenceTests(unittest.TestCase):
    def test_valid_snapshot(self):
        result = analyze(sample(), 1793533461, 60)
        self.assertEqual(result['unix_seconds'], 1793533453)
        self.assertEqual(result['reference_skew_seconds'], 8)
    def test_reject_failure_missing_sync_and_wrong_version(self):
        for data in (sample() + b'NIHOS_C6_TIME_ERROR Timeout\n', sample().replace(b'synced=00000001', b'synced=00000000'), sample().replace(b'minor=0000000d', b'minor=00000004'), sample() + sample()):
            with self.assertRaises(InvalidEvidence): analyze(data, 1793533461, 60)
    def test_reject_stale_time(self):
        with self.assertRaises(InvalidEvidence): analyze(sample(), 1793534461, 60)
if __name__ == '__main__': unittest.main()

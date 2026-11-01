import unittest
import c6_time_fault_evidence as evidence

GOOD = b'''NIHOS_NATIVE_NETWORK ip=00000001 reconnects=00000000 failures=00000000 acquisitions=00000001
NIHOS_NATIVE_NETWORK_UI frames=00000001 ticks0=00000001 ticks1=00000001
NIHOS_NATIVE_C6_TIME_FAULT stage=00000002 dropped=00000002 expired=00000001
NIHOS_NATIVE_BLE phase=00000004 status=00000000 timeouts=00000000
NIHOS_NATIVE_NETWORK_UI frames=00000001 ticks0=00000001 ticks1=00000001
NIHOS_NATIVE_NTP attempts=00000002 failures=00000001 replies=00000001 unix_high=00000000 unix_low=6ae732d4
NIHOS_NATIVE_RTC_SYNC applied=00000001 failures=00000000 error_code=00000000 unix_high=00000000 unix_low=6ae732d4
NIHOS_NATIVE_NETWORK ip=00000001 reconnects=00000000 failures=00000000 acquisitions=00000001
NIHOS_NATIVE_BLE phase=00000004 status=00000000 timeouts=00000000
NIHOS_NATIVE_DEVICES rtc_present=00000001 rtc_valid=00000001 rtc_error=00000000 year=000007ea month=0000000b day=00000001 hour=0000000c minute=00000026 second=00000031
NIHOS_NATIVE_DEVICES rtc_present=00000001 rtc_valid=00000001 rtc_error=00000000 year=000007ea month=0000000b day=00000001 hour=0000000c minute=00000026 second=00000036
NIHOS_NATIVE_NETWORK_UI frames=00000002 ticks0=00000002 ticks1=00000002
'''

class FaultEvidenceTests(unittest.TestCase):
    def test_complete_capture(self):
        self.assertEqual(evidence.check(GOOD)['time_replies'], 1)

    def test_partial_or_unrelated_success_rejected(self):
        for capture in (GOOD.replace(b'dropped=00000002', b'dropped=00000000'),
                        GOOD.replace(b'failures=00000001 replies', b'failures=00000000 replies'),
                        GOOD.replace(b'reconnects=00000000', b'reconnects=00000001'),
                        GOOD[:GOOD.rfind(b'ip=00000001')] + GOOD[GOOD.rfind(b'ip=00000001'):].replace(b'ip=00000001', b'ip=00000000', 1),
                        GOOD.replace(b'ticks1=00000002', b'ticks1=00000001'),
                        GOOD.replace(b'unix_low=6ae732d4', b'unix_low=00000000', 1),
                        GOOD.replace(b'expired=00000001', b'expired=00000000'),
                        GOOD.replace(b'second=00000036', b'second=00000031'),
                        GOOD.replace(b'NIHOS_NATIVE_BLE phase=00000004', b'NIHOS_NATIVE_BLE phase=00000003', 1),
                        GOOD + b'NIHOS_NATIVE_TRAP fault=00000001\n'):
            with self.assertRaises(ValueError):
                evidence.check(capture)

if __name__ == '__main__':
    unittest.main()

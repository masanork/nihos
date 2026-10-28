"""Clock evidence must prove correlated UTC application and continuing RTC/UI."""
import datetime
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('native_time', Path(__file__).with_name('check-native-time.py'))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
STAMP = 1793158278


def record(marker, **values):
    return marker + ' ' + ' '.join(key + '={:08x}'.format(value) for key, value in values.items()) + '\n'


def device(stamp, valid=1):
    date = datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc)
    return record('NIHOS_NATIVE_DEVICES', rtc_present=1, rtc_valid=valid, rtc_error=0 if valid else 3,
                  rtc_flags=0x25, year=date.year, month=date.month, day=date.day,
                  hour=date.hour, minute=date.minute, second=date.second, errors=0)


def log(mode='sync'):
    result = 'ESP-ROM:esp32p4\n'
    for index in range(3):
        result += record('NIHOS_NATIVE_NETWORK_UI', frames=100+index, ticks0=200+index, ticks1=200+index)
        result += device(STAMP+index*5, 1 if mode == 'retention' or index else 0)
        if mode != 'retention':
            ready = int(index > 0 and mode == 'sync')
            result += record('NIHOS_NATIVE_NETWORK', acquisitions=ready, ip=0xc0000201 if ready else 0)
            result += record('NIHOS_NATIVE_NTP', phase=1, attempts=ready, replies=ready, rejected=0, failures=0,
                             stratum=ready, rtt_us=10000 if ready else 0, unix_high=0, unix_low=STAMP if ready else 0)
            result += record('NIHOS_NATIVE_RTC_SYNC', applied=ready, failures=0, error_code=0,
                             unix_high=0, unix_low=STAMP if ready else 0)
    return result


def recovered_log():
    result = 'ESP-ROM:esp32p4\n'
    for index, (phase, attempts, replies, failures) in enumerate(((0,0,0,0),(4,1,0,0),(1,1,0,1),(1,2,1,1),(1,2,1,1))):
        result += record('NIHOS_NATIVE_NETWORK_UI', frames=100+index, ticks0=200+index, ticks1=200+index)
        result += device(STAMP+index*5)
        result += record('NIHOS_NATIVE_NETWORK', acquisitions=1, ip=0xc0000201)
        result += record('NIHOS_NATIVE_NTP', phase=phase, attempts=attempts, replies=replies, rejected=0,
                         failures=failures, stratum=replies, rtt_us=10000 if replies else 0,
                         unix_high=0, unix_low=STAMP if replies else 0)
        result += record('NIHOS_NATIVE_RTC_SYNC', applied=replies, failures=0, error_code=0,
                         unix_high=0, unix_low=STAMP if replies else 0)
    return result


class NativeTimeTests(unittest.TestCase):
    def test_recovery_is_explicit_and_retains_exactly_one_failed_request(self):
        result = CHECK.check(recovered_log(), 'recovered-sync')
        self.assertEqual(result['ntp']['attempts'], 2)
        self.assertEqual(result['ntp']['failures'], 1)
        with self.assertRaises(ValueError):
            CHECK.check(recovered_log())
        with self.assertRaises(ValueError):
            CHECK.check(log(), 'recovered-sync')

    def test_recovery_rejects_hidden_failure_extra_attempt_missing_wait_and_early_write(self):
        original = recovered_log()
        for changed in (original.replace('attempts=00000002', 'attempts=00000003'),
                        original.replace('replies=00000001 rejected=00000000 failures=00000001',
                                         'replies=00000001 rejected=00000000 failures=00000000'),
                        original.replace('phase=00000004', 'phase=00000001'),
                        original.replace('applied=00000000', 'applied=00000001', 1),
                        original.replace('rtc_error=00000000', 'rtc_error=00000003')):
            with self.assertRaises(ValueError):
                CHECK.check(changed, 'recovered-sync')

    def test_sync_and_no_network_retention_are_distinct(self):
        result = CHECK.check(log())
        self.assertEqual(result['rtc_written_unix'], STAMP)
        self.assertEqual(CHECK.check(log('retention'), 'retention')['rtc_last_unix'], STAMP+10)
        self.assertEqual(CHECK.check(log('unavailable'), 'unavailable')['rtc_applied'], 0)
        with self.assertRaises(ValueError):
            CHECK.check(log('unavailable'))

    def test_rejects_mixed_boot_packet_failures_no_lease_and_clock_write_failure(self):
        original = log()
        for changed in (original + 'ESP-ROM:esp32p4', original + 'NIHOS_NATIVE_TRAP',
                        original.replace('stratum=00000001', 'stratum=00000010'),
                        original.replace('rejected=00000000', 'rejected=00000001', 1),
                        original.replace('acquisitions=00000001', 'acquisitions=00000000'),
                        original.replace('applied=00000001', 'applied=00000000'),
                        original.replace('rtc_error=00000000', 'rtc_error=00000003')):
            with self.assertRaises(ValueError):
                CHECK.check(changed)

    def test_rejects_wrong_date_voltage_loss_nonadvancing_rtc_and_stopped_core(self):
        original = log()
        for changed in (original.replace('year=000007ea', 'year=000007eb'),
                        original.replace('rtc_flags=00000025', 'rtc_flags=00000027'),
                        original.replace(device(STAMP+10), device(STAMP+5)),
                        original.replace('ticks1=000000ca', 'ticks1=000000c8')):
            with self.assertRaises(ValueError):
                CHECK.check(changed)

    def test_no_network_or_retention_control_cannot_hide_clock_activity(self):
        with self.assertRaises(ValueError):
            CHECK.check(log('unavailable').replace('applied=00000000', 'applied=00000001', 1), 'unavailable')
        with self.assertRaises(ValueError):
            CHECK.check(log('retention') + record('NIHOS_NATIVE_NTP', attempts=0), 'retention')


if __name__ == '__main__':
    unittest.main()

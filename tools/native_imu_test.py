import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('imu_check', Path(__file__).with_name('check-native-imu.py'))
IMU = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMU)


def record(count, **changes):
    values = dict(chip=0x24, initialized=1, stage=12, fault=0, uploaded=8192, valid=1,
                  samples=count, acc_x=-100, acc_y=0, acc_z=8190, gyr_x=0, gyr_y=-2,
                  gyr_z=3, sensor_error=0, ready_status=0xc0)
    values.update(changes)
    return 'NIHOS_NATIVE_IMU ' + ' '.join(f'{name}={values[name] & 0xffffffff:08x}' for name in IMU.FIELDS) + '\n'


class CheckerTests(unittest.TestCase):
    def test_accepts_fresh_signed_gravity_readings(self):
        log = 'ESP-ROM:esp32p4\n' + ''.join(record(n) for n in (1, 11, 21))
        self.assertEqual(IMU.check(log)['first']['acc_x'], -100)
        self.assertEqual(IMU.check(log)['sample_delta'], 20)

    def test_rejects_fault_incomplete_upload_stale_counts_and_zero_data(self):
        for changes in ({'fault': 1}, {'uploaded': 8160}, {'samples': 1}, {'valid': 0},
                        {'initialized': 0}, {'ready_status': 0x80}, {'sensor_error': 1},
                        {'acc_z': 0}, {'gyr_x': 0x10000}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                IMU.check('ESP-ROM:esp32p4\n' + record(1) + record(11, **changes) + record(21))

    def test_rejects_malformed_or_mixed_boot_and_missing_records(self):
        log = 'ESP-ROM:esp32p4\n' + ''.join(record(n) for n in (1, 11, 21))
        for candidate in (log + 'ESP-ROM:esp32p4', log + 'NIHOS_NATIVE_FAIL reason',
                          log.replace('gyr_x=', 'gyro_x='), log[:log.index('NIHOS_NATIVE_IMU')]):
            with self.assertRaises(ValueError):
                IMU.check(candidate)


if __name__ == '__main__':
    unittest.main()

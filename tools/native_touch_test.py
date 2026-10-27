"""Reject incomplete or contradictory PIN-free touch/colour receipts."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('native_touch', Path(__file__).with_name('check-native-touch-log.py'))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def record(tag, fields, values):
    return tag + ''.join(f' {key}={value:08x}' for key, value in zip(fields, values)) + '\n'


def complete():
    log = record('NIHOS_NATIVE_TOUCH_START', CHECK.START, (0, 720, 1280, 10, 1))
    for x, y, color in [(100, 100, 0xf800), (600, 100, 0x07e0), (100, 1000, 0x001f), (600, 1000, 0xffe0)]:
        log += record('NIHOS_NATIVE_TOUCH_EVENT', CHECK.EVENT, (1, x, y, color, 0))
    log += record('NIHOS_NATIVE_TOUCH_EVENT', CHECK.EVENT, (0, 600, 1000, 0x1082, 1))
    log += record('NIHOS_NATIVE_TOUCH_CHECK', CHECK.FIELDS, (1, 0, 720, 1280, 10, 20, 10, 1, 15, 0, 1, 6, 0, 1, 64))
    return log


class TouchTests(unittest.TestCase):
    def test_full_trace_correlates_quadrants_colors_releases_and_frame_progress(self):
        result = CHECK.check_touch(complete())
        self.assertEqual(result['report']['quadrants'], 15)
        self.assertEqual(len(result['events']), 5)

    def test_false_pin_mode_geometry_no_release_and_wrong_color_are_rejected(self):
        log = complete()
        for old, new in [('pin_enabled=00000000', 'pin_enabled=00000001'),
                         ('x=00000064', 'x=000002d0'), ('color=0000f800', 'color=000007e0'),
                         ('max_contacts=00000001', 'max_contacts=00000000'),
                         ('inferred_releases=00000001', 'inferred_releases=00000000'),
                         ('quadrants=0000000f', 'quadrants=00000007'),
                         ('frames=00000040', 'frames=00000001'), ('vbus_off=00000001', 'vbus_off=00000000')]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                CHECK.check_touch(log.replace(old, new))
        with self.assertRaises(ValueError):
            CHECK.check_touch(log + log)

    def test_traffic_after_checkpoint_does_not_corrupt_its_correlated_counts(self):
        extra = record('NIHOS_NATIVE_TOUCH_EVENT', CHECK.EVENT, (1, 100, 100, 0xf800, 0))
        self.assertEqual(len(CHECK.check_touch(complete() + extra)['events']), 5)


if __name__ == '__main__':
    unittest.main()

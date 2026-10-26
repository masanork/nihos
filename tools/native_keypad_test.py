"""Count-only keypad trace regressions; no actual key values are fixtures."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('keypad_check', Path(__file__).with_name('check-native-keypad-log.py'))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def record(tag, names, values):
    return tag + ''.join(f' {name}={value:08x}' for name, value in zip(names, values)) + '\n'


def complete():
    log = record('NIHOS_NATIVE_KEYPAD_START', ('pin_enabled', 'vbus_off'), (0, 1))
    for effect, count in [(1, 1), (1, 2), (1, 3), (1, 4), (2, 3), (1, 4), (4, 0), (1, 1), (1, 2), (3, 0)]:
        log += record('NIHOS_NATIVE_KEYPAD_EVENT', ('effect', 'count'), (effect, count))
    return log + record('NIHOS_NATIVE_KEYPAD_CHECK', CHECK.FIELDS, (1, 0, 1, 100, 7, 1, 1, 1, 2, 10, 0, 31, 0, 1000))


class KeypadTests(unittest.TestCase):
    def test_count_transitions_correlate_with_operations(self):
        self.assertEqual(CHECK.check_keypad(complete())['report']['confirms'], 1)

    def test_incomplete_rendering_false_counts_pin_mode_and_duplicate_receipts_fail(self):
        log = complete()
        for old, new in [('pin_enabled=00000000', 'pin_enabled=00000001'),
                         ('shown_mask=0000001f', 'shown_mask=0000000f'),
                         ('erases=00000001', 'erases=00000002'),
                         ('effect=00000002 count=00000003', 'effect=00000002 count=00000004'),
                         ('vbus_off=00000001', 'vbus_off=00000000')]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                CHECK.check_keypad(log.replace(old, new))
        with self.assertRaises(ValueError):
            CHECK.check_keypad(log + log)

    def test_post_checkpoint_input_does_not_change_checkpoint_counts(self):
        self.assertEqual(len(CHECK.check_keypad(complete() + record('NIHOS_NATIVE_KEYPAD_EVENT', ('effect', 'count'), (1, 1)))['events']), 10)


if __name__ == '__main__':
    unittest.main()

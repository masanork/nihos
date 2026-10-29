import unittest

from capture_canvas_fixture import restore_spans, with_restoration


class CanvasCaptureTests(unittest.TestCase):
    def test_restoration_runs_after_success_partial_write_and_interrupt(self):
        for failure in (None, RuntimeError('partial write'), KeyboardInterrupt()):
            events = []
            def operation():
                events.append('install')
                if failure is not None:
                    raise failure
                events.append('capture')
            def restore():
                events.extend(('restore', 'verify'))
            if failure is None:
                with_restoration(operation, restore)
            else:
                with self.assertRaises(type(failure)):
                    with_restoration(operation, restore)
            self.assertEqual(events[-2:], ['restore', 'verify'])

    def test_restore_failure_is_not_reported_as_success(self):
        events = []
        def restore():
            events.append('restore')
            raise RuntimeError('verify failed')
        with self.assertRaisesRegex(RuntimeError, 'verify failed'):
            with_restoration(lambda: events.append('install'), restore)
        self.assertEqual(events, ['install', 'restore'])

    def test_restores_exact_erased_regions_and_rejects_wrong_table(self):
        raw = bytearray(16 * 1024 * 1024)
        raw[0x2000:0x8000] = b'L' * 0x6000
        raw[0x8000:0x8004] = b'tabl'
        raw[0x10000:0x13000] = b'A' * 0x3000
        loader, app = restore_spans(raw, 0x2000, 0x2001, b'tabl')
        self.assertEqual(loader, b'L' * 0x6000)
        self.assertEqual(app, b'A' * 0x3000)
        for bad in (b'', b'bad!', b'x' * 0x1001):
            with self.subTest(partition=bad[:4]), self.assertRaises(ValueError):
                restore_spans(raw, 0x2000, 0x2001, bad)
        for size in (0, 0x100001):
            with self.subTest(size=size), self.assertRaises(ValueError):
                restore_spans(raw, 0x2000, size, b'tabl')
        with self.assertRaises(ValueError):
            restore_spans(raw[:-1], 0x2000, 0x2001, b'tabl')


if __name__ == '__main__':
    unittest.main()

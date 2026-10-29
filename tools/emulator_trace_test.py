import copy
import unittest
import emulator_trace as trace


class TraceTest(unittest.TestCase):
    def setUp(self):
        self.trace = {'schema': trace.TRACE_SCHEMA, 'name': 'test', 'samples': [
            {'contacts': 1, 'x': 10, 'y': 20, 'time_us': 30}]}
        self.report = {'schema': trace.REPORT_SCHEMA, 'evidence': 'esp32p4-emulator-rv32',
                       'trace': self.trace, 'trace_sha256': trace.validate_trace(self.trace),
                       'frames': [{'samples': i, 'events': i, 'clicks': 0, 'kind': i, 'pixel_sha256': 'a' * 64}
                                  for i in range(2)],
                       'identity': {name: 'b' * 64 for name in ('image_sha256', 'elf_sha256', 'flash_sha256', 'source_sha256')}}

    def test_detects_pixel_and_event_changes(self):
        self.assertEqual(trace.compare(self.report, copy.deepcopy(self.report)), 2)
        for field, value in (('pixel_sha256', 'c' * 64), ('clicks', 1), ('kind', 2)):
            changed = copy.deepcopy(self.report)
            changed['frames'][1][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'frame 1 differs'):
                trace.compare(self.report, changed)

    def test_rejects_incomplete_or_incompatible_reports(self):
        for change in ('trace', 'frames', 'evidence', 'identity'):
            bad = copy.deepcopy(self.report)
            if change == 'trace': bad['trace']['samples'][0]['x'] += 1
            if change == 'frames': bad['frames'].pop()
            if change == 'evidence': bad['evidence'] = 'physical'
            if change == 'identity': bad['identity']['elf_sha256'] = 'invalid'
            with self.subTest(change=change), self.assertRaises(ValueError): trace.validate_report(bad)

    def test_rejects_invalid_samples(self):
        for field, value in (('x', 720), ('y', -1), ('contacts', True), ('time_us', 0x100000000)):
            bad = copy.deepcopy(self.trace)
            bad['samples'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): trace.validate_trace(bad)
        bad = copy.deepcopy(self.trace)
        bad['samples'].append({**bad['samples'][0], 'time_us': 29})
        with self.assertRaises(ValueError): trace.validate_trace(bad)

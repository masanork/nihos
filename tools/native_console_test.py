"""Validate physical read-only snapshot evidence without claiming keyboard support."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('display_console', ROOT / 'tools/check-native-display-log.py')
DISPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DISPLAY)
LOG = (ROOT / 'docs/measurements/2026-10-27-native-console-initial.log').read_text()
IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-console-initial.json').read_text())['image_audit']

class NativeConsoleEvidenceTests(unittest.TestCase):
    def check(self, log=LOG):
        return DISPLAY.check(log, IMAGE, 2, 80, require_console=True)

    def test_real_snapshot_and_unavailable_input(self):
        report = self.check()
        self.assertEqual(report['console']['log_bytes'], 2048)
        self.assertEqual(report['console']['input'], 0)
        self.assertEqual(report['console']['rows'], 43)

    def test_missing_duplicate_or_reordered_snapshot_is_rejected(self):
        line = next(line for line in LOG.splitlines() if line.startswith('NIHOS_NATIVE_CONSOLE '))
        for changed in (LOG.replace(line, ''), LOG + line + '\n', line + '\n' + LOG.replace(line, '')):
            with self.subTest(), self.assertRaises(ValueError):
                self.check(changed)

    def test_truncated_capture_wrong_geometry_and_unimplemented_input_are_rejected(self):
        for old, new in (('columns=0000004e', 'columns=0000004d'), ('rows=0000002b', 'rows=0000002a'),
                         ('log_bytes=00000800', 'log_bytes=00000000'), ('input=00000000', 'input=00000001')):
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check(LOG.replace(old, new))

    def test_actual_size_raster_requires_matching_style(self):
        tall = LOG.replace('rows=0000002b', 'rows=00000016').replace('columns=0000004e', 'columns=00000050')
        with self.assertRaises(ValueError):
            self.check(tall)
        style = ('NIHOS_NATIVE_CONSOLE_STYLE cell_width=0000000f cell_height=0000001e palette=00000001 '
                 'foreground=0000a5f5 accent=000085b5 background=00001082 font=00000001\n')
        self.assertEqual(self.check(tall + style)['console_style']['cell_height'], 30)
        with self.assertRaises(ValueError):
            self.check(tall + style.replace('cell_height=0000001e', 'cell_height=00000010'))


CURRENT_LOG = (ROOT / 'docs/measurements/2026-10-27-native-console.log').read_text()
CURRENT_IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-console.json').read_text())['image_audit']

class NativeCurrentConsoleTests(unittest.TestCase):
    def test_real_eighty_column_green_font(self):
        result = DISPLAY.check(CURRENT_LOG, CURRENT_IMAGE, 2, 80, require_console=True)
        self.assertEqual(result['console']['columns'], 80)
        self.assertEqual(result['console']['rows'], 22)
        self.assertEqual(result['console_style']['font'], 1)
        self.assertEqual(result['console_style']['palette'], 1)

    def test_font_size_palette_and_cell_readback_must_agree(self):
        for old, new in (('font=00000001', 'font=00000000'), ('cell_width=0000000f', 'cell_width=00000010'),
                         ('cell_height=0000001e', 'cell_height=00000018'), ('foreground=0000a5f5', 'foreground=0000ffff'),
                         ('palette=00000001', 'palette=00000002'), ('accent=000085b5', 'accent=00000000')):
            self.assertIn(old, CURRENT_LOG)
            with self.subTest(old=old), self.assertRaises(ValueError):
                DISPLAY.check(CURRENT_LOG.replace(old, new), CURRENT_IMAGE, 2, 80, require_console=True)

if __name__ == '__main__':
    unittest.main()

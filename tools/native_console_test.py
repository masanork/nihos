"""Validate static/live device records; optical and real keys remain separate."""
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


LIVE_LOG = (ROOT / 'docs/measurements/2026-10-27-native-console-live.log').read_text()
LIVE_IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-console-live.json').read_text())['image_audit']

class NativeLiveConsoleTests(unittest.TestCase):
    def check(self, log=LIVE_LOG):
        return DISPLAY.check(log, LIVE_IMAGE, 2, 80, require_console=True, require_live_controls=True)

    def test_live_core_run_and_all_serial_controls(self):
        live = self.check()['live']
        self.assertEqual(live['ready']['target'], 255)
        self.assertGreater(live['resumes'][0]['frames'], live['pauses'][0]['frames'])
        self.assertFalse(live['keyboard_escape_seen'])

    def test_single_field_records_keep_the_entire_hex_number(self):
        self.assertEqual(DISPLAY.NATIVE.fixed_record('TEST frames=00000542\n', 'TEST', ('frames',)), {'frames': 0x542})
        with self.assertRaises(ValueError):
            self.check(LIVE_LOG.replace('tx_dropped=00000000', 'tx_dropped=00000001'))

    def test_missing_records_or_invented_input_are_rejected(self):
        for marker in ('NIHOS_NATIVE_UI_START ', 'NIHOS_NATIVE_UI_READY ', 'NIHOS_NATIVE_UI_SETTLED ',
                       'NIHOS_NATIVE_UI_PAUSE ', 'NIHOS_NATIVE_UI_RESUME ', 'NIHOS_NATIVE_KEYBOARD '):
            line = next(line for line in LIVE_LOG.splitlines() if line.startswith(marker))
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                self.check(LIVE_LOG.replace(line, ''))

    def test_bad_key_source_usage_and_acceptance_are_rejected(self):
        for old, new in (('usage=0000001b', 'usage=00000029'), ('source=00000001 action=', 'source=00000004 action='),
                         ('accepted=00000001 view=', 'accepted=00000000 view='), ('clock_hz=000f4240', 'clock_hz=00000000'),
                         ('target=000000ff', 'target=000000fe'), ('input=00000001', 'input=00000000'),
                         ('last_stage=00000005', 'last_stage=00000000')):
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check(LIVE_LOG.replace(old, new))

    def test_a_late_snapshot_cannot_masquerade_as_live_boot(self):
        line = next(line for line in LIVE_LOG.splitlines() if line.startswith('NIHOS_NATIVE_UI_START '))
        with self.assertRaises(ValueError):
            self.check(LIVE_LOG.replace(line + '\n', '') + line + '\n')

    def test_injected_failure_remains_inspectable_without_resuming(self):
        log = (ROOT / 'docs/measurements/2026-10-27-native-console-live-fault.log').read_text()
        self.assertIn('NIHOS_NATIVE_UI_FAILURE visible=1 scheduler=stopped', log)
        keys = DISPLAY.NATIVE.repeated_records(log, 'NIHOS_NATIVE_DIAGNOSTIC_KEY', DISPLAY.KEY)
        self.assertEqual([key['action'] for key in keys], [1, 2, 4, 3])
        self.assertEqual([key['accepted'] for key in keys], [1, 0, 0, 0])
        self.assertTrue(all(key['view'] == 1 for key in keys))
        self.assertGreater(keys[-1]['frames'], keys[0]['frames'])
        with self.assertRaises(ValueError):
            self.check(log)

    def test_failed_hardware_attempts_cannot_count_as_success(self):
        for name in ('live-01', 'live-02'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.check((ROOT / f'docs/measurements/2026-10-27-native-console-{name}-failed.log').read_text())

SCROLL_LOG = (ROOT / 'docs/measurements/2026-10-27-native-console-scroll.log').read_text()
SCROLL_IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-console-scroll.json').read_text())['image_audit']

class NativeScrollConsoleTests(unittest.TestCase):
    def check(self, log=SCROLL_LOG):
        return DISPLAY.check(log, SCROLL_IMAGE, 2, 80, require_console=True, require_live_controls=True)

    def test_small_font_and_incremental_scroll_on_device(self):
        report = self.check()
        self.assertEqual((report['console']['columns'],report['console']['rows']),(78,43))
        self.assertEqual(report['console_style']['font'],3)
        stats = report['live']['render']
        self.assertEqual(stats['full'],2) # entering details twice before READY
        self.assertGreater(stats['partial'],stats['full'])
        self.assertGreater(stats['scrolls'],0)
        self.assertLessEqual(stats['steps'],stats['scrolls']*4)

    def test_missing_render_geometry_and_unbounded_irq_interval_are_rejected(self):
        for old,new in (('font=00000003','font=00000001'),('cell_height=00000010','cell_height=0000001e'),
                        ('partial=00000022','partial=00000000'),('cache_chunk_us=0000001d','cache_chunk_us=00001000'),
                        ('line_step_us=00024649','line_step_us=ffffffff')):
            self.assertIn(old,SCROLL_LOG)
            with self.subTest(old=old), self.assertRaises(ValueError): self.check(SCROLL_LOG.replace(old,new))

    def test_retained_physical_escape_can_open_details_before_ui_start(self):
        log = (ROOT / 'docs/measurements/2026-10-27-native-console-scroll-profile-01.log').read_text()
        screen = DISPLAY.NATIVE.fixed_record(log,'NIHOS_NATIVE_DISPLAY_SCANOUT',DISPLAY.SCANOUT)
        result = DISPLAY.check_live(log,screen,True)
        self.assertTrue(result['keyboard_escape_seen'])
        self.assertEqual(result['start']['view'],1)

    def test_startup_details_without_an_input_event_is_rejected(self):
        line = next(line for line in SCROLL_LOG.splitlines() if line.startswith('NIHOS_NATIVE_UI_START '))
        with self.assertRaises(ValueError): self.check(SCROLL_LOG.replace(line,line.replace('view=00000000','view=00000001')))

MATRIX_LOG = (ROOT / 'docs/measurements/2026-10-27-native-console-matrix.log').read_text()
MATRIX_IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-console-matrix.json').read_text())['image_audit']

class NativeMatrixConsoleTests(unittest.TestCase):
    def check(self, log=MATRIX_LOG):
        return DISPLAY.check(log,MATRIX_IMAGE,2,80,require_console=True,require_live_controls=True)

    def test_single_pass_matrix_device_run_and_cpu_estimate(self):
        report = self.check()
        self.assertEqual(report['console_style']['foreground'],0x07e8)
        stats = report['live']['render']
        self.assertEqual(stats['scrolls'],stats['steps'])
        self.assertEqual(stats['cpu_mhz'],90)

    def test_old_animation_count_wrong_colour_and_zero_clock_are_rejected(self):
        for old,new in (('steps=00000020','steps=00000080'),('foreground=000007e8','foreground=00005dcf'),
                        ('cpu_mhz=0000005a','cpu_mhz=00000000')):
            self.assertIn(old,MATRIX_LOG)
            with self.subTest(old=old),self.assertRaises(ValueError):self.check(MATRIX_LOG.replace(old,new))

if __name__ == '__main__':
    unittest.main()

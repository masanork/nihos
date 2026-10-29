"""Reject partial or misleading display evidence using a physical SRAM fixture."""
import importlib.util
import json
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('display_log', ROOT / 'tools/check-native-display-log.py')
DISPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DISPLAY)
LOG = (ROOT / 'docs/measurements/2026-10-26-native-sram-scanout.log').read_text()
IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-26-native-sram-scanout.json').read_text())['image_audit']


class NativeDisplayEvidenceTests(unittest.TestCase):
    def check(self, log=LOG, image=IMAGE):
        return DISPLAY.check(log, image, 5, 80)

    def test_physical_fixture_with_exact_reservation_and_refresh(self):
        report = self.check()
        self.assertEqual(report['refresh']['frames'], 32)
        self.assertEqual(report['native']['external_memory'][0]['start'], 0x48200000)
        self.assertEqual(report['optical_evidence'], 'not evaluated by this checker')

    def test_panel_only_preparation_requires_full_runtime_scanout_evidence(self):
        original = next(line for line in LOG.splitlines() if line.startswith('NIHOS_NATIVE_DISPLAY_PREP '))
        panel_only = original
        for key, value in (('stage', 3), ('checksum', 0), ('phy_trim', 0), ('phy_status', 0)):
            panel_only = re.sub(' ' + key + r'=[0-9a-f]{8}', ' {}={:08x}'.format(key, value), panel_only)
        log = LOG.replace(original, panel_only)
        self.check(log)
        # It cannot masquerade as a successful stand-alone PHY probe.
        with self.assertRaises(ValueError):
            DISPLAY.NATIVE.check_display_preparation(log)
        for key in ('checksum', 'phy_trim', 'phy_status'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(log.replace(key + '=00000000', key + '=00000001', 1))
        for marker in ('NIHOS_NATIVE_DISPLAY_SCANOUT ', 'NIHOS_NATIVE_DISPLAY_IRQ_PASS '):
            incomplete = '\n'.join(line for line in log.splitlines() if not line.startswith(marker))
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                self.check(incomplete)

    def test_default_and_unknown_reservations_do_not_accept_display_heap(self):
        for reserved in (3 * 65536, 0, 0x200040, 1 << 20):
            with self.subTest(reserved=reserved), self.assertRaises(ValueError):
                DISPLAY.NATIVE.check(LOG, 'integer', 32 << 20, IMAGE, 'physical-device', external_reserved_bytes=reserved)

    def test_display_reservation_requires_matching_preparation(self):
        for old, new in (('reserve_bytes=001d0000', 'reserve_bytes=001c0000'),
                         ('frame_bytes=001c2000', 'frame_bytes=001c1fff'),
                         ('frame_start=48030000', 'frame_start=48200000')):
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check(LOG.replace(old, new))

    def test_missing_duplicate_and_malformed_irq_reports_fail(self):
        line = next(line for line in LOG.splitlines() if line.startswith('NIHOS_NATIVE_DISPLAY_IRQ_PASS '))
        for changed in (LOG.replace(line, ''), LOG + line + '\n', LOG.replace(line, 'NIHOS_NATIVE_DISPLAY_IRQ_PASS malformed')):
            with self.subTest(changed=changed[-100:]), self.assertRaises(ValueError):
                self.check(changed)

    def test_late_fault_and_partial_startup_are_rejected(self):
        for old, new in (('frames=00000020', 'frames=0000001f'), ('fault=00000000', 'fault=00000001'),
                         ('commands=00000022', 'commands=00000021'), ('dpi_mhz=00000050', 'dpi_mhz=0000000a'),
                         ('backlight=00000001', 'backlight=00000000')):
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check(LOG.replace(old, new))
        with self.assertRaises(ValueError):
            self.check(LOG + 'NIHOS_NATIVE_DISPLAY_IRQ_FAIL\n')

    def test_wrong_source_and_nonfixed_dma_are_rejected(self):
        for old, new in (('sram=00000001', 'sram=00000000'), ('word=ffffffff', 'word=00000000'),
                         ('dma_control=001c1b51', 'dma_control=001c1b41'),
                         ('source=4ff16040', 'source=48030000')):
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check(LOG.replace(old, new))

    def test_reboot_and_emulator_audit_do_not_qualify_physical_display(self):
        with self.assertRaises(ValueError):
            self.check(LOG + 'NIHOS_NATIVE_BOOT backend=zig-sram rtos=none\n')
        with self.assertRaises(ValueError):
            self.check(image={**IMAGE, 'memory': {**IMAGE['memory'], 'profile': 'emulator'}})


FAST_LOG = (ROOT / 'docs/measurements/2026-10-27-native-landscape.log').read_text()
FAST_IMAGE = json.loads((ROOT / 'docs/measurements/2026-10-27-native-landscape.json').read_text())['image_audit']


class NativeFastDisplayEvidenceTests(unittest.TestCase):
    def check(self, log=FAST_LOG):
        return DISPLAY.check(log, FAST_IMAGE, 2, 80)

    def test_real_200mhz_landscape_fixture(self):
        result = self.check()
        self.assertEqual(result['native']['psram_fast']['mpll']['mhz'], 400)
        self.assertEqual(result['layout']['logical_width'], 1280)
        self.assertEqual(result['timing']['refresh_millihz'], 59982)
        self.assertEqual(result['optical_evidence'], 'not evaluated by this checker')

    def test_missing_or_duplicate_timing_evidence(self):
        for marker in ('PSRAM_TUNING', 'PSRAM_MPLL', 'PSRAM_LINK', 'DISPLAY_TIMING', 'PSRAM_SWEEP'):
            line = next(line for line in FAST_LOG.splitlines() if line.startswith('NIHOS_NATIVE_' + marker + ' '))
            for changed in (FAST_LOG.replace(line, ''), FAST_LOG + line + '\n'):
                with self.subTest(marker=marker), self.assertRaises(ValueError):
                    self.check(changed)

    def test_incomplete_calibration_wrong_clock_and_wrong_geometry(self):
        for old, new in (('mhz=00000190', 'mhz=000000f0'), ('divider=00000099', 'divider=00000098'),
                         ('reused=00000001', 'reused=00000002'), ('delay=00000011', 'delay=00000012'),
                         ('phase_mask=0000000f', 'phase_mask=00000000'), ('delay_mask=3fffffc0', 'delay_mask=00020000'),
                         ('repetitions=00000064', 'repetitions=00000063'), ('reads=00018440', 'reads=0001843f'),
                         ('bus=00010001', 'bus=00020002'), ('command=00010001', 'command=00130013'),
                         ('mr8=0000004b', 'mr8=0000000b'), ('ddr=00003023', 'ddr=00003021'),
                         ('dll_cache=00000021', 'dll_cache=00000001'), ('dqs0=00010001', 'dqs0=00010003'),
                         ('refresh_millihz=0000ea4e', 'refresh_millihz=0000ffff'),
                         ('vtotal=0000067f', 'vtotal=0000067e'), ('rotation=00000001', 'rotation=00000003'),
                         ('transactions=0001853e', 'transactions=00000071')):
            self.assertIn(old, FAST_LOG)
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check(FAST_LOG.replace(old, new))

    def test_canvas_fixture_requires_portrait_and_checksum_receipt(self):
        old = 'NIHOS_NATIVE_DISPLAY_LAYOUT logical_width=00000500 logical_height=000002d0 rotation=00000001'
        new = ('NIHOS_NATIVE_DISPLAY_LAYOUT logical_width=000002d0 logical_height=00000500 rotation=00000000\n'
               'NIHOS_NATIVE_CANVAS_PATTERN checksum=549e3481 frames=0000005a')
        self.assertIn(old, FAST_LOG)
        log = FAST_LOG.replace(old, new)
        report = DISPLAY.check(log, FAST_IMAGE, 2, 80, canvas_demo=True)
        self.assertEqual(report['canvas']['checksum'], 0x549e3481)
        self.assertEqual(report['optical_evidence'], 'not evaluated by this checker')
        for changed in (log.replace('checksum=549e3481', 'checksum=549e3480'),
                        log.replace('checksum=549e3481 frames=0000005a', 'checksum=549e3481 frames=00000059'),
                        log.replace('NIHOS_NATIVE_CANVAS_PATTERN checksum=549e3481 frames=0000005a\n', ''),
                        log + 'NIHOS_NATIVE_CANVAS_PATTERN checksum=549e3481 frames=0000005a\n',
                        log.replace('NIHOS_NATIVE_CANVAS_PATTERN checksum=549e3481 frames=0000005a\n', '') + 'NIHOS_NATIVE_CANVAS_PATTERN checksum=549e3481 frames=0000005a\n',
                        log.replace('rotation=00000000', 'rotation=00000001')):
            with self.subTest(changed=changed[-100:]), self.assertRaises(ValueError):
                DISPLAY.check(changed, FAST_IMAGE, 2, 80, canvas_demo=True)
        with self.assertRaises(ValueError):
            DISPLAY.check(log, FAST_IMAGE, 2, 80)


CARD_EVIDENCE = ROOT / 'docs/measurements/evidence/2026-10-28-card-foreground-startup'
CARD_LOG = (CARD_EVIDENCE / 'fixed-boot.log').read_text()
CARD_IMAGE = json.loads((CARD_EVIDENCE / 'fixed-image-audit.json').read_text())


class NativeCardStartupEvidenceTests(unittest.TestCase):
    def test_physical_probe_startup_accepts_auxiliary_boot_and_portrait(self):
        report = DISPLAY.check(CARD_LOG, CARD_IMAGE, 11, 80)
        self.assertEqual(report['layout'], dict(logical_width=720, logical_height=1280, rotation=0))
        self.assertEqual(report['refresh']['frames'], 32)
        self.assertEqual(report['optical_evidence'], 'not evaluated by this checker')

    def test_card_probe_rejects_wrong_layout_or_foreign_boot(self):
        for old, new in (('rotation=00000000', 'rotation=00000001'),
                         ('logical_width=000002d0', 'logical_width=00000500'),
                         ('NIHOS_NATIVE_CARD_AUTO_BOOT ', 'NIHOS_C6_BOOT ')):
            self.assertIn(old, CARD_LOG)
            with self.subTest(old=old), self.assertRaises(ValueError):
                DISPLAY.check(CARD_LOG.replace(old, new), CARD_IMAGE, 11, 80)


if __name__ == '__main__':
    unittest.main()

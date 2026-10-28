"""Count-only keypad trace regressions; no actual key values are fixtures."""
import importlib.util
import hashlib
import json
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
    def test_shipped_ui_manifests_match_current_sources_and_payloads(self):
        root = Path(__file__).resolve().parents[1]
        payloads = {
            'keypad_atlas': {'plan_sha256': 'keypad_atlas_plan.bin', 'atlas_sha256': 'keypad_atlas.bin'},
            'card_read_font': {'font_sha256': 'card_read_font.bin'},
            'card_auto_font': {'font_sha256': 'card_auto_font.bin', 'font_raw_sha256': 'card_read_font.bin'},
        }
        for name, fields in payloads.items():
            manifest = json.loads((root / 'src/graphics' / (name + '.json')).read_text())
            self.assertTrue({'src/platform/native/main.zig', 'src/platform/native/memory.zig',
                             'src/platform/native/esp32p4.ld'} <= manifest['sources'].keys())
            for source, expected in manifest['sources'].items():
                with self.subTest(manifest=name, source=source):
                    self.assertEqual(hashlib.sha256((root / source).read_bytes()).hexdigest(), expected)
            for field, filename in fields.items():
                with self.subTest(manifest=name, payload=filename):
                    self.assertEqual(hashlib.sha256((root / 'src/graphics' / filename).read_bytes()).hexdigest(), manifest[field])

    def test_relocated_display_leases_must_stay_inside_base_free_domains(self):
        low = 0x4ff48000
        lease = {'nodes': 100, 'lease_start': low + 0x1000, 'lease_bytes': 6400}
        font = lease['lease_start'] + lease['lease_bytes']
        storage = {'font_low': font, 'font_low_bytes': low + 96 * 1024 - font, 'pixel_bytes': 10000}
        memory = {'pool0_start': low, 'pool0_bytes': 96 * 1024, 'pool1_start': 0x4ff82000, 'pool1_bytes': 116 * 1024}
        audit = {'allocation': 'base-free-sram-v1', 'writable': False, 'executable': False,
                 'ui_mode': 'runtime', 'font_bytes': 357358,
                 'pools': [{'name': 'service.free0', 'origin': hex(low), 'end': '0x4ff60000'},
                           {'name': 'service.free1', 'origin': '0x4ff80000', 'end': '0x4ff9f000'}]}
        CHECK.DISPLAY.check_keypad_storage(lease, storage, audit, True, memory)
        for bad in (None, {**memory, 'pool0_start': low - 64},
                    {**memory, 'pool1_start': 0x4ff78000},
                    {**memory, 'pool1_bytes': 200 * 1024},
                    {**memory, 'pool1_start': low, 'pool1_bytes': 4096}):
            with self.subTest(memory=bad), self.assertRaises(ValueError):
                CHECK.DISPLAY.check_keypad_storage(lease, storage, audit, True, bad)

    def test_sram_receipt_matches_audited_banks_and_descriptor_bounds(self):
        lease = {'nodes': 637, 'lease_start': 0x4ff46c80, 'lease_bytes': 637 * 64}
        font_low = lease['lease_start'] + lease['lease_bytes']
        storage = {'font_low': font_low, 'font_low_bytes': 0x4ff60000 - font_low, 'pixel_bytes': 216600}
        audit = {'nodes': 637, 'atlas_bytes': 203144, 'writable': False, 'executable': False,
                 'pools': [{'name': name, 'origin': hex(start), 'end': hex(end)} for name, start, end in
                           [('.keypad.low', 0x4ff40000, 0x4ff60000), ('.keypad.high', 0x4ff70000, 0x4ff9f000)]]}
        CHECK.DISPLAY.check_keypad_storage(lease, storage, audit)
        for bad_lease, bad_storage, bad_audit in (({**lease, 'nodes': 636}, storage, audit),
                ({**lease, 'lease_start': 0x4ff60000}, storage, audit),
                (lease, {**storage, 'font_low': font_low - 64}, audit),
                (lease, {**storage, 'font_low_bytes': 65536}, audit),
                (lease, storage, {**audit, 'pools': []}),
                (lease, storage, {**audit, 'executable': True})):
            with self.assertRaises(ValueError):
                CHECK.DISPLAY.check_keypad_storage(bad_lease, bad_storage, bad_audit)

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

"""Reject resets, blackouts and card activity in the card-free scene exercise."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('scene_check', Path(__file__).with_name('check-native-scene-log.py'))
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)


def record(tag, fields, values):
    return 'NIHOS_NATIVE_' + tag + ''.join(f' {k}={v:08x}' for k, v in zip(fields, values)) + '\n'


def fixture():
    display = ('swaps', 'panel_starts', 'backlight_offs', 'frames', 'backlight', 'fault')
    result = record('CARD_AUTO_DISPLAY', display, (0, 1, 0, 32, 1, 0))
    for step in range(13):
        if step:
            result += record('CARD_SCENE_PIXELS', ('step', 'mismatches'), (step, 0))
        result += record('CARD_SCENE', ('step',), (step,))
        result += record('CARD_SCENE_HANDOFF', ('updates', 'max_pause_us'), (step, 1000 if step else 0))
        result += record('CARD_AUTO_DISPLAY', display, (0, 1, 0, 32 + step * 100, 1, 0))
    result += record('CARD_SCENE_PIXELS', ('step', 'mismatches'), (13, 0))
    result += record('CARD_SCENE_READY', ('manual',), (1,))
    result += record('CARD_AUTO_DISPLAY', display, (1, 1, 0, 1300, 1, 0))
    return result


class NativeSceneTests(unittest.TestCase):
    def test_boot_handoff_has_its_own_pixel_and_frame_proof(self):
        boot = record('CARD_BOOT', ('stage', 'frames', 'checked', 'mismatches'), (1, 2, 1, 0))
        boot += record('CARD_BOOT', ('stage', 'frames', 'checked', 'mismatches'), (2, 4, 1, 0))
        log = fixture()
        for i in reversed(range(13)):
            log = log.replace(f'updates={i:08x}', f'updates={i + 1:08x}')
        log = log.replace('max_pause_us=00000000', 'max_pause_us=000003e8')
        self.assertEqual(C.check_transitions(boot + log)['handoffs'][-1]['updates'], 13)
        for bad in (boot.replace('checked=00000001', 'checked=00000000'),
                    boot.replace('mismatches=00000000', 'mismatches=00000001'),
                    boot.replace('stage=00000002', 'stage=00000001'),
                    boot.replace('frames=00000004', 'frames=00000002')):
            with self.assertRaises(ValueError):
                C.check_transitions(bad + log)

    def test_exercise_build_refuses_a_read_enabled_profile(self):
        root = Path(__file__).resolve().parents[1]
        env = {**os.environ, 'NIHOS_NATIVE_NETWORK': '0', 'NIHOS_NATIVE_USB': '1',
               'NIHOS_NATIVE_DISPLAY': '11', 'NIHOS_NATIVE_CARD_AUTO_PROBE': '0',
               'NIHOS_NATIVE_CARD_SCENE_EXERCISE': '1'}
        with tempfile.TemporaryDirectory() as temporary:
            run = subprocess.run(['sh', str(root / 'tools/build-native-elf.sh'), 'device', temporary, 'integer'],
                                 cwd=root, env=env, capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('Card scene exercise requires DISPLAY=11 and CARD_AUTO_PROBE=1', run.stderr)

    def test_all_twelve_transitions_preserve_one_panel_start_and_no_blackout(self):
        report = C.check_transitions(fixture())
        self.assertEqual(report['handoffs'][-1]['updates'], 12)
        self.assertEqual(report['optical_evidence'], 'requires separate user observation')

    def test_missing_repeated_wrong_order_and_stalled_transitions_are_rejected(self):
        log = fixture()
        for old, new in (('step=0000000c', 'step=0000000b'),
                         ('updates=0000000c', 'updates=0000000b'),
                         ('frames=000004d0', 'frames=0000046c'),
                         ('max_pause_us=000003e8', 'max_pause_us=00030d40'),
                         ('panel_starts=00000001', 'panel_starts=00000002'),
                         ('backlight_offs=00000000', 'backlight_offs=00000001'),
                         ('backlight=00000001', 'backlight=00000000'),
                         ('fault=00000000', 'fault=00000001')):
            self.assertIn(old, log)
            with self.subTest(old=old), self.assertRaises(ValueError):
                C.check_transitions(log.replace(old, new))
        with self.assertRaises(ValueError):
            C.check_transitions(log.replace('mismatches=00000000', 'mismatches=00000001'))
        with self.assertRaises(ValueError):
            C.check_transitions(log + record('CARD_SCENE', ('step',), (12,)))

    def test_real_card_or_input_events_cannot_qualify_a_card_free_exercise(self):
        for marker in ('CARD_AUTO_DETECTED', 'CARD_AUTO_PROMPT', 'CARD_AUTO_RESULT', 'KEYPAD_EVENT', 'TOUCH_EVENT', 'JPKI'):
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                C.check_transitions(fixture() + 'NIHOS_NATIVE_' + marker + ' unexpected\n')
        for profile in ({}, {'scene_exercise': True, 'read_enabled': True}, {'scene_exercise': False, 'read_enabled': False}):
            with self.assertRaises(ValueError):
                C.check(fixture(), {'automatic_cards': profile})


if __name__ == '__main__':
    unittest.main()

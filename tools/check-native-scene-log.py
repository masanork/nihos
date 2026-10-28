#!/usr/bin/env python3
"""Check a card-free PIN/result/detail/notice exercise; optical evidence is separate."""
import argparse
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('scene_display', Path(__file__).with_name('check-native-display-log.py'))
DISPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DISPLAY)
NATIVE = DISPLAY.NATIVE


def check_transitions(log):
    log = log.replace('\r', '')
    boot = DISPLAY.check_card_boot(log, True) if 'NIHOS_NATIVE_CARD_BOOT ' in log else None
    offset = 1 if boot else 0
    steps = NATIVE.repeated_records(log, 'NIHOS_NATIVE_CARD_SCENE', ('step',))
    changes = NATIVE.repeated_records(log, 'NIHOS_NATIVE_CARD_SCENE_HANDOFF', ('updates', 'max_pause_us'))
    screens = NATIVE.repeated_records(log, 'NIHOS_NATIVE_CARD_AUTO_DISPLAY', ('swaps', 'panel_starts', 'backlight_offs', 'frames', 'backlight', 'fault'))
    pixels = NATIVE.repeated_records(log, 'NIHOS_NATIVE_CARD_SCENE_PIXELS', ('step', 'mismatches'))
    if [p['step'] for p in pixels] != list(range(1, 14)) or any(p['mismatches'] for p in pixels):
        raise ValueError('missing or mismatched actual DMA pixels')
    ready = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_SCENE_READY', ('manual',))
    if ready['manual'] != 1 or log.index('NIHOS_NATIVE_CARD_SCENE_READY ') < log.index('NIHOS_NATIVE_CARD_SCENE step=0000000c'):
        raise ValueError('missing manual scene screen after exercise')
    if [s['step'] for s in steps] != list(range(13)) or len(changes) != 13 or len(screens) != 15:
        raise ValueError('incomplete scene exercise')
    if any(marker in log for marker in ('NIHOS_NATIVE_CARD_AUTO_DETECTED ', 'NIHOS_NATIVE_CARD_AUTO_SELECTED ',
                                        'NIHOS_NATIVE_CARD_AUTO_PROMPT ', 'NIHOS_NATIVE_CARD_AUTO_RESULT ',
                                        'NIHOS_NATIVE_CARD_AUTO_DONE ', 'NIHOS_NATIVE_CARD_AUTO_ABORT ',
                                        'NIHOS_NATIVE_KEYPAD_EVENT ', 'NIHOS_NATIVE_TOUCH_EVENT ', 'NIHOS_NATIVE_JPKI ')):
        raise ValueError('unexpected card/input activity in card-free exercise')
    previous = 0
    for screen in screens:
        if (screen['panel_starts'] != 1 or screen['backlight_offs'] or screen['backlight'] != 1 or screen['fault'] or
                screen['frames'] < previous):
            raise ValueError('scene reset, blackout, fault or frame counter reset')
        previous = screen['frames']
    for i, change in enumerate(changes):
        if change['updates'] != i + offset or not 0 <= change['max_pause_us'] < 200_000 or ((i or offset) and not change['max_pause_us']):
            raise ValueError('invalid scene handoff progress/timing')
        if i and (change['max_pause_us'] < changes[i - 1]['max_pause_us'] or screens[i + 1]['frames'] <= screens[i]['frames']):
            raise ValueError('scene handoff/frame progress regressed')
        markers = (f'NIHOS_NATIVE_CARD_SCENE step={i:08x}',
                   f'NIHOS_NATIVE_CARD_SCENE_HANDOFF updates={i + offset:08x}')
        if log.index(markers[0]) >= log.index(markers[1]):
            raise ValueError('out-of-order scene evidence')
    return {'steps': steps, 'handoffs': changes, 'screens': screens, 'pixels': pixels,
            'card_operations': 'none in this audited profile', 'optical_evidence': 'requires separate user observation'}


def check(log, image):
    profile = image.get('automatic_cards', {})
    if profile.get('scene_exercise') is not True or profile.get('read_enabled') is not False:
        raise ValueError('audited card-free exercise image required')
    if 'NIHOS_NATIVE_TRAP' in log or 'NIHOS_NATIVE_FAIL' in log:
        raise ValueError('native trap/failure during scene exercise')
    return {'display': DISPLAY.check(log, image, 11, 80), 'exercise': check_transitions(log)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    args.report.write_text(json.dumps(check(args.log.read_text(), json.loads(args.audit.read_text())), indent=2) + '\n')
    print('Card-free scene exercise passed; optical confirmation remains separate')


if __name__ == '__main__':
    main()

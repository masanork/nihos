#!/usr/bin/env python3
"""Validate count-only keypad operations; no coordinates or key values are needed."""
import argparse
import importlib.util
import json
from pathlib import Path


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


NATIVE = module('keypad_native', 'check-native-log.py')
DISPLAY = module('keypad_display', 'check-native-display-log.py')
FIELDS = ('status', 'pin_enabled', 'vbus_off', 'samples', 'increments', 'erases', 'cancels',
          'confirms', 'full', 'updates', 'retries', 'shown_mask', 'errors', 'frames')


def check_keypad(log):
    log = log.replace('\r', '')
    start = NATIVE.fixed_record(log, 'NIHOS_NATIVE_KEYPAD_START', ('pin_enabled', 'vbus_off'))
    report = NATIVE.fixed_record(log, 'NIHOS_NATIVE_KEYPAD_CHECK', FIELDS)
    if start != {'pin_enabled': 0, 'vbus_off': 1}:
        raise ValueError('keypad must disable card transport / PIN input')
    if (report['status'] != 1 or report['errors'] or report['pin_enabled'] or report['vbus_off'] != 1 or
            report['samples'] == 0 or report['frames'] < 32 or report['shown_mask'] != 31 or
            min(report['increments'], report['erases'], report['cancels'], report['confirms'], report['full'], report['updates']) == 0):
        raise ValueError('incomplete keypad interaction or display evidence')
    prefix = log[:log.index('NIHOS_NATIVE_KEYPAD_CHECK ')]
    events = NATIVE.repeated_records(prefix, 'NIHOS_NATIVE_KEYPAD_EVENT', ('effect', 'count'))
    counters = dict(increments=0, erases=0, cancels=0, confirms=0, full=0)
    count = 0
    for event in events:
        effect = event['effect']
        if effect == 1 and count < 4:
            count += 1
            counters['increments'] += 1
            counters['full'] += int(count == 4)
        elif effect == 2 and count > 0:
            count -= 1
            counters['erases'] += 1
        elif effect == 3:
            count = 0
            counters['cancels'] += 1
        elif effect == 4 and count == 4:
            count = 0
            counters['confirms'] += 1
        else:
            raise ValueError('invalid keypad transition')
        if event['count'] != count:
            raise ValueError('keypad count differs from effect')
    if any(report[name] != value for name, value in counters.items()):
        raise ValueError('keypad counters differ from event trace')
    return {'report': report, 'events': events, 'optical_evidence': 'not evaluated by checker'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    log = args.log.read_text()
    result = {'display': DISPLAY.check(log, json.loads(args.audit.read_text()), 8, 80),
              'keypad': check_keypad(log)}
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Native sparse keypad: 0..4 rendered, erase/cancel/confirm passed; optical evidence is separate')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Check PIN-free contact/colour traces; optical confirmation stays separate."""
import argparse
import importlib.util
import json
from pathlib import Path


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


NATIVE = module('native_touch_base', 'check-native-log.py')
DISPLAY = module('native_touch_display', 'check-native-display-log.py')
START = ('pin_enabled', 'width', 'height', 'slots', 'vbus_off')
EVENT = ('contacts', 'x', 'y', 'color', 'inferred_release')
FIELDS = ('status', 'pin_enabled', 'width', 'height', 'slots', 'samples', 'contacts',
          'max_contacts', 'quadrants', 'explicit_releases', 'inferred_releases',
          'updates', 'errors', 'vbus_off', 'frames')


def check_touch(log, require_contacts=True):
    log = log.replace('\r', '')
    start = NATIVE.fixed_record(log, 'NIHOS_NATIVE_TOUCH_START', START)
    end = NATIVE.fixed_record(log, 'NIHOS_NATIVE_TOUCH_CHECK', FIELDS)
    if log.index('NIHOS_NATIVE_TOUCH_START ') > log.index('NIHOS_NATIVE_TOUCH_CHECK '):
        raise ValueError('touch report precedes initialization')
    if (start['pin_enabled'] != 0 or start['width'] != 720 or start['height'] != 1280 or
            not 1 <= start['slots'] <= 10 or start['vbus_off'] != 1 or
            any(end[name] != start[name] for name in START) or
            end['status'] != 1 or end['errors'] != 0 or end['samples'] == 0 or
            end['contacts'] > end['samples'] or end['max_contacts'] > end['slots'] or
            end['quadrants'] > 15 or end['updates'] < 1 or end['frames'] < 32):
        raise ValueError('incomplete touch initialization / display refresh')
    prefix = log[:log.index('NIHOS_NATIVE_TOUCH_CHECK ')]
    events = NATIVE.repeated_records(prefix, 'NIHOS_NATIVE_TOUCH_EVENT', EVENT)
    quadrants = 0
    releases = 0
    contacts = 0
    max_contacts = 0
    for event in events:
        if event['contacts'] > start['slots'] or event['x'] >= 720 or event['y'] >= 1280 or event['inferred_release'] not in (0, 1):
            raise ValueError('invalid touch event')
        if event['contacts']:
            quadrant = int(event['x'] >= 360) | (int(event['y'] >= 640) << 1)
            expected = (0xf800, 0x07e0, 0x001f, 0xffe0)[quadrant]
            quadrants |= 1 << quadrant
            contacts += 1
            max_contacts = max(max_contacts, event['contacts'])
            if event['inferred_release']:
                raise ValueError('contact cannot be a release')
        else:
            expected = 0x1082
            releases += 1
        if event['color'] != expected:
            raise ValueError('touch position and requested colour differ')
    if (quadrants != end['quadrants'] or contacts > end['contacts'] or max_contacts != end['max_contacts'] or
            releases != end['explicit_releases'] + end['inferred_releases'] or
            end['updates'] != len(events) + 1):
        raise ValueError('touch counters differ from the event trace')
    if require_contacts and (quadrants != 15 or contacts < 4 or releases < 1):
        raise ValueError('four quadrants and a release have not been observed')
    return {'report': end, 'events': events, 'contacts_required': require_contacts,
            'optical_evidence': 'not evaluated by this checker',
            'release_note': 'Sitronix idle inference belongs only to this PIN-free experiment'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    log = args.log.read_text()
    result = {'display': DISPLAY.check(log, json.loads(args.audit.read_text()), 6, 80),
              'touch': check_touch(log)}
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('Native display refresh, four touch quadrants and release trace passed; optical evidence is separate')


if __name__ == '__main__':
    main()

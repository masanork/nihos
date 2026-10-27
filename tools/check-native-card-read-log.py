#!/usr/bin/env python3
"""Validate one local read from metadata only; no PIN or attributes are accepted."""
import argparse
import importlib.util
import json
from pathlib import Path

def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
DISPLAY = module('read_display', 'check-native-display-log.py')
NATIVE = DISPLAY.NATIVE
FIELDS = ('status','fault','remaining_before','remaining_after','verifies','cleanup','vbus_off','attributes','preflight_cut')
DONE = FIELDS + ('shown','missing_glyphs','erased')
def check_read(log, photo_required=False):
    log = log.replace('\r','')
    ready = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_READ_READY', ('remaining_before','verifies','preflight_cut'))
    read = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_READ_RESULT', FIELDS)
    done = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_READ_DONE', DONE)
    if (ready['remaining_before'] not in (2,3) or ready['verifies'] != 0 or ready['preflight_cut'] != 1 or
            read != {name: done[name] for name in FIELDS} or read['remaining_before'] != ready['remaining_before'] or
            read['status'] != 1 or read['fault'] or read['remaining_after'] != 255 or read['verifies'] != 1 or
            read['cleanup'] not in (1,2) or read['vbus_off'] != 1 or read['attributes'] != 15 or read['preflight_cut'] != 1 or
            done['shown'] != 15 or done['missing_glyphs'] or done['erased'] != 1):
        raise ValueError('incomplete one-shot read / cleanup / result display / erasure')
    if not log.index('NIHOS_NATIVE_CARD_READ_READY ') < log.index('NIHOS_NATIVE_CARD_READ_RESULT ') < log.index('NIHOS_NATIVE_CARD_READ_DONE '):
        raise ValueError('read lifecycle out of order')
    if any(tag in log for tag in ('NIHOS_NATIVE_KEYPAD_EVENT ', 'NIHOS_NATIVE_JPKI ', 'NIHOS_NATIVE_TOUCH_EVENT ')):
        raise ValueError('unexpected probe/keystroke logging in authenticated mode')
    result = {'ready':ready, 'result':read, 'done':done, 'optical_evidence':'requires separate user observation'}
    if 'NIHOS_NATIVE_CARD_OVERVIEW ' in log:
        overview = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_OVERVIEW', ('shown','truncated','missing_glyphs','photo_enabled','photo_decoded'))
        if overview['shown'] != 15 or overview['truncated'] or overview['missing_glyphs']:
            raise ValueError('overview omitted, truncated or substituted a field')
        result['overview'] = overview
    if photo_required or 'NIHOS_NATIVE_PHOTO_' in log:
        pre = NATIVE.fixed_record(log, 'NIHOS_NATIVE_PHOTO_PREFLIGHT', ('selftest','error_code','stack_used','arena_bytes','surface_sw','surface_counter'))
        start = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_READ_START_TOUCH', ('photo_enabled','preflight_cut'))
        photo = NATIVE.fixed_record(log, 'NIHOS_NATIVE_PHOTO_RESULT', ('photo_enabled','surface_verifies','photo_decoded','photo_error'))
        clear = NATIVE.fixed_record(log, 'NIHOS_NATIVE_PHOTO_CLEANUP', ('decoded','stack_used','erased'))
        if (pre['selftest'] != 1 or pre['error_code'] or pre['arena_bytes'] != 4194176 or
                not 0 < pre['stack_used'] < 12224 or
                not (pre['surface_sw'] == 0x9000 and pre['surface_counter'] == 255 or
                     pre['surface_sw'] == 0x63c0 + pre['surface_counter'] and 2 <= pre['surface_counter'] <= 15) or
                start != {'photo_enabled':1,'preflight_cut':1} or
                photo['photo_enabled'] != 1 or photo['surface_verifies'] not in (0,1) or photo['photo_decoded'] != 1 or photo['photo_error'] or
                clear['decoded'] != 1 or clear['erased'] != 1 or not pre['stack_used'] <= clear['stack_used'] < 12224 or
                result.get('overview') != {'shown':15,'truncated':0,'missing_glyphs':0,'photo_enabled':1,'photo_decoded':1}):
            raise ValueError('incomplete photo preflight / single credential / decode / erasure')
        tags = ('PHOTO_PREFLIGHT', 'CARD_READ_START_TOUCH', 'CARD_READ_READY', 'PHOTO_RESULT', 'CARD_READ_RESULT', 'CARD_OVERVIEW', 'PHOTO_CLEANUP', 'CARD_READ_DONE')
        positions = [log.index('NIHOS_NATIVE_' + tag + ' ') for tag in tags]
        if positions != sorted(positions): raise ValueError('photo lifecycle out of order')
        result['photo'] = {'preflight':pre, 'result':photo, 'cleanup':clear}
        if 'NIHOS_NATIVE_CARD_DISPLAY_TEST ' in log or 'NIHOS_NATIVE_CARD_COUNTERS ' in log:
            smoke = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_DISPLAY_TEST', ('frames','verifies'))
            counters = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CARD_COUNTERS', ('input_remaining','surface_remaining','verifies','surface_verifies'))
            if (smoke['frames'] < 480 or smoke['verifies'] or counters['verifies'] or counters['surface_verifies'] or
                    counters['input_remaining'] != ready['remaining_before'] or counters['surface_remaining'] != pre['surface_counter'] or
                    not log.index('NIHOS_NATIVE_CARD_DISPLAY_TEST ') < log.index('NIHOS_NATIVE_CARD_COUNTERS ') < log.index('NIHOS_NATIVE_CARD_READ_START_TOUCH ')):
                raise ValueError('unsafe display selftest / PIN-free counter checkpoint')
            result['photo'].update(display_test=smoke, counters=counters)
    return result
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path);parser.add_argument('audit',type=Path);parser.add_argument('report',type=Path)
    args=parser.parse_args();log=args.log.read_text()
    image=json.loads(args.audit.read_text())
    photo=bool(image.get('photo_codec'))
    result={'display':DISPLAY.check(log,image,10 if photo else 9,80),'card_read':check_read(log,photo)}
    args.report.write_text(json.dumps(result,indent=2)+'\n')
    print('One local VERIFY, four parsed fields displayed and cleared, DMA/VBUS cleanup passed; values excluded')
if __name__=='__main__': main()

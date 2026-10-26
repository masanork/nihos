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
def check_read(log):
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
    return {'ready':ready, 'result':read, 'done':done, 'optical_evidence':'requires separate user observation'}
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path);parser.add_argument('audit',type=Path);parser.add_argument('report',type=Path)
    args=parser.parse_args();log=args.log.read_text()
    result={'display':DISPLAY.check(log,json.loads(args.audit.read_text()),9,80),'card_read':check_read(log)}
    args.report.write_text(json.dumps(result,indent=2)+'\n')
    print('One local VERIFY, four parsed fields displayed and cleared, DMA/VBUS cleanup passed; values excluded')
if __name__=='__main__': main()

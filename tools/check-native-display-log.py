#!/usr/bin/env python3
"""Validate native core/heap and display evidence; optical confirmation is separate."""
import argparse
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('native_log', Path(__file__).with_name('check-native-log.py'))
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)
SCANOUT = ('status', 'stage', 'error_code', 'panel', 'commands', 'last_command', 'frames', 'fault',
           'event', 'backlight', 'dpi_mhz', 'lane_mbps', 'cleanup', 'dsi_error0', 'dsi_error1',
           'dma_error', 'bridge_error', 'start_code', 'prime_depth', 'bl_latch', 'bl_enable',
           'bl_level', 'bl_mux', 'bl_matrix', 'white')
SOURCE = ('sram', 'source', 'dma_source', 'dma_control', 'word')
REFRESH = ('frames', 'fault', 'event', 'dsi_error0', 'dsi_error1', 'dma_error', 'bridge_error')


def check_keypad_storage(lease, storage, audit):
    pools = {pool['name']: (int(pool['origin'], 16), int(pool['end'], 16)) for pool in audit.get('pools', [])}
    if (pools != {'.keypad.low': (0x4ff40000, 0x4ff60000), '.keypad.high': (0x4ff70000, 0x4ff9f000)} or
            audit.get('writable') is not False or audit.get('executable') is not False):
        raise ValueError('missing audited keypad SRAM pools')
    if (not 1 <= lease['nodes'] <= 1024 or lease['nodes'] != audit.get('nodes') or
            lease['lease_bytes'] != lease['nodes'] * 64 or lease['lease_start'] % 64 or
            not 0x4ff40000 < lease['lease_start'] < storage['font_low'] <= 0x4ff60000 or
            storage['font_low'] != lease['lease_start'] + lease['lease_bytes'] or
            storage['font_low_bytes'] != 0x4ff60000 - storage['font_low'] or
            not audit.get('atlas_bytes', 0) <= storage['pixel_bytes'] < 720 * 1280 * 2 or
            storage['pixel_bytes'] % 8):
        raise ValueError('invalid SRAM sparse keypad plan')


def check(log, image, mode, expected_dpi, psram_bytes=32 << 20):
    if mode not in (2, 3, 4, 5, 6, 7, 8) or expected_dpi not in (10, 60, 80):
        raise ValueError('unknown display mode/timing')
    log = log.replace('\r', '')
    core = NATIVE.check(log, 'integer', psram_bytes, image, 'physical-device')
    if 'NIHOS_NATIVE_DISPLAY_IRQ_FAIL' in log:
        raise ValueError('display refresh failed')
    screen = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_SCANOUT', SCANOUT)
    source = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_SOURCE', SOURCE)
    panel = screen['panel']
    if (screen['status'] != 1 or screen['stage'] != 5 or panel not in (1, 2, 3) or
            screen['commands'] != {1: 205, 2: 31, 3: 34}[panel] or screen['last_command'] != 0x29 or
            screen['frames'] < 2 or screen['backlight'] != 1 or screen['white'] != int(mode in (3, 4, 5)) or
            screen['dpi_mhz'] != expected_dpi or screen['lane_mbps'] != (960 if panel == 3 else 1000) or
            not 768 <= screen['prime_depth'] <= 1024 or
            any(screen[name] for name in ('error_code', 'fault', 'cleanup', 'dsi_error0', 'dsi_error1',
                                         'dma_error', 'bridge_error', 'start_code')) or
            any(screen[name] != 1 for name in ('bl_latch', 'bl_enable', 'bl_level'))):
        raise ValueError('incomplete display startup')
    if source['sram'] != (5 if mode == 8 else 2 if mode == 7 else int(mode in (5, 6))):
        raise ValueError('unexpected display source')
    if mode in (5, 6, 7, 8):
        if (not 0x4ff00000 <= source['source'] < 0x4ff28000 or
                (mode == 5 and source['dma_source'] != source['source']) or
                source['word'] != (0xf7bdf7bd if mode == 8 else 0xffffffff if mode == 5 else 0x10821082) or
                not source['dma_control'] & (1 << 4)):
            raise ValueError('invalid fixed SRAM source')
    elif source['source'] != 0x48030000:
        raise ValueError('invalid PSRAM source')
    lease = None
    if mode in (6, 7):
        lease = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_LEASE', ('lease_start', 'lease_bytes', 'nodes'))
        nodes = 81 if mode == 6 else 353
        owner = core['memory'][0]
        if (lease['nodes'] != nodes or lease['lease_bytes'] != nodes * 64 or lease['lease_start'] % 64 or
                lease['lease_start'] < owner['start'] + owner['used'] or
                lease['lease_start'] + lease['lease_bytes'] > owner['end'] - 64):
            raise ValueError('display descriptor lease crosses owner bounds')
    if mode == 8:
        lease = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_LEASE', ('lease_start', 'lease_bytes', 'nodes'))
        storage = NATIVE.fixed_record(log, 'NIHOS_NATIVE_KEYPAD_STORAGE', ('font_low', 'font_low_bytes', 'pixel_bytes'))
        audit = image.get('keypad_storage', {})
        check_keypad_storage(lease, storage, audit)
        lease['storage'] = storage
    refresh = None
    if mode != 4:
        refresh = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_IRQ_PASS', REFRESH)
        if (refresh['frames'] < 32 or refresh['frames'] <= screen['frames'] or refresh['event'] != 1 or
                any(refresh[name] for name in REFRESH if name not in ('frames', 'event'))):
            raise ValueError('incomplete display IRQ evidence')
    return {'native': core, 'display': screen, 'source': source, 'refresh': refresh,
            'mode': mode, 'lease': lease, 'optical_evidence': 'not evaluated by this checker'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--mode', type=int, required=True)
    parser.add_argument('--dpi', type=int, required=True)
    args = parser.parse_args()
    report = check(args.log.read_text(), json.loads(args.audit.read_text()), args.mode, args.dpi)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Native memory/core and display startup/IRQ evidence passed; optical evidence is separate')


if __name__ == '__main__':
    main()

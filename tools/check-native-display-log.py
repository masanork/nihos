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
UI = ('frames', 'clock_hz', 'sources', 'view', 'progress', 'target')
KEY = ('sequence', 'source', 'action', 'modifiers', 'usage', 'accepted', 'view', 'stage', 'frames')


def check_live(log, screen, exercise=False):
    start = NATIVE.fixed_record(log, 'NIHOS_NATIVE_UI_START', UI)
    ready = NATIVE.fixed_record(log, 'NIHOS_NATIVE_UI_READY', UI)
    keyboard = NATIVE.fixed_record(log, 'NIHOS_NATIVE_KEYBOARD', ('status', 'firmware', 'mode', 'transactions', 'error_code', 'sources'))
    io = NATIVE.fixed_record(log, 'NIHOS_NATIVE_UI_IO', ('tx_dropped',))
    if (start['clock_hz'] != 1_000_000 or ready['clock_hz'] != 1_000_000 or
            start['sources'] not in (1, 3) or ready['sources'] not in (1, 3) or
            keyboard['sources'] != start['sources'] or ready['sources'] & ~start['sources'] or
            not screen['frames'] <= start['frames'] < ready['frames'] or
            start['view'] != 0 or ready['view'] not in (0, 1) or
            not 0 <= start['progress'] <= start['target'] == 85 or
            not 0 <= ready['progress'] <= ready['target'] == 255 or io['tx_dropped']):
        raise ValueError('incomplete live UI/clock/input evidence')
    if keyboard['status'] == 1:
        if (keyboard['sources'] != 3 or keyboard['mode'] != 1 or keyboard['transactions'] < 4 or keyboard['error_code']):
            raise ValueError('incomplete standard keyboard initialization')
    elif keyboard['status'] != 2 or keyboard['sources'] != 1:
        raise ValueError('invalid unavailable keyboard report')
    order = ('NIHOS_NATIVE_DISPLAY_SCANOUT ', 'NIHOS_NATIVE_KEYBOARD ', 'NIHOS_NATIVE_UI_START ',
             'NIHOS_NATIVE_PSRAM_SMP ', 'NIHOS_NATIVE_HEARTBEAT ', 'NIHOS_NATIVE_FP_PASS ',
             'NIHOS_NATIVE_CONSOLE ', 'NIHOS_NATIVE_UI_IO ', 'NIHOS_NATIVE_UI_READY ')
    if [log.index(marker) for marker in order] != sorted(log.index(marker) for marker in order):
        raise ValueError('live display was not active during core qualification')
    keys = NATIVE.repeated_records(log, 'NIHOS_NATIVE_DIAGNOSTIC_KEY', KEY)
    previous = screen['frames']
    for sequence, key in enumerate(keys, 1):
        if (key['sequence'] != sequence or key['source'] not in (1, 2) or key['action'] not in (1, 2, 3, 4) or
                key['accepted'] not in (0, 1) or key['view'] not in (0, 1) or key['stage'] > 8 or
                key['frames'] < previous or key['modifiers'] > 255 or
                (key['accepted'] and key['action'] != 4 and key['view'] != int(key['action'] != 2))):
            raise ValueError('malformed/out-of-order diagnostic key')
        expected = {1: 0x1b, 2: 0x0c, 3: 0x02, 4: 0x12} if key['source'] == 1 else {1: 0x29, 2: 0x0f, 3: 0x05, 4: 0x15}
        if key['usage'] != expected[key['action']] or (key['source'] == 1 and key['modifiers']):
            raise ValueError('key source/usage mismatch')
        if key['source'] == 2 and (keyboard['status'] != 1 or (key['action'] != 1 and (not key['modifiers'] & 0x11 or key['modifiers'] & 0xcc))):
            raise ValueError('unqualified physical keyboard control')
        previous = key['frames']
    pauses = NATIVE.repeated_records(log, 'NIHOS_NATIVE_UI_PAUSE', ('frames', 'last_stage'))
    resumes = NATIVE.repeated_records(log, 'NIHOS_NATIVE_UI_RESUME', ('frames',))
    if len(pauses) != len(resumes) or len(pauses) > 1:
        raise ValueError('unmatched boot pause/resume')
    if pauses and (not 1 <= pauses[0]['last_stage'] <= 8 or
                   not start['frames'] <= pauses[0]['frames'] < resumes[0]['frames'] <= ready['frames'] or
                   log.index('NIHOS_NATIVE_UI_PAUSE ') > log.index('NIHOS_NATIVE_UI_RESUME ')):
        raise ValueError('invalid boot checkpoint pause')
    settled = NATIVE.repeated_records(log, 'NIHOS_NATIVE_UI_SETTLED', ('frames', 'progress', 'target'))
    if len(settled) > 1 or (settled and (settled[0]['frames'] < ready['frames'] or settled[0]['progress'] != 255 or settled[0]['target'] != 255 or
                                      log.index('NIHOS_NATIVE_UI_SETTLED ') < log.index('NIHOS_NATIVE_UI_READY '))):
        raise ValueError('invalid milestone colour completion')
    if exercise:
        serial = [key for key in keys if key['source'] == 1]
        if [key['action'] for key in serial] != [1, 2, 3, 4, 2, 1] or any(not key['accepted'] for key in serial) or not pauses or not settled:
            raise ValueError('incomplete live control exercise')
    return {'start': start, 'ready': ready, 'keyboard': keyboard, 'io': io, 'keys': keys,
            'pauses': pauses, 'resumes': resumes, 'settled': settled,
            'keyboard_escape_seen': any(key['source'] == 2 and key['action'] == 1 and key['accepted'] for key in keys)}


def check(log, image, mode, expected_dpi, psram_bytes=32 << 20, require_console=False, require_live_controls=False):
    if mode not in (2, 3, 4, 5, 6, 7) or expected_dpi not in (10, 60, 80):
        raise ValueError('unknown display mode/timing')
    log = log.replace('\r', '')
    core = NATIVE.check(log, 'integer', psram_bytes, image, 'physical-device',
                        require_qualification='NIHOS_NATIVE_PSRAM_TUNING ' in log, external_reserved_bytes=2 << 20)
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
    if source['sram'] != (2 if mode == 7 else int(mode in (5, 6))):
        raise ValueError('unexpected display source')
    if mode in (5, 6, 7):
        if (not 0x4ff00000 <= source['source'] < 0x4ff28000 or
                (mode == 5 and source['dma_source'] != source['source']) or
                source['word'] != (0xffffffff if mode == 5 else 0x10821082) or
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
    refresh = None
    if mode != 4:
        refresh = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_IRQ_PASS', REFRESH)
        if (refresh['frames'] < 32 or refresh['frames'] <= screen['frames'] or refresh['event'] != 1 or
                any(refresh[name] for name in REFRESH if name not in ('frames', 'event'))):
            raise ValueError('incomplete display IRQ evidence')
    timing = None
    layout = None
    if core['psram_fast'] is not None:
        timing = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_TIMING', ('pixel_hz', 'refresh_millihz', 'htotal', 'vtotal'))
        if (timing['pixel_hz'] != expected_dpi * 1_000_000 or timing['htotal'] != 802 or
                timing['vtotal'] not in (1663, 1524) or
                timing['refresh_millihz'] != timing['pixel_hz'] * 1000 // (timing['htotal'] * timing['vtotal'])):
            raise ValueError('display refresh timing does not match the selected profile')
    if 'NIHOS_NATIVE_DISPLAY_LAYOUT ' in log:
        layout = NATIVE.fixed_record(log, 'NIHOS_NATIVE_DISPLAY_LAYOUT', ('logical_width', 'logical_height', 'rotation'))
        if layout != dict(zip(('logical_width', 'logical_height', 'rotation'), (720, 1280, 0) if mode in (6, 7) else (1280, 720, 1))):
            raise ValueError('unexpected display composition/rotation')
    console = None
    console_style = None
    live = None
    if require_console or 'NIHOS_NATIVE_CONSOLE ' in log:
        console = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CONSOLE', ('status', 'columns', 'rows', 'log_bytes', 'dropped_low', 'input'))
        if (mode != 2 or core['psram_fast'] is None or layout is None or
                console['status'] != 1 or (console['columns'], console['rows']) not in ((78, 43), (80, 22)) or
                console['log_bytes'] != 2048 or console['input'] not in (0, 1) or
                log.index('NIHOS_NATIVE_CONSOLE ') < log.index('NIHOS_NATIVE_DISPLAY_SCANOUT ')):
            raise ValueError('incomplete read-only native console snapshot')
        if console['rows'] == 22:
            console_style = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CONSOLE_STYLE', ('cell_width', 'cell_height', 'palette', 'foreground', 'accent', 'background', 'font'))
            if (console_style['cell_width'] != 15 or console_style['cell_height'] != 30 or console_style['font'] not in (1, 2) or
                    console_style['palette'] not in (0, 1, 2) or
                    console_style['foreground'] != {0: 0xe71c, 1: 0xa5f5, 2: 0xadd9}.get(console_style['palette']) or
                    console_style['accent'] != 0x85b5 or console_style['background'] != 0x1082):
                raise ValueError('console style/geometry does not match the raster')
        elif 'NIHOS_NATIVE_CONSOLE_STYLE ' in log:
            raise ValueError('unexpected style on historical square console raster')
        if console['input'] == 1:
            if console['rows'] != 22:
                raise ValueError('live input requires the current raster')
            live = check_live(log, screen, require_live_controls)
    elif 'NIHOS_NATIVE_CONSOLE_STYLE ' in log:
        raise ValueError('orphan console style record')
    if live is None and (require_live_controls or 'NIHOS_NATIVE_UI_' in log or 'NIHOS_NATIVE_KEYBOARD ' in log or 'NIHOS_NATIVE_DIAGNOSTIC_KEY ' in log):
        raise ValueError('orphan live UI/input evidence')
    return {'live': live, 'console_style': console_style, 'console': console, 'timing': timing, 'layout': layout, 'native': core, 'display': screen, 'source': source, 'refresh': refresh,
            'mode': mode, 'lease': lease, 'optical_evidence': 'not evaluated by this checker'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--mode', type=int, required=True)
    parser.add_argument('--dpi', type=int, required=True)
    parser.add_argument("--console", action="store_true", help="Require the ASCII console record")
    parser.add_argument("--exercise-live", action="store_true", help="Require the complete six-control serial exercise")
    args = parser.parse_args()
    report = check(args.log.read_text(), json.loads(args.audit.read_text()), args.mode, args.dpi, require_console=args.console, require_live_controls=args.exercise_live)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Native memory/core and display startup/IRQ evidence passed; optical evidence is separate')


if __name__ == '__main__':
    main()

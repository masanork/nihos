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


def check(log, image, mode, expected_dpi, psram_bytes=32 << 20, require_console=False):
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
    if require_console or 'NIHOS_NATIVE_CONSOLE ' in log:
        console = NATIVE.fixed_record(log, 'NIHOS_NATIVE_CONSOLE', ('status', 'columns', 'rows', 'log_bytes', 'dropped_low', 'input'))
        if (mode != 2 or core['psram_fast'] is None or layout is None or
                console['status'] != 1 or (console['columns'], console['rows']) not in ((78, 43), (80, 22)) or
                console['log_bytes'] != 2048 or console['input'] != 0 or
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
    elif 'NIHOS_NATIVE_CONSOLE_STYLE ' in log:
        raise ValueError('orphan console style record')
    return {'console_style': console_style, 'console': console, 'timing': timing, 'layout': layout, 'native': core, 'display': screen, 'source': source, 'refresh': refresh,
            'mode': mode, 'lease': lease, 'optical_evidence': 'not evaluated by this checker'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('audit', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--mode', type=int, required=True)
    parser.add_argument('--dpi', type=int, required=True)
    parser.add_argument("--console", action="store_true", help="Require the read-only ASCII snapshot record")
    args = parser.parse_args()
    report = check(args.log.read_text(), json.loads(args.audit.read_text()), args.mode, args.dpi, require_console=args.console)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Native memory/core and display startup/IRQ evidence passed; optical evidence is separate')


if __name__ == '__main__':
    main()

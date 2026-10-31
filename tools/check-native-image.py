#!/usr/bin/env python3
import sqld_native_manifest as sqld_profile
"""Audit the native ELF/image boundary without requiring a target toolchain.

Require SRAM runtime/mutable data, bounded Flash boot code and read-only tables,
known ROM calls, no unresolved symbols, and a source-bound image descriptor.
This is a structural check, not a proof of memory safety or isolation.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys
import re
import importlib.util
import normal_fs_manifest as normal_fs_profile
import fatfs_native_profile

SRAM_LOW, SRAM_HIGH = 0x4FF00000, 0x4FF28000
SRAM_PROFILES = {"device": (SRAM_LOW, SRAM_HIGH, 0),
                 "emulator": (0x4FF20000, 0x4FF48000, 1)}
STACK_LOW, STACK_HIGH = 0x4FF60000, 0x4FF6E000
HIGH_BANKS = {".high_sram_a": (0x4ff40000, 0x4ff60000),
              ".high_sram_b": (0x4ff6e000, 0x4ffa0000)}
BROKER_CONFIG = (2, 0x4ff73000, 16384, 0x4ff1c000, 0x4ff28000, 0x4ff77000, 0x4ff9f000,
                 0x48200000, 0x4a000000, 65536, 8912896, 0x48008000, 32768)
BROKER_HOOKS_V1 = ('nih_broker_peer_quiet', 'nih_broker_quiet', 'nih_broker_ready', 'nih_broker_register',
                'nih_broker_task_exited', 'nih_broker_pending', 'nih_broker_cleanup_ready', 'nih_broker_round', 'nih_broker_reaped')
BROKER_HOOKS = BROKER_HOOKS_V1 + ('nih_broker_cancel_requested',)


def audit_broker(config, symbols, low, high, heap_start, profile):
    require(profile == 'device' and len(config) == 56, 'invalid broker device/configuration')
    values = struct.unpack('<14I', config)
    require(values[0] in (1, 2) and values[1:13] == BROKER_CONFIG[1:] and 0 < values[13] <= values[2], 'broker ranges/reserves differ from approved layout')
    require(heap_start <= values[3], 'broker low heap overlaps resident state')
    hooks = BROKER_HOOKS if values[0] == 2 else BROKER_HOOKS_V1
    for name in hooks:
        require(low <= symbols.get(name, 0) < high, 'broker IRQ hook outside resident SRAM: ' + name)
    return {'version': values[0], 'metadata_start': hex(values[1]), 'metadata_reserve': values[2], 'metadata_bytes': values[13],
            'internal_bytes': values[4] - values[3] + values[6] - values[5], 'internal_floor': values[9],
            'external_start': hex(values[7]), 'external_bytes': values[8] - values[7], 'external_floor': values[10],
            'ipc_start': hex(values[11]), 'ipc_bytes': values[12], 'resident_hooks': list(hooks)}
ROM_SYMBOLS = {"nih_rom_putc": 0x4FC00054,
               "nih_rom_get_cpu_ticks": 0x4FC00040,
               "nih_rom_set_cpu_ticks": 0x4FC00044,
               "nih_rom_set_cpu1_entry": 0x4FC000A8,
               "nih_rom_l2_line_size": 0x4FC003CC,
               "nih_rom_l2_enable": 0x4FC00504,
               "nih_rom_cache_invalidate": 0x4FC003E4,
               "nih_rom_cache_writeback": 0x4FC003F4}
OPTIONAL_ROM_SYMBOLS = {"nih_rom_reset_reason": 0x4FC00018}
OPTIONAL_ROM_DATA = {"nih_rom_saved_pc": 0x4FF3FFF8}
FLASH_SECTIONS = {".flash.appdesc": (0x40000020, 256),
                  ".flash.boot": (0x40000120, None),
                  ".flash.rodata": (0x40010020, None)}

# Foreground only, never reached by an ISR or a cache-off path. Keep the
# allowlist independent of the linked ELF; accepting all functions found there
# would defeat the SRAM/Flash boundary check.
DEVICE_FUNCTIONS = {
    'nih_audio_tx_prepare', 'nih_audio_tx_start', 'nih_audio_tx_status', 'nih_audio_tx_stop', 'audio_output',
    'nih_microphone_prepare', 'nih_microphone_start', 'nih_microphone_status', 'nih_microphone_stop', 'microphone_output',
    'nih_rs485_diagnostic', 'nih_rs485_dir_low', 'nih_rs485_open', 'nih_rs485_direction', 'nih_rs485_errors',
    'nih_rs485_writable', 'nih_rs485_readable', 'nih_rs485_tx_idle', 'nih_rs485_write', 'nih_rs485_read',
    'nih_rs485_close', 'nih_rs485_closed', 'rs485_output',
}

# These entry points are CPU0 foreground dispatch, never interrupt handlers.
# These run with the loader's Flash mapping available; IRQ and cache-off
# control remains in SRAM/ROM. The permitted entry points are explicit.
CAMERA_FOREGROUND_FUNCTIONS = {'diagnostic_ui.drawSession', 'diagnostic_ui.updateSplash', 'diagnostic_ui.paintTouchControl', 'diagnostic_ui.captureXySystem', 'board_devices.poll', 'board_devices.requestDevice', 'main.serviceNetwork',
    'nih_csi_stream_begin', 'nih_csi_stream_stop', 'nih_csi_stream_state', 'nih_csi_stream_borrow',
    'nih_csi_stream_release', 'nih_csi_stream_end', 'nih_csi_stream_abort',
    'nih_jpeg_begin', 'nih_jpeg_poll', 'nih_jpeg_abort', 'nih_jpeg_status', 'camera_jpeg.poll', 'camera_jpeg.write', 'camera_jpeg.hex', 'camera_jpeg.field', 'camera_jpeg.sync', 'camera_jpeg.fail', 'camera_jpeg.request', 'camera_jpeg.info', 'camera_jpeg.read'}

def device_function(name):
    return name in DEVICE_FUNCTIONS or name in CAMERA_FOREGROUND_FUNCTIONS or re.fullmatch(r'diagnostic_ui\.(?:input|poll|sessionKey|service)__func_[0-9]+', name) is not None or re.fullmatch(r'(?:audio_probe|microphone_probe|rs485_probe)\.poll__func_[0-9]+', name) is not None


PMP_FLASH_FUNCTIONS = {
    "native_tasks.closeFaulted",
    "native_tasks.onProtectedFault",
    "native_tasks.reclaimFaulted",
    "pmp.commit",
    "pmp.grant",
    "pmp.protectionAccepted",
    "pmp.writeWords",
    "task_runtime.Runtime(4,2).add",
    "task_runtime.Runtime(4,2).containFault",
    "task_runtime.Runtime(4,2).finishCall",
}

USER_PROBE_FUNCTIONS = {
    "nih_user_probe_trampoline",
    "nih_user_probe_body",
}


def audit_pmp_flash(functions, span):
    start, end = span
    require(0x40000120 < start < end <= 0x40010000 and start % 16 == 0, "invalid PMP Flash extent")
    selected = sorted((address, stop, name) for name, address, stop in functions if start <= address < end)
    require(selected and selected[0][0] == start and selected[-1][1] == end and
            all(start <= address < stop <= end for address, stop, name in selected),
            "PMP Flash function outside its extent")
    names = [name for _, _, name in selected]
    require(names and len(names) == len(set(names)) and set(names) <= PMP_FLASH_FUNCTIONS,
            "unapproved PMP Flash function")
    # Export and Zig debug aliases may describe the same bytes. Every name above
    # must still be approved; only the byte-coverage walk collapses exact aliases.
    ranges = sorted(set((a, b) for a, b, _ in selected))
    require(all(0 <= right[0] - left[1] <= 16 for left, right in zip(ranges, ranges[1:])),
            "overlapping or unaccounted PMP Flash bytes")
    for name, address, stop in functions:
        if name in PMP_FLASH_FUNCTIONS:
            require(start <= address < stop <= end, "PMP helper left its Flash extent: " + name)
    return {name: {"start": hex(address), "end": hex(stop)} for address, stop, name in selected}


def audit_device_functions(functions, span):
    start, end = span
    require(0x40000120 < start < end <= 0x40010000 and start % 16 == 0, 'invalid device Flash extent')
    selected = sorted((address, stop, name) for name, address, stop in functions if start <= address < end)
    require(selected and selected[0][0] == start and selected[-1][1] == end and
            all(start <= address < stop <= end and device_function(name) for address, stop, name in selected), 'unapproved device Flash function')
    names = [name for _, _, name in selected]
    require(len(names) == len(set(names)) and DEVICE_FUNCTIONS.issubset(names) and
            all(sum(re.fullmatch(prefix + r'\.poll__func_[0-9]+', name) is not None for name in names) == 1
                for prefix in ('audio_probe', 'microphone_probe', 'rs485_probe')), 'missing/duplicate device Flash function')
    # Export and Zig debug aliases may describe the same bytes. Every name above
    # must still be approved; only the byte-coverage walk collapses exact aliases.
    ranges = sorted(set((a, b) for a, b, _ in selected))
    require(all(0 <= right[0] - left[1] <= 16 for left, right in zip(ranges, ranges[1:])), 'overlapping/unaccounted device Flash bytes')
    return {name: {'start': hex(address), 'end': hex(stop)} for address, stop, name in selected}

TIME_ENGINE = 'sntp.Engine(".flash.text.time"[0..16]).'
TIME_CALENDAR = 'rtc.Calendar(".flash.text.time"[0..16]).'
TIME_FUNCTIONS = {'main.serviceTime', 'board_devices.applyNetworkTime', 'network_service.timePoll', 'network_service.step'} | {
    TIME_ENGINE + name for name in ('disconnect', 'bind', 'fail', 'tx', 'route', 'query', 'udp', 'sent', 'receive', 'datagram', 'acceptTime', 'take', 'snapshot', 'timestamp', 'skipName', 'dnsAnswer', 'validMac', 'unicast', 'sum16')
} | {TIME_CALENDAR + name for name in ('fromUnix', 'toUnix')}
TIME_GENERIC = {TIME_CALENDAR + name for name in ('set', 'writeStopped')}

def time_function(name):
    return name in TIME_FUNCTIONS or any(re.fullmatch(re.escape(prefix) + r'__func_[0-9]+', name) for prefix in TIME_GENERIC)


def audit_time_functions(functions, span):
    start, end = span
    require(0x40000120 < start < end <= 0x40010000 and start % 16 == 0, 'invalid network/time Flash extent')
    selected = sorted((address, stop, name) for name, address, stop in functions if start <= address < end)
    require(selected and selected[0][0] == start and selected[-1][1] == end and
            all(start <= address < stop <= end and time_function(name) for address, stop, name in selected), 'unapproved network/time Flash function')
    names = [name for _, _, name in selected]
    require(len(names) == len(set(names)) and TIME_FUNCTIONS.issubset(names) and
            all(sum(re.fullmatch(re.escape(prefix) + r'__func_[0-9]+', name) is not None for name in names) == 1 for prefix in TIME_GENERIC), 'missing/duplicate network/time Flash function')
    # Export and Zig debug aliases may describe the same bytes. Every name above
    # must still be approved; only the byte-coverage walk collapses exact aliases.
    ranges = sorted(set((a, b) for a, b, _ in selected))
    require(all(0 <= right[0] - left[1] <= 16 for left, right in zip(ranges, ranges[1:])), 'overlapping/unaccounted network/time Flash bytes')
    return {name: {'start': hex(address), 'end': hex(stop)} for address, stop, name in selected}


SQL_START, SQL_END = 0x40020000, 0x400C0000
FATFS_SQL_END = 0x400D0000
SQL_SECTIONS = {".flash.sqltext", ".flash.sqlrodata", ".flash.sqlpad"}
GRAPH_START, GRAPH_END = 0x40020000, 0x40C00000
GRAPH_SECTIONS = {".flash.graphtext", ".flash.graphrodata", ".flash.graphfonts", ".flash.graphpad", ".flash.graphrender"}
RENDER_FUNCTIONS = {"native_surface.checkSource", "native_font_stack.paint", "main.graphicsReport", "main.taskReport", "main.floatingReport", "main.resourceReport", "main.stackReport", "native_font_exchange.sourceHash", "native_font_exchange.drawHash", "native_font_exchange.stageText", "native_surface.verify", "native_surface.prepare", "native_surface.paint", "native_surface.draw"}
RENDER_RESIDENT = {"native_font_stack.scratch", "native_font_stack.reaped", "native_font_exchange.releaseArchive", "native_surface.stage", "native_surface.verifySource", "native_surface.compose", "native_surface.contextAllowed", "native_surface.captureTimer",
                   "nih_native_dispatch", "nih_native_trap", "heap.allocTask", "heap.freeTask"}
GRAPH_RAM_LOW, GRAPH_RAM_HIGH = 0x4FF78000, 0x4FF80000
GRAPH_STACK_LOW, GRAPH_STACK_HIGH = 0x4FF6E000, 0x4FF76000

PHOTO_SECTIONS = {".flash.photo", ".flash.photo.rodata"}
UI_SECTIONS = {".flash.uipad", ".flash.ui"}
UI_POOLS = {".keypad.low": (0x4ff40000, 128 * 1024), ".keypad.high": (0x4ff70000, 188 * 1024)}
SERVICE_SRAM_FUNCTIONS = {'nih_base_sram_take', 'nih_base_sram_release', 'base_sram_lock',
                          'base_sram_unlock', 'base_sram_cpu0', 'nih_sram_pool_init',
                          'nih_sram_pool_take', 'nih_sram_pool_release', 'nih_display_keypad_fits', 'ui_place',
                          'keypad_display.acquire', 'keypad_display.release'}
CARD_BOOT_FUNCTIONS = {'card_boot.paint', 'card_boot.finish', 'card_boot.report', 'main.startDisplay', 'display_runtime.replace', 'display_runtime.wipePools', 'graphics.keypad_plan.buildStaticColor'}

def audit_ui_pool(name, kind, flags, address, size, allowed):
    require(allowed and kind == 8 and flags == 3 and (address, size) == UI_POOLS.get(name), 'invalid keypad SRAM pool')


XY_SECTIONS = {'.flash.xypad', '.flash.xytext', '.flash.xyrodata'}
XY_METHODS = {'initInPlace', 'tick', 'alloc', 'pair', 'number', 'text', 'string', 'opcode',
              'collect', 'mark', 'space', 'delimiter', 'read', 'arguments', 'lookup', 'define',
              'closure', 'sequence', 'eval', 'integer', 'apply', 'start', 'evaluate',
              'runCommand', 'format', 'emit', 'print', 'viewKey', 'applyView', 'cameraRead',
              'applyStorage', 'nonnegative', 'storageText','sameText','parseDecimal','parseHex'}
XY_HOST_METHODS = {'initInPlace', 'resetScheme', 'schemeError', 'evaluate', 'schemeCall', 'handle', 'insert', 'feedHid', 'feedSerial', 'expireSerial', 'openSystem', 'appendCommand', 'cameraCapture', 'cameraInfo', 'cameraRead', 'storageCall', 'saveDocument', 'loadDocument', 'documentText', 'replayInput','evaluateOnStack'}


# Foreground object compiled with symbols retained. Keep this exact: IRQ or I/O
# helpers must not acquire a route into the PSRAM render stack.
XY_RENDER_FUNCTIONS = {
    'native_render_entry.nih_xy_render', 'native_render_entry.nih_xy_render_init',
    'native_render_entry.nih_xy_render_bytes', 'rotated_surface.Rotated.blit',
    'rotated_surface.Rotated.paint', 'rotated_surface.Rotated.blitLinear',
    'rotated_surface.Rotated.fillRect', 'surface.channelLinear', 'xy.presentation.publish', 'presentation.publish',
    'ttf.TwoTierCache(24,1024,48,16384).getOrRender', 'ttf.Face.glyphSpan',
    'ttf.decodeSimpleGlyfSlice', 'ttf.Family.resolve', 'ttf.Face.lookupBaseGlyph',
    'ttf.Face.init', 'ttf.SliceReader.fromSlice.Impl.readSlice',
    'xy.storage.decimalU32','xy.storage.copyDecimalBytes','xy.storage.validUtf8', 'xy.storage.Client.save', 'xy.storage.Client.load', 'xy.storage.Client.saveStaged', 'xy.storage.Client.loadOpened',
    'unicode.utf8ByteSequenceLength', 'unicode.utf8Decode4', 'unicode.utf8Decode3',
    'unicode.utf8Decode', 'unicode.utf8Decode2', 'unicode.utf8ValidateSlice',
    'line_layout.Flow.place', 'render_adapter.computeCursorRect',
    'render_adapter.ThemePalette.color565', 'document.nextClusterEnd',
    'document.isClusterBoundary', 'render_session.SizedSession(2048).render',
    'native_render_entry.readingPack', 'catalog.Pack.entry', 'catalog.Pack.chapter',
    'catalog.Pack.font', 'reader.closeBoundary', 'viewport_layout.ClusterIterator.next',
    'view_config.Config.set', 'Io.Writer.writeAll', 'Io.Writer.unimplementedSendFile',
    'Io.Writer.failingRebase', 'Io.Writer.noopFlush', 'Io.Writer.fixedDrain',
    'xy.navigation.State.home', 'xy.navigation.State.open',
    'xy.navigation.State.selectChapter', 'xy.navigation.State.handle',
    'xy.navigation.State.activateHome', 'xy.navigation.State.next',
    'xy.navigation.State.back', 'xy.navigation.State.touch',
}

def xy_function(name):
    match = re.fullmatch(r'(?:xy\.)?scheme_runtime\.Runtime\.(\w+?)(?:__func_[0-9]+)?', name)
    host = re.fullmatch(r'xy\.scratch\.Model\.(\w+)', name)
    render_helper = re.fullmatch(r"(?:diagnostic_ui\.(?:beginSession|traceScratch|traceIdle)|mem\.(?:eql|findAny)|line_layout\.cluster|native_reading\.(?:label|footer)|Io\.Writer\.printIntAny|viewport_layout\.(?:shapeRun|layoutParagraph|layoutParagraphWithWordWrap)|render_session\.SizedSession\(2048\)\.renderInto)__func_[0-9]+", name)
    return bool(name in XY_RENDER_FUNCTIONS or render_helper or (match and match[1] in XY_METHODS) or (host and host[1] in XY_HOST_METHODS) or name in ('scheme_runtime.message', 'xy.scheme_runtime.message', 'diagnostic_ui.drawSession', 'diagnostic_ui.updateSplash', 'diagnostic_ui.paintTouchControl', 'diagnostic_ui.captureXySystem', 'diagnostic_ui.traceScratch', 'xy_render_runtime.draw', 'sqld_abi.call', 'xy_eval_runtime.nih_xy_evaluate', 'nih_xy_evaluate', 'xy_eval_runtime.nih_xy_eval_on_stack', 'nih_xy_eval_on_stack', 'nih_xy_eval_call', 'nih_xy_render', 'nih_xy_render_init', 'nih_xy_render_bytes', 'nih_xy_render_call', '.Lttf.SliceReader.fromSlice.Impl.readSlice'))


def audit_xy_functions(functions, span):
    start, end = span
    require(start == 0x40060000 and start < end <= 0x400c0000, 'invalid xy code extent')
    selected = sorted((a, b, n) for n, a, b in functions if start <= a < end)
    require(selected and selected[0][0] == start and all(a < b <= end and xy_function(n) for a, b, n in selected), 'unapproved xy Flash function')
    # Export and Zig debug aliases may describe the same bytes. Every name above
    # must still be approved; only the byte-coverage walk collapses exact aliases.
    ranges = sorted(set((a, b) for a, b, _ in selected))
    require(all(0 <= right[0] - left[1] <= 16 for left, right in zip(ranges, ranges[1:])) and 0 <= end - selected[-1][1] <= 16, 'unaccounted xy code bytes')
    require(any('Runtime.evaluate' in n for _, _, n in selected) and any('Runtime.collect' in n for _, _, n in selected), 'incomplete xy evaluator')
    return {n: {'start': hex(a), 'end': hex(b)} for a, b, n in selected}


def audit_service_sram(symbols, high, allocated):
    keys = ['__service_sram' + str(i) + suffix for i in range(2) for suffix in ('_start', '_end')]
    if not any(key in symbols for key in keys):
        return []  # Historical evidence uses explicitly reserved keypad pools.
    require(all(key in symbols for key in keys), 'incomplete base free SRAM symbols')
    domains = []
    for i in range(2):
        start, end = (symbols[keys[2 * i + j]] for j in range(2))
        require(start % 64 == end % 64 == 0 and start < end and
                ((start == max(high, 0x4ff40000) and end == STACK_LOW) if i == 0 else
                 STACK_HIGH <= start < end == 0x4ff9f000), 'invalid base free SRAM extent')
        require(all(int(s['address'], 16) + s['bytes'] <= start or int(s['address'], 16) >= end
                    for s in allocated), 'base free SRAM overlaps an allocated section')
        domains.append({'name': 'service.free' + str(i), 'origin': hex(start), 'end': hex(end), 'bytes': end - start})
    return domains


def audit_ui_assets(start, data, symbols, manifest):
    for role in (('font',) if manifest.get('ui_mode') == 'runtime' else ('plan', 'atlas')):
        first = symbols.get('__keypad_' + role + '_start', 0)
        last = symbols.get('__keypad_' + role + '_end', 0)
        require(start <= first < last <= start + len(data) and first % 64 == 0, 'invalid keypad asset extent')
        raw = data[first - start:last - start]
        require(len(raw) == manifest[role + '_bytes'] and hashlib.sha256(raw).hexdigest() == manifest[role + '_sha256'], 'keypad asset differs from manifest')
        if role=='font' and manifest.get('font_encoding'):
            require(manifest['font_encoding']=='row12-v1','unapproved font encoding')
            spec=importlib.util.spec_from_file_location('native_font_codec',Path(__file__).with_name('font_codec.py'))
            codec=importlib.util.module_from_spec(spec);spec.loader.exec_module(codec)
            decoded=codec.decode(raw)
            require(hashlib.sha256(decoded).hexdigest()==manifest.get('font_raw_sha256') and len(decoded)==manifest.get('glyphs',0)*36,'compressed glyph pixels differ from pinned raw font')


def audit_flash_section(name, kind, flags, address, size, allow_sql=False, allow_ui=False, allow_photo=False, allow_devices=False, allow_time=False, sql_end=SQL_END, allow_fs=False, allow_graphics=False, allow_xy=False, allow_sqld=False):
    if name in sqld_profile.SECTIONS:
        require(allow_sqld and kind == 1, 'unapproved permanent sqld section')
        if name == '.flash.sqldpad':
            require(flags == 2 and 0x40060000 < address < address + size == 0x40400000, 'invalid sqld padding')
        else:
            require((flags == 6 if name == '.flash.sqldtext' else flags & 7 == 2 and flags & ~50 == 0) and 0x40400000 <= address < address + size <= 0x404c0000 and address % 16 == 0, 'invalid sqld extent/permissions')
        return
    if name == '.flash.xypad':
        require(allow_xy and kind == 1 and flags == 2 and 0x40010020 < address < 0x40060000 and address + size == 0x40060000 and address % 4 == size % 4 == 0, 'invalid xy Flash padding')
        return
    if name in XY_SECTIONS:
        require(allow_xy and kind == 1 and (flags == 6 if name == '.flash.xytext' else flags & 7 == 2 and flags & ~50 == 0), 'invalid xy Flash profile/permissions')
        require(0x40060000 <= address < address + size <= (0x400c0000 if name == '.flash.xytext' else 0x40400000) and address % 16 == 0 and (name != '.flash.xytext' or address == 0x40060000), 'invalid xy Flash extent')
        return
    if name in GRAPH_SECTIONS:
        readonly = flags & 7 == 2 and flags & ~50 == 0
        require(allow_graphics and kind == 1 and (flags == 6 if name in (".flash.graphtext", ".flash.graphrender") else readonly), "unapproved graphics Flash section")
        if name == ".flash.graphpad":
            require(0x40010020 < address < GRAPH_START and address + size == GRAPH_START, "invalid graphics Flash padding")
        else:
            require(GRAPH_START <= address < address + size <= GRAPH_END, "invalid graphics Flash extent")
        return
    elif name in normal_fs_profile.SECTIONS:
        require(allow_fs and kind == 1, 'unapproved ordinary FS Flash section')
        if name == '.flash.fspad':
            require(flags == 2 and 0x40010020 < address < SQL_START and address + size == SQL_START, 'invalid FS Flash padding')
        else:
            require((flags == 6 if name == '.flash.fstext' else flags & 7 == 2 and flags & ~50 == 0) and SQL_START <= address < address + size <= 0x40060000 and (name != '.flash.fstext' or address == SQL_START), 'invalid FS Flash permissions/extent')
        return
    if name == '.flash.time':
        require(allow_time and kind == 1 and flags == 6 and 0x40000120 < address < address + size <= 0x40010000 and address % 16 == 0, 'invalid network/time foreground Flash section')
        return
    if name == '.flash.devices':
        require(allow_devices and kind == 1 and flags == 6 and 0x40000120 < address < address + size <= 0x40010000 and address % 16 == 0, 'invalid device foreground Flash section')
        return
    if name in PHOTO_SECTIONS:
        require(allow_photo and kind == 1 and (flags == 6 if name == '.flash.photo' else flags & 7 == 2 and flags & ~50 == 0) and SQL_START <= address < address + size <= SQL_END, 'invalid photo codec Flash extent/permissions')
        return
    if name == '.flash.card':
        require(allow_ui and kind == 1 and flags == 6 and 0x40000120 < address < address + size <= 0x40010000, 'invalid card foreground Flash code')
        return
    if name == ".flash.pmp":
        require(kind == 1 and flags == 6 and 0x40000120 < address < address + size <= 0x40010000 and address % 16 == 0,
                "invalid PMP Flash section")
        return
    if name == ".flash.user":
        require(kind == 1 and flags == 6 and 0x40000120 < address < address + size <= 0x40010000 and address % 128 == 0 and size % 128 == 0,
                "invalid user probe Flash section")
        return
    if name in UI_SECTIONS:
        require(allow_ui and kind == 1 and flags & 7 == 2 and flags & ~50 == 0, 'unapproved/mutable/executable keypad Flash section')
        if name == '.flash.uipad':
            require(0x40010020 < address < SQL_START and address + size == SQL_START, 'invalid keypad Flash padding')
        else:
            require(address == SQL_START and 0 < size <= SQL_END - SQL_START, 'invalid keypad read-only extent')
        return
    if name == ".flash.sqlpad":
        require(allow_sql and kind == 1 and flags == 2 and 0x40010020 < address < SQL_START and address + size == SQL_START,
                "invalid SQLite Flash padding")
        return
    if name in SQL_SECTIONS:
        require(allow_sql and kind == 1 and (flags == 6 if name == ".flash.sqltext" else (flags & 7 == 2 and flags & ~50 == 0)),
                "unapproved/mutable SQLite Flash section")
        require(SQL_START <= address < address + size <= sql_end and
                (name != ".flash.sqltext" or address == SQL_START), "invalid SQLite Flash extent")
        return
    expected = FLASH_SECTIONS.get(name)
    require(expected is not None and address == expected[0], "unexpected non-SRAM section: " + name)
    # SHF_MERGE/SHF_STRINGS describe immutable constant folding, not memory
    # permissions. Small headless tables may retain these linker metadata bits.
    permissions = flags == 6 if name == ".flash.boot" else (
        flags & 7 == 2 and flags & ~50 == 0 if name == ".flash.rodata" else flags == 2)
    require(kind == 1 and permissions, "invalid Flash PROGBITS permissions")
    maximum = 65248 if name == ".flash.boot" else 65504
    require(size == expected[1] if expected[1] is not None else 0 < size <= maximum,
            "invalid Flash section size")


def audit_graphics_sram(name, kind, flags, address, size):
    require(flags == 3, "graphics SRAM must be writable non-executable")
    if name == ".graphics.stack":
        require(kind == 8 and address == GRAPH_STACK_LOW and size == 32768, "invalid graphics stack")
    else:
        require(name in (".graphics.data", ".graphics.bss") and kind == (1 if name == ".graphics.data" else 8) and
                GRAPH_RAM_LOW <= address < address + size <= GRAPH_RAM_HIGH, "invalid graphics SRAM data")


def audit_render(section, functions):
    low, data = section
    high = low + len(data)
    require(low % 4 == 0 and 0 < len(data) <= 16384, "invalid rendering Flash extent")
    selected = [(name, start, end) for name, start, end in functions if low <= start < high or start < low < end]
    require(len(selected) == len(RENDER_FUNCTIONS) and {n for n, _, _ in selected} == RENDER_FUNCTIONS,
            "unexpected/missing rendering Flash function")
    selected.sort(key=lambda item: item[1])
    require(selected[0][1] == low and all(low <= start < end <= high for _, start, end in selected) and
            0 <= high - selected[-1][2] < 16 and
            all(0 <= right[1] - left[2] < 16 for left, right in zip(selected, selected[1:])),
            "overlapping/unaccounted rendering Flash function extent")
    resident = {name: {"start": hex(start), "end": hex(end)} for name, start, end in functions if name in RENDER_RESIDENT}
    require(set(resident) == RENDER_RESIDENT and all(0x4ff00000 <= int(f["start"], 16) < int(f["end"], 16) <= 0x4ff48000 for f in resident.values()),
            "renderer guard/allocator/trap helper must remain SRAM")
    return {"start": hex(low), "end": hex(high), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "functions": {name: {"start": hex(start), "end": hex(end)} for name, start, end in selected},
            "resident": resident}


def audit_graphics(sections, symbols, sizes, functions, manifest, tables):
    require(manifest and manifest.get("schema") == 1 and manifest.get("allowed_functions"), "missing graphics object manifest")
    require(set(sections) == GRAPH_SECTIONS | {".graphics.data", ".graphics.bss", ".graphics.stack"}, "missing graphics sections")
    text, ro, fonts, pad = (sections[n] for n in (".flash.graphtext", ".flash.graphrodata", ".flash.graphfonts", ".flash.graphpad"))
    require(text[0] == GRAPH_START and text[0] + len(text[1]) == ro[0] and
            0 <= fonts[0] - ro[0] - len(ro[1]) < 16 and fonts[0] % 16 == 0, "noncontiguous graphics Flash layout")
    require(pad[0] == 0x40010020 + ((len(tables) + 3) & ~3) and not any(pad[1]) and
            pad[0] + len(pad[1]) == GRAPH_START, "nonzero/noncontiguous graphics padding")
    require(symbols.get("__graphics_font_stack_bottom") == GRAPH_STACK_LOW and symbols.get("__graphics_font_stack_top") == GRAPH_STACK_HIGH,
            "graphics stack symbols differ")
    require(symbols.get("__graphics_bss_start") == sections[".graphics.bss"][0] and symbols.get("__graphics_bss_end") == sections[".graphics.bss"][0] + sections[".graphics.bss"][2], "graphics BSS zeroing bounds differ")
    require(not {"malloc", "calloc", "realloc", "free", "__getreent"}.intersection(symbols), "unprefixed graphics C runtime")
    for name in ("memcpy", "memset", "memmove", "memcmp", "__udivdi3"):
        require(name not in symbols or any(low <= symbols[name] < high and 0x4ff00000 <= low < high <= 0x4ff48000 for _, low, high in functions), "kernel helper redirected to graphics Flash")
    selected = {name: {"start": hex(low), "end": hex(high)} for name, low, high in functions if GRAPH_START <= low < high <= ro[0]}
    require({"graphics_font_link_probe", "nih_gfx_study_malloc"}.issubset(selected), "missing graphics functions")
    require(GRAPH_RAM_LOW <= symbols.get("graphics_output", 0) < GRAPH_RAM_HIGH and sizes.get("graphics_output") == 844, "graphics output ABI/data placement differs")
    require(GRAPH_RAM_LOW <= symbols.get("graphics_result", 0) < GRAPH_RAM_HIGH and sizes.get("graphics_result") == 124, "graphics result ABI/data placement differs")
    render = sections[".flash.graphrender"]
    require(render[0] == (fonts[0] + len(fonts[1]) + 3) & ~3, "noncontiguous rendering Flash layout")
    render_report = audit_render(render, functions)
    require(symbols.get("__flash_render_start") == render[0] and symbols.get("__flash_render_end") == render[0] + len(render[1]) and
            symbols.get("__flash_graphics_end") == render[0] + len(render[1]), "rendering Flash symbols differ")
    queue_metadata = {}
    for name in ("requests", "replies"):
        symbol = "native_font_exchange." + name
        address = symbols.get(symbol, 0)
        require(0x4ff00000 <= address < address + 384 <= 0x4ff48000 and sizes.get(symbol) == 384,
                "queue metadata must remain bounded internal SRAM")
        queue_metadata[name] = {"start": hex(address), "end": hex(address + 384), "bytes": 384}
    inputs = []
    for item in manifest["fonts"]:
        low, high = (symbols.get("nih_graphics_" + item["family"] + suffix, 0) for suffix in ("_start", "_end"))
        require(fonts[0] <= low < high <= fonts[0] + len(fonts[1]) and high - low == item["bytes"], "font extent differs")
        require(hashlib.sha256(fonts[1][low - fonts[0]:high - fonts[0]]).hexdigest() == item["sha256"], "font bytes differ from pinned source")
        inputs.append({**item, "start": hex(low), "end": hex(high)})
    payload = tables + bytes((-len(tables)) % 4) + pad[1] + text[1] + ro[1] + bytes(fonts[0] - ro[0] - len(ro[1])) + fonts[1]
    payload += bytes(render[0] - fonts[0] - len(fonts[1])) + render[1]
    payload += bytes((-len(payload)) % 4)
    return {"render": render_report, "queue_metadata": queue_metadata, "text_start": hex(text[0]), "text_end": hex(ro[0]), "text_bytes": len(text[1]),
            "rodata_bytes": len(ro[1]), "fonts_bytes": len(fonts[1]), "fonts": inputs,
            "functions": selected, "payload_sha256": manifest["payload_sha256"], "padding_bytes": len(pad[1]),
            "static_data_bytes": sections[".graphics.data"][2], "static_bss_bytes": sections[".graphics.bss"][2],
            "stack_bytes": 32768, "ram_reserved_bytes": 32768}, (text[0], ro[0]), payload


def audit_boot_functions(functions, start, end, low, high, sql_span=None, sql_functions=(), card_span=None, card_functions=(), photo_span=None, photo_functions=(), automatic_cards=False, device_span=None, time_span=None, sdmmc_span=None, fs_span=None, fs_functions=(), render_span=None, pmp_span=None, user_span=None, xy_span=None):
    found = {}
    for name, address, stop in functions:
        if low <= address < high:
            require(stop <= high, "function exceeds SRAM: " + name)
            continue
        if (ROM_SYMBOLS | OPTIONAL_ROM_SYMBOLS).get(name) == address:
            continue
        if xy_span is not None and xy_span[0] <= address < stop <= xy_span[1]:
            require(xy_function(name), 'unapproved xy foreground function: ' + name)
            continue
        if fs_span is not None and fs_span[0] <= address < stop <= fs_span[1]:
            require(name in fs_functions, 'non-manifest ordinary FS Flash function: ' + name)
            continue
        if time_span is not None and time_span[0] <= address < stop <= time_span[1]:
            require(time_function(name), 'unapproved network/time Flash function: ' + name)
            continue
        if device_span is not None and device_span[0] <= address < stop <= device_span[1]:
            require(device_function(name), 'unapproved device Flash function: ' + name)
            continue
        if sql_span is not None and sql_span[0] <= address < stop <= sql_span[1]:
            require(name in sql_functions, "non-manifest function in mapped library Flash: " + name)
            continue
        if render_span is not None and render_span[0] <= address < stop <= render_span[1]:
            require(name in RENDER_FUNCTIONS, "unapproved rendering Flash function: " + name)
            continue
        if pmp_span is not None and pmp_span[0] <= address < stop <= pmp_span[1]:
            require(name in PMP_FLASH_FUNCTIONS, "unapproved PMP Flash function: " + name)
            continue
        if user_span is not None and user_span[0] <= address < stop <= user_span[1]:
            require(name in USER_PROBE_FUNCTIONS, "unapproved user probe function: " + name)
            continue
        if card_span is not None and card_span[0] <= address < stop <= card_span[1]:
            require(any(name == prefix or re.fullmatch(re.escape(prefix) + r'__func_[0-9]+', name) for prefix in card_functions), 'unapproved card foreground function: ' + name)
            continue
        if photo_span is not None and photo_span[0] <= address < stop <= photo_span[1]:
            software = (name.startswith(('compiler_rt.addf3.', 'compiler_rt.mulf3.', 'compiler_rt.divf3.', 'compiler_rt.divsf3.', 'compiler_rt.divdf3.', 'compiler_rt.comparef.', 'compiler_rt.float_from_int.', 'compiler_rt.int_from_float.', 'compiler_rt.extendf.', 'compiler_rt.truncf.')) or re.fullmatch(r'__(?:(?:add|sub|mul|div|cmp|eq|ne|ge|gt|le|lt|unord)(?:sf|df)2?3?|float(?:un)?(?:si|di)(?:sf|df)|fix(?:uns)?(?:sf|df)(?:si|di)|extendsfdf2|truncdfsf2)',name))
            automatic = automatic_cards and (name in ('notice_build', 'nih_display_notice_publish', 'nih_display_scanout_begin', 'display_runtime.presentNotice', 'keypad_display.publishNotice') or name.startswith(('card_auto.', 'graphics.card_read_result.automaticText', 'graphics.card_read_result.Glyph(', 'graphics.card_read_result.AutoPainter(', 'graphics.card_read_result.readBits', 'graphics.card_read_result.automaticOverview', 'card.jis0208.Decoder(', 'card.license_trust.lookup', 'card.license.Parser(', 'card.license_record.Parser(', 'card.license_session.Session(', 'card.service.ServiceType(true,', 'card.wire_policy.PolicyType(true)')))
            require(automatic or name in photo_functions or name.startswith('card.surface.Parser') or name in ('photo_runtime.execute', 'keypad_display.stage', 'card_read.abort') or software, 'unapproved photo codec function: ' + name)
            continue
        role = "probe" if name == "psram.probe" else "mapping" if re.fullmatch(r"psram_memory\.prepare__func_[0-9]+", name) else "clock" if re.fullmatch(r"cpu_boot\.run__func_[0-9]+", name) else None
        if sdmmc_span is not None and name == "sdmmc_probe.run":
            require((address, stop) == sdmmc_span, "SDMMC boot function differs from linker extent")
            role = "sdmmc"
        require(role is not None and start <= address < stop <= end, "unapproved Flash function: " + name)
        require(role not in found, "duplicate Flash boot role")
        found[role] = {"name": name, "start": hex(address), "end": hex(stop)}
    expected_roles = {"probe", "mapping"} | ({"sdmmc"} if sdmmc_span is not None else set())
    require(set(found) in (expected_roles, expected_roles | {"clock"}), "missing approved Flash boot functions")
    ordered = sorted(found.values(), key=lambda entry: int(entry["start"], 16))
    require(int(ordered[0]["start"], 16) == start and int(ordered[-1]["end"], 16) == end and
            all(0 <= int(right["start"], 16) - int(left["end"], 16) <= 16 for left, right in zip(ordered, ordered[1:])),
            "overlapping/unaccounted Flash boot extent")
    return found


def audit_sdmmc_resident(symbols, sizes, low, high):
    for resident in ("nih_storage_read", "nih_storage_controller_begin", "nih_storage_controller_end"):
        if resident in symbols:
            require(low <= symbols[resident] < high, "SD runtime controller callback left SRAM: " + resident)
    for name, size in (("sdmmc_probe.dma_data", 512), ("sdmmc_probe.dma_descriptor", 64)):
        require(name in symbols and low <= symbols[name] < symbols[name] + size <= high and
                sizes.get(name) == size and symbols[name] % 64 == 0, "SD DMA buffer outside aligned internal SRAM")


def audit_io_lifetimes(config, symbols, sizes, low, high):
    require(config.get('version') == 1 and isinstance(config.get('qualification'), bool), 'invalid I/O lifetime manifest')
    require(isinstance(config.get('removal_test', False), bool) and
            (not config.get('removal_test') or config['qualification']), 'invalid physical removal profile')
    require(isinstance(config.get('capture_handshake', False), bool) and
            (not config.get('capture_handshake') or config['qualification']), 'invalid capture handshake profile')
    if config.get('capture_handshake'):
        capture_format = config.get('capture_format', 1)
        require(type(capture_format) is int and capture_format in (1, 2), 'unknown capture format')
        require(symbols.get('nih_rom_reset_reason') == OPTIONAL_ROM_SYMBOLS['nih_rom_reset_reason'] and
                symbols.get('USB_SERIAL_JTAG') == 0x500d2000 and
                low <= symbols.get('nih_boot_capture_getc', 0) < high, 'invalid capture ROM/input ABI')
        expected_capture = {'probes/sdmmc/pads.c', 'src/platform/native/esp32p4.ld'}
        if capture_format == 2:
            expected_capture.add('src/soc/esp32p4/reset_capture.zig')
            require(symbols.get('nih_rom_saved_pc') == OPTIONAL_ROM_DATA['nih_rom_saved_pc'], 'invalid saved PC ROM data ABI')
        require(set(config.get('capture_sources', {})) == expected_capture and
                all(re.fullmatch('[0-9a-f]{64}', value) for value in config['capture_sources'].values()),
                'missing capture source identity')
    expected = {'src/fs/io_leases.zig', 'src/fs/io_stop.zig', 'src/fs/sdmmc_owner.zig',
                'src/soc/esp32p4/sdmmc.zig', 'src/platform/native/sdmmc_probe.zig',
                'src/platform/native/main.zig', 'src/diagnostics/record.zig', 'include/nihos_storage_io.h'}
    require(set(config.get('sources', {})) == expected and all(re.fullmatch('[0-9a-f]{64}', value)
            for value in config['sources'].values()), 'incomplete I/O lifetime source identity')
    for name in ('sdmmc_probe.io_owner', 'sdmmc_probe.io_signal'):
        require(name in symbols and 0 < sizes.get(name, 0) and low <= symbols[name] < symbols[name] + sizes[name] <= high,
                'I/O lease or notification metadata left resident SRAM: ' + name)
    if config['qualification']:
        for name in ('nih_storage_io_active', 'nih_storage_io_stop', 'nih_storage_io_removed'):
            require(low <= symbols.get(name, 0) < high, 'I/O notification hook left resident SRAM: ' + name)
    return config


def audit_cold_flash(manifest, symbols, functions, low, high, heap_start, sql_span, profile, broker):
    start, end = symbols.get('__flash_cold_start'), symbols.get('__flash_cold_end')
    require((start is None) == (end is None), 'partial cold Flash linker extent')
    if manifest is None:
        require(start is None or start == end, 'cold Flash code without approved manifest')
        return None
    require(isinstance(manifest, dict), 'invalid cold Flash manifest')
    policy_path = Path(__file__).with_name('native-cold-policy.json')
    policy = json.loads(policy_path.read_text())
    require(profile == 'device' and broker is not None and broker.get('version') == 2,
            'cold Flash placement requires device broker version 2')
    require(manifest.get('version') == policy['version'] and
            manifest.get('functions') == sorted(policy['functions']) and
            manifest.get('resident') == policy['resident'] and
            manifest.get('baseline_bytes') == policy['baseline_bytes'] and
            manifest.get('resident_limit') == policy['resident_limit'] and
            manifest.get('policy_sha256') == hashlib.sha256(policy_path.read_bytes()).hexdigest(),
            'cold Flash manifest differs from explicit placement policy')
    sources = manifest.get('sources', {})
    require(isinstance(sources, dict) and set(sources) == set(policy['functions'].values()) and
            all(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) for value in sources.values()),
            'missing cold Flash source provenance')
    require(start is not None and sql_span is not None and sql_span[0] <= start < end <= sql_span[1],
            'cold Flash extent outside mapped code')
    rows = sorted((address, stop, name) for name, address, stop in functions if start <= address < end)
    require(len(rows) == len(policy['functions']) and {row[2] for row in rows} == set(policy['functions']),
            'cold Flash extent has missing, duplicate or unapproved functions')
    require(rows[0][0] == start and rows[-1][1] == end and
            all(address < stop <= end for address, stop, _ in rows) and
            all(0 <= right[0] - left[1] <= 4 for left, right in zip(rows, rows[1:])),
            'overlapping or unaccounted cold Flash extent')
    for name in policy['resident']:
        require(low <= symbols.get(name, 0) < min(heap_start, high), 'critical callback left resident SRAM: ' + name)
    resident_bytes = heap_start - low
    require(0 < resident_bytes <= policy['resident_limit'], 'cold Flash resident headroom below 8 KiB')
    return {'version': policy['version'], 'start': hex(start), 'end': hex(end), 'bytes': end - start,
            'functions': {name: {'start': hex(address), 'bytes': stop - address} for address, stop, name in rows},
            'resident': {name: hex(symbols[name]) for name in policy['resident']},
            'baseline_primary_bytes': policy['baseline_bytes'], 'primary_bytes': resident_bytes,
            'recovered_bytes': policy['baseline_bytes'] - resident_bytes,
            'old_heap_bytes': high - heap_start, 'source': manifest,
            'irq_call_graph_proven': False}


def audit_app_descriptor(data):
    require(len(data) == 256 and struct.unpack_from("<I", data)[0] == 0xABCD5432,
            "invalid app descriptor")
    require(data[180] == 16, "app descriptor must select 64 KiB MMU pages")


def fnv1a(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def is_fp_instruction(word, width):
    if width == 2:
        return (word & 3) in (0, 2) and (word >> 13) in (1, 3, 5, 7)
    opcode = word & 0x7f
    return opcode in (0x07, 0x27, 0x43, 0x47, 0x4b, 0x4f, 0x53) or (
        opcode == 0x73 and ((word >> 12) & 7) != 0 and (word >> 20) in (1, 2, 3))


def audit_heap_layout(symbols, allocated, low=SRAM_LOW, high=SRAM_HIGH):
    start, end = symbols["__heap_start"], symbols["__heap_end"]
    require(low <= symbols["__bss_end"] <= start < end == high and
            start % 64 == 0 and end % 64 == 0 and end - start >= 49152,
            "invalid native heap boundary")
    heap = [section for section in allocated if section["name"] == ".heap"]
    require(len(heap) == 1 and int(heap[0]["address"], 16) == start and
            heap[0]["bytes"] == end - start, "heap section differs from symbols")
    for section in allocated:
        address = int(section["address"], 16)
        if section["name"] != ".heap" and low <= address < high:
            require(address + section["bytes"] <= start, "static section overlaps native heap")
    return {"start": hex(start), "end": hex(end), "bytes": end - start,
            "owner_count": 2, "granule_bytes": 64, "external_bytes": 0}


def audit_stack_section(kind, flags, address, size):
    require(kind == 8 and flags == 3 and address == STACK_LOW and size == STACK_HIGH - STACK_LOW,
            "stacks must be the fixed writable non-executable NOBITS bank")


def audit_high_section(name, kind, flags, address, size, profile):
    low, high = HIGH_BANKS[name]
    require(profile == "device" and kind == 8 and flags == 3 and
            address == low and size == high - low,
            "high SRAM must be a fixed device-only writable non-executable NOBITS bank")


def audit_high_layout(symbols, allocated):
    found = [row for row in allocated if row["name"] in HIGH_BANKS]
    if not found:
        require(not any(name.startswith("__high_sram_") for name in symbols), "orphan high SRAM symbols")
        return None
    require(len(found) == 2 and {row["name"] for row in found} == set(HIGH_BANKS), "missing/duplicate high SRAM bank")
    for name, (low, high) in HIGH_BANKS.items():
        prefix = "__" + name[1:]
        require(symbols.get(prefix + "_start") == low and symbols.get(prefix + "_end") == high,
                "high SRAM symbols differ from fixed banks")
    return {"version": 1, "tested_bytes": 328 * 1024, "heap_bytes": 208 * 1024,
            "guard_bytes": 16 * 1024, "dma_reserve_bytes": 32 * 1024,
            "future_stack_reserve_bytes": 72 * 1024, "page_bytes": 4096,
            "temporary_psram": {"start": "0x48030000", "bytes": 8 * 1024 * 1024}}


def audit_stack_layout(symbols, sizes, allocated):
    expected = {"__stacks_start": STACK_LOW, "__stack0_bottom": STACK_LOW,
                "__stack0_top": STACK_LOW + 8192, "__stack1_bottom": STACK_LOW + 8192,
                "__stack1_top": STACK_LOW + 16384, "__irq_stack0_bottom": STACK_LOW + 16384,
                "__irq_stack0_top": STACK_LOW + 24576, "__irq_stack1_bottom": STACK_LOW + 24576,
                "__irq_stack1_top": STACK_LOW + 32768, "__task_stacks_start": STACK_LOW + 32768,
                "__task_stacks_end": STACK_HIGH, "__stacks_end": STACK_HIGH,
                "native_tasks.stacks": STACK_LOW + 32768}
    require(all(symbols.get(name) == value for name, value in expected.items()), "stack symbols differ from fixed bank layout")
    require(sizes.get("native_tasks.stacks") == 24576, "worker stack array size differs from reservation")
    stacks = [section for section in allocated if section["name"] == ".stacks"]
    require(len(stacks) == 1 and int(stacks[0]["address"], 16) == STACK_LOW and stacks[0]["bytes"] == STACK_HIGH - STACK_LOW,
            "missing/invalid stack bank section")
    trap_bytes = symbols.get('nih_native_task_context_bytes')
    require(trap_bytes is None or trap_bytes == 128, 'invalid task-side trap context reserve')
    return {"start": hex(STACK_LOW), "end": hex(STACK_HIGH), "bytes": STACK_HIGH - STACK_LOW,
            "bootstrap_bytes_per_hart": 8192, "irq_bytes_per_hart": 8192,
            "worker_bytes": 4096, "workers_per_hart": 3, "worker_start": hex(STACK_LOW + 32768),
            "task_side_trap_bytes": trap_bytes, "ordinary_sp_budget_bytes": 3952 if trap_bytes is not None else None}


def stack_size_rows(data, functions):
    """LLVM static frames; this is not a whole-call-stack bound."""
    names = {}
    for name, address, _ in functions:
        names.setdefault(address, []).append(name)
    rows = []
    cursor = 0
    while cursor < len(data):
        require(cursor + 4 <= len(data), "truncated C stack address")
        address = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        value, shift = 0, 0
        while True:
            require(cursor < len(data) and shift < 35, "truncated/overflowing C stack size")
            byte = data[cursor]
            cursor += 1
            value |= (byte & 127) << shift
            shift += 7
            if byte & 128 == 0:
                break
        require(address in names and value <= 0xffffffff, "unknown C stack function/size")
        rows.append({"address": hex(address), "functions": sorted(names[address]), "bytes": value})
    require(rows, "empty C static stack metadata")
    return rows


def decode_stack_sizes(data, functions):
    rows = stack_size_rows(data, functions)
    return {"records": len(rows), "maximum_reported_frame_bytes": max(row["bytes"] for row in rows),
            "largest_frames": sorted(rows, key=lambda row: row["bytes"], reverse=True)[:10],
            "recursive_or_Zig_call_graph_bound": False}


def audit(elf, image, mode=None, profile="device", sqlite_manifest=None, keypad_manifest=None, normal_fs_manifest=None, sqld_manifest=None):
    require(profile in SRAM_PROFILES, "invalid native memory profile")
    low, high, revision = SRAM_PROFILES[profile]
    require(high <= STACK_LOW, "stack bank overlaps primary SRAM")
    require(elf[:7] == b"\x7fELF\x01\x01\x01", "expected ELF32 little endian")
    header = struct.unpack_from("<HHIIIIIHHHHHH", elf, 16)
    kind, machine, _, entry, _, shoff, _, _, _, _, shsize, shnum, shstr = header
    require(kind == 2 and machine == 243, "expected executable RISC-V ELF")
    require(low <= entry < high, "entry outside profile SRAM")
    require(shsize == 40 and shstr < shnum, "invalid section table")
    sections = [struct.unpack_from("<10I", elf, shoff + i * shsize)
                for i in range(shnum)]
    strings = sections[shstr]
    names = elf[strings[4]:strings[4] + strings[5]]

    def string(table, offset):
        require(offset < len(table), "invalid string offset")
        end = table.index(0, offset)
        return table[offset:end].decode("ascii")

    allocated = []
    symbols = {}
    symbol_sizes = {}
    functions = []
    executable = []
    flash_found = set()
    flash_tables = None
    boot_code = None
    pmp_code = b""
    pmp_start = None
    user_code = b""
    user_start = None
    time_code = b''
    time_start = None
    allow_time = any(string(names, section[0]) == '.flash.time' and section[5] for section in sections)
    require(not allow_time or (mode == 'integer' and profile == 'device' and keypad_manifest is None), 'invalid network/time Flash profile')
    device_code = b''
    device_start = None
    allow_devices = any(string(names, section[0]) == '.flash.devices' and section[5] for section in sections)
    require(not allow_devices or (mode == 'integer' and profile == 'device' and keypad_manifest is None), 'invalid device Flash profile')
    xy_sections = {}
    allow_xy = any(string(names, section[0]) in XY_SECTIONS and section[5] for section in sections)
    require(not allow_xy or (mode == 'integer' and sqlite_manifest is None and keypad_manifest is None), 'invalid xy evaluator image profile')
    sqld_sections = {}
    allow_sqld = sqld_manifest is not None
    require(not allow_sqld or (allow_xy and normal_fs_manifest is not None), "sqld requires xy and normal SD owner")
    fs_sections = {}
    allow_fs = normal_fs_manifest is not None
    has_fs = any(string(names, section[0]) in normal_fs_profile.SECTIONS and section[5] for section in sections)
    require(has_fs == allow_fs, 'ordinary FS section/manifest mismatch')
    require(not allow_fs or (mode == 'integer' and profile == 'device' and keypad_manifest is None and sqlite_manifest is None), 'invalid ordinary FS image profile')
    if allow_fs:
        normal_fs_profile.validate(normal_fs_manifest)
    sql_sections = {}
    graph_sections = {}
    allow_sql = mode == "sqlite"
    fatfs_native = (sqlite_manifest or {}).get('fatfs_native')
    if fatfs_native is not None:
        require(allow_sql, 'native FatFs requires SQLite mapped profile')
        fatfs_native_profile.validate_profile(fatfs_native)
    sql_end = FATFS_SQL_END if fatfs_native is not None else SQL_END
    allow_ui = keypad_manifest is not None
    allow_photo = allow_ui and keypad_manifest.get("codec") is not None
    require(not allow_ui or (mode == 'integer' and profile == 'device' and not allow_sql and keypad_manifest.get('schema') == 1), 'invalid keypad profile/manifest')
    card_code = b""
    card_start = None
    photo_sections = {}
    ui_sections = {}
    ui_pools = []
    allow_graphics = mode == "graphics"
    require(not allow_sql or (sqlite_manifest is not None and sqlite_manifest.get("schema") == 1 and
                             sqlite_manifest.get("allowed_functions")), "missing SQLite object manifest")
    for section in sections:
        name_id, section_type, flags, address, offset, size, link, _, _, stride = section
        name = string(names, name_id)
        if flags & 2 and size:  # SHF_ALLOC
            require(section_type not in (14, 15, 16) and name not in (".ctors", ".dtors") and flags & 0x400 == 0,
                    "native CRT does not support dynamic initializers or TLS")
            if name == ".heap":
                require(section_type == 8 and flags & 7 == 3, "heap must be writable NOBITS")
            in_stacks = name == ".stacks"
            if in_stacks:
                audit_stack_section(section_type, flags, address, size)
            in_high = name in HIGH_BANKS
            if in_high:
                audit_high_section(name, section_type, flags, address, size, profile)
            in_sram = low <= address and address + size <= high
            in_ui = name in UI_POOLS
            if in_ui:
                audit_ui_pool(name, section_type, flags, address, size, allow_ui)
                ui_pools.append({'name': name, 'origin': hex(address), 'end': hex(address + size), 'bytes': size})
            in_graphics_ram = name in (".graphics.data", ".graphics.bss", ".graphics.stack")
            if in_graphics_ram:
                require(allow_graphics, "unapproved graphics SRAM reservation")
                audit_graphics_sram(name, section_type, flags, address, size)
                graph_sections[name] = (address, elf[offset:offset+size] if section_type == 1 else b"", size)
            if not in_sram and not in_stacks and not in_ui and not in_high and not in_graphics_ram:
                audit_flash_section(name, section_type, flags, address, size, allow_sql, allow_ui, allow_photo, allow_devices, allow_time, sql_end=sql_end, allow_fs=allow_fs, allow_graphics=allow_graphics, allow_xy=allow_xy, allow_sqld=allow_sqld)
                require(name not in flash_found, "duplicate mapped Flash section")
                flash_found.add(name)
                if name in sqld_profile.SECTIONS:
                    sqld_sections[name] = (address, elf[offset:offset + size])
                if name in XY_SECTIONS:
                    xy_sections[name] = (address, elf[offset:offset + size])
                if name in normal_fs_profile.SECTIONS:
                    fs_sections[name] = (address, elf[offset:offset + size])
                if name == '.flash.time':
                    time_start, time_code = address, elf[offset:offset + size]
                if name == '.flash.devices':
                    device_start, device_code = address, elf[offset:offset + size]
                if name == '.flash.card':
                    card_start, card_code = address, elf[offset:offset + size]
                if name in PHOTO_SECTIONS:
                    photo_sections[name] = (address, elf[offset:offset + size])
                if name in SQL_SECTIONS:
                    sql_sections[name] = (address, elf[offset:offset + size])
                if name in UI_SECTIONS:
                    ui_sections[name] = (address, elf[offset:offset + size])
                if name in GRAPH_SECTIONS:
                    graph_sections[name] = (address, elf[offset:offset + size])
                if name == ".flash.appdesc":
                    audit_app_descriptor(elf[offset:offset + size])
                if name == ".flash.rodata":
                    flash_tables = elf[offset:offset + size]
                    require(len(flash_tables) == size, "truncated Flash tables")
                if name == ".flash.boot":
                    boot_code = elf[offset:offset + size]
                    require(len(boot_code) == size, "truncated Flash boot code")
                if name == ".flash.pmp":
                    pmp_start, pmp_code = address, elf[offset:offset + size]
                if name == ".flash.user":
                    user_start, user_code = address, elf[offset:offset + size]
            allocated.append({"name": name, "address": hex(address), "bytes": size})
            if flags & 4:
                executable.append((name, address, elf[offset:offset + size]))
        if section_type == 2:  # SHT_SYMTAB
            require(stride == 16 and link < shnum, "invalid symbol table")
            table = sections[link]
            symnames = elf[table[4]:table[4] + table[5]]
            for pos in range(offset, offset + size, stride):
                name_id, value, symbol_size, info, _, index = struct.unpack_from("<IIIBBH", elf, pos)
                if not name_id:
                    continue
                symbol = string(symnames, name_id)
                require(index != 0, "unresolved symbol: " + symbol)
                require(not symbol.startswith(("xTask", "vTask", "pxCurrentTCB", "call_start_cpu")),
                        "hosted runtime symbol: " + symbol)
                if info & 15 == 2:  # STT_FUNC
                    functions.append((symbol, value, value + symbol_size))
                symbols[symbol] = value
                symbol_sizes[symbol] = symbol_size
    require((user_start is not None) == ("__user_probe_start" in symbols) == ("__user_probe_end" in symbols), "user probe section/symbol mismatch")
    require(flash_found == set(FLASH_SECTIONS) | {".flash.pmp"} | ({".flash.user"} if user_start is not None else set()) | (GRAPH_SECTIONS if allow_graphics else set()) | (SQL_SECTIONS if allow_sql else set()) | (UI_SECTIONS if allow_ui else set()) | (PHOTO_SECTIONS if allow_photo else set()) | ({".flash.card"} if allow_ui and keypad_manifest.get("ui_mode") == "runtime" else set()) | ({".flash.devices"} if allow_devices else set()) | ({".flash.time"} if allow_time else set()) | (normal_fs_profile.SECTIONS if allow_fs else set()) | (XY_SECTIONS if allow_xy else set()) | (sqld_profile.SECTIONS if allow_sqld else set()), "missing mapped Flash sections")
    service_sram = audit_service_sram(symbols, high, allocated)
    ui_report = None
    ui_payload = None
    if allow_ui:
        require((len(service_sram) == 2 and not ui_pools) or (not service_sram and len(ui_pools) == 2), 'missing/competing display SRAM source')
        pad_start, pad = ui_sections['.flash.uipad']
        start, data = ui_sections['.flash.ui']
        require(pad_start == 0x40010020 + ((len(flash_tables) + 3) & ~3) and not any(pad), 'invalid keypad Flash padding bytes')
        require(symbols.get('__flash_ui_start') == start and symbols.get('__flash_ui_end') == start + len(data), 'invalid keypad Flash symbols')
        audit_ui_assets(start, data, symbols, keypad_manifest)
        ui_payload = flash_tables + bytes((-len(flash_tables)) % 4) + pad + data
        ui_payload += bytes((-len(ui_payload)) % 4)
        ui_report = {'start': hex(start), 'end': hex(start + len(data)), 'bytes': len(data), 'writable': False, 'executable': False,
                     'ui_mode': keypad_manifest.get('ui_mode', 'baked'), 'pools': service_sram or ui_pools}
        if service_sram:
            ui_report['allocation'] = 'base-free-sram-v1'
        if keypad_manifest.get('card_boot'):
            boot = keypad_manifest['card_boot']
            first, last = symbols.get('__card_boot_masks_start', 0), symbols.get('__card_boot_masks_end', 0)
            require(boot.get('schema') == 1 and boot.get('source') == 'sparse-sram-v1' and boot.get('paper') == 0x1924 and
                    0x40010020 <= first < last <= 0x40010020 + len(flash_tables) and
                    last - first == boot.get('mask_bytes') and
                    hashlib.sha256(flash_tables[first - 0x40010020:last - 0x40010020]).hexdigest() == boot.get('mask_sha256'),
                    'card boot mask differs from pinned manifest')
            ui_report['card_boot'] = boot
        ui_report.update({key: value for key, value in keypad_manifest.items() if key in ('font_sha256', 'font_bytes', 'plan_sha256', 'atlas_sha256', 'atlas_bytes', 'nodes')})
    photo_span = None
    photo_report = None
    if allow_photo:
        codec = keypad_manifest['codec']
        require(codec['name'] == 'OpenJPEG' and codec['version'] == '2.5.4' and codec['decode_only'] is True and codec['io'] is False and codec['threads'] is False and codec['htj2k'] is False, 'unsupported photo codec profile')
        require(codec['archive_sha256'] == 'a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a' and codec['workspace_bytes'] == 4*1024*1024-128 and codec['stack_low'] == '0x4ff68000' and codec['stack_high'] == '0x4ff6b000', 'unapproved photo quota/stack/source')
        require(codec['allowed_functions'] == sorted(set().union(*(set(obj['functions']) for obj in codec['objects'].values()))), 'photo function manifest differs from objects')
        code_start, code = photo_sections['.flash.photo']; ro_start, ro = photo_sections['.flash.photo.rodata']
        require(code_start == start + len(data) and ro_start == code_start + len(code) and ro_start + len(ro) <= SQL_END, 'photo sections must be contiguous with read-only UI data')
        require(all(symbols.get(name) == address for name,address in {'__photo_text_start':code_start,'__photo_text_end':ro_start,'__photo_rodata_start':ro_start,'__photo_rodata_end':ro_start+len(ro)}.items()), 'invalid photo section symbols')
        first,last = symbols['__photo_fixture_start'],symbols['__photo_fixture_end']
        require(ro_start <= first < last <= ro_start + len(ro) and hashlib.sha256(ro[first-ro_start:last-ro_start]).hexdigest() == codec['fixture_sha256'], 'synthetic photo fixture mismatch')
        automatic = keypad_manifest.get('automatic_cards')
        jis_first,jis_last=symbols.get('__license_jis_start',0),symbols.get('__license_jis_end',0)
        if automatic:
            require(automatic.get('notice_scanout') == 'sram-double-bank-v1', 'unapproved public notice scanout')
            require(automatic.get('scene_exercise', False) is False or (automatic.get('scene_exercise') is True and automatic['read_enabled'] is False), 'scene exercise cannot enable credentials')
            require(automatic.get('kinds') == ['mynumber','license','myna_license'] and automatic.get('credential_budget_per_pin') == 1 and type(automatic.get('read_enabled')) is bool and automatic.get('jis_bytes') == (17672 if automatic['read_enabled'] else 0), 'unapproved automatic card profile')
            require(ro_start <= jis_first <= jis_last <= ro_start+len(ro) and jis_last-jis_first == automatic['jis_bytes'] and (not automatic['read_enabled'] or hashlib.sha256(ro[jis_first-ro_start:jis_last-ro_start]).hexdigest() == automatic['jis_sha256']), 'JIS mapping differs from automatic card manifest')
            trust_first,trust_last=symbols.get('__license_trust_start',0),symbols.get('__license_trust_end',0)
            require(ro_start<=trust_first<=trust_last<=ro_start+len(ro) and trust_last-trust_first==automatic.get('trust_bytes') and automatic['trust_bytes']%293==0 and automatic['trust_bytes']<=64*293 and (not automatic['read_enabled'] or hashlib.sha256(ro[trust_first-ro_start:trust_last-ro_start]).hexdigest()==automatic.get('trust_sha256')), 'licence trust bundle differs from audited pins')
            if automatic['read_enabled']:
                crypto=keypad_manifest.get('license_crypto',{})
                require(crypto.get('profile')=='npa-raw-sha256-v1_5' and crypto.get('bits')==2048 and crypto.get('exponents')==[3,65537] and crypto.get('stack_bytes')==65536 and crypto.get('external_stack') is True and set(crypto.get('objects',{}))=={'card_crypto.o','card_crypto_stack.o'}, 'unapproved licence crypto profile')
                require(crypto.get('allowed_functions')==sorted(set().union(*(set(obj['functions']) for obj in crypto['objects'].values()))), 'licence crypto function manifest mismatch')
        else:
            require(jis_first == jis_last, 'licence data without automatic card profile')
        forbidden = {'fopen','fclose','fread','fwrite','fprintf','printf','snprintf','vsnprintf','getenv','opj_create_compress','opj_encode','opj_start_compress','opj_pi_initialise_encode','opj_tcd_rateallocate'}
        require(not forbidden.intersection(symbols), 'I/O/encoding API linked in photo decoder')
        photo_span = (code_start,ro_start)
        ui_payload += code + ro
        ui_payload += bytes((-len(ui_payload))%4)
        photo_report = {'name':codec['name'],'version':codec['version'],'decode_only':True,'text_start':hex(code_start),'text_end':hex(ro_start),'rodata_start':hex(ro_start),'rodata_end':hex(ro_start+len(ro)),'text_bytes':len(code),'rodata_bytes':len(ro),'text_sha256':hashlib.sha256(code).hexdigest(),'rodata_sha256':hashlib.sha256(ro).hexdigest(),'workspace_bytes':codec['workspace_bytes'],'stack_low':codec['stack_low'],'stack_high':codec['stack_high']}
        sizes = [elf[section[4]:section[4]+section[5]] for section in sections if string(names,section[0]) == '.stack_sizes']
        require(len(sizes)==1, 'missing photo C stack metadata')
        photo_report['static_c_stack'] = decode_stack_sizes(sizes[0],functions)
        require(photo_report['static_c_stack']['maximum_reported_frame_bytes'] <= 8192, 'photo C frame exceeds isolated stack margin')
    fs_span = None
    fs_report = None
    require(symbols.get('__native_normal_storage', 0) == int(allow_fs), 'ordinary FS build/manifest mismatch')
    if allow_fs:
        pad_start, pad = fs_sections['.flash.fspad']
        text_start, code = fs_sections['.flash.fstext']
        ro_start, data = fs_sections['.flash.fsrodata']
        require(pad_start == 0x40010020 + ((len(flash_tables) + 3) & ~3) and not any(pad), 'invalid ordinary FS padding bytes')
        require(text_start == symbols.get('__flash_fs_text_start') == SQL_START and text_start + len(code) == symbols.get('__flash_fs_text_end') == ro_start == symbols.get('__flash_fs_rodata_start') and ro_start + len(data) == symbols.get('__flash_fs_rodata_end'), 'ordinary FS linker extent mismatch')
        font_start = symbols.get('__flash_console_font_start')
        font_end = symbols.get('__flash_console_font_end')
        require(font_start is not None and font_end is not None and ro_start <= font_start <= font_end <= ro_start + len(data), 'console font outside ordinary FS read-only span')
        fs_span = (text_start, ro_start)
        actual = {n for n, a, b in functions if text_start <= a < b <= ro_start}
        require(normal_fs_profile.REQUIRED.issubset(actual), 'missing ordinary FS runtime functions')
        require(not any(n.startswith('nih_fs_test') for n in symbols), 'host test hook in native FS image')
        identity = normal_fs_profile.validate(normal_fs_manifest)
        at = symbols.get('nih_normal_fs_identity', 0) - ro_start
        require(0 <= at <= len(data) - len(identity) and symbol_sizes.get('nih_normal_fs_identity') == len(identity) and data[at:at + len(identity)] == identity, 'ordinary FS linked input identity mismatch')
        require(len(service_sram) == 2 and not any(name.startswith(('high_sram.', 'nih_broker_')) for name in symbols), 'ordinary FS must use the common service SRAM pool')
        stack_data = [elf[item[4]:item[4] + item[5]] for item in sections if string(names, item[0]) == '.stack_sizes']
        require(len(stack_data) == 1, 'missing ordinary FS frame metadata')
        rows = [row for row in stack_size_rows(stack_data[0], functions) if text_start <= int(row['address'], 16) < ro_start]
        require(rows and max(row['bytes'] for row in rows) <= 3952, 'ordinary FS frame exceeds worker margin')
        require(not {'f_write','f_mkfs','f_unlink','f_rename','f_truncate','f_sync','f_mkdir','malloc','calloc','realloc','free'}.intersection(symbols), 'mutable filesystem or libc heap linked into ordinary FS')
        fs_report = {'profile': list(normal_fs_profile.PROFILE), 'manifest_sha256': normal_fs_profile.digest(normal_fs_manifest).hex(),
                     'text_start': hex(text_start), 'text_bytes': len(code), 'text_sha256': hashlib.sha256(code).hexdigest(),
                     'rodata_start': hex(ro_start), 'rodata_bytes': len(data), 'rodata_sha256': hashlib.sha256(data).hexdigest(),
                     'parent_bytes': 65536, 'worker_stack_bytes': 4096, 'foreground_only': True, 'read_only': True,
                     'static_frames': {'records': len(rows), 'maximum_bytes': max(row['bytes'] for row in rows), 'largest': sorted(rows, key=lambda row: row['bytes'], reverse=True)[:10]}, 'whole_call_stack_qualified': False}
        fs_payload = flash_tables + bytes((-len(flash_tables)) % 4) + pad + code + data
        fs_payload += bytes((-len(fs_payload)) % 4)
    sql_span = None
    sql_report = None
    if allow_sql:
        pad_start, sql_pad = sql_sections[".flash.sqlpad"]
        require(pad_start == FLASH_SECTIONS[".flash.rodata"][0] + ((len(flash_tables) + 3) & ~3) and not any(sql_pad), "invalid nonzero/noncontiguous SQLite padding")
        text_start, sql_code = sql_sections[".flash.sqltext"]
        ro_start, sql_ro = sql_sections[".flash.sqlrodata"]
        text_end, ro_end = text_start + len(sql_code), ro_start + len(sql_ro)
        require(ro_start == text_end and text_end % 16 == 0 and ro_end <= sql_end, "invalid SQLite code/rodata ordering")
        expected_symbols = {"__flash_sql_text_start": text_start, "__flash_sql_text_end": text_end,
                            "__flash_sql_rodata_start": ro_start, "__flash_sql_rodata_end": ro_end}
        require(all(symbols.get(key) == value for key, value in expected_symbols.items()), "SQLite linker symbols differ")
        sql_span = (text_start, text_end)
        sql_funcs = {name: {"start": hex(low), "end": hex(high)} for name, low, high in functions
                     if text_start <= low < high <= text_end}
        require({"nih_sqlite_session_open", "nih_sqlite_session_eval", "nih_sqlite_session_close", "sqlite3_open"}.issubset(sql_funcs),
                "missing actual SQLite/session functions")
        quotas = sqlite_manifest.get("pool_quotas")
        require(isinstance(quotas, list) and len(quotas) == 10 and all(isinstance(n, int) and 0 < n <= 65535 for n in quotas), "invalid SQLite manifest quotas")
        sql_report = {"pool_quotas": quotas, "text_start": hex(text_start), "text_end": hex(text_end), "rodata_start": hex(ro_start),
                      "rodata_end": hex(ro_end), "text_bytes": len(sql_code), "rodata_bytes": len(sql_ro),
                      "functions": sql_funcs, "object_manifest_sha256": hashlib.sha256(json.dumps(sqlite_manifest, sort_keys=True).encode()).hexdigest(),
                      "text_sha256": hashlib.sha256(sql_code).hexdigest(), "rodata_sha256": hashlib.sha256(sql_ro).hexdigest()}
        if 'littlefs' in sqlite_manifest:
            lfs = sqlite_manifest['littlefs']
            require(lfs.get('read_only') is True and lfs.get('no_malloc') is True and
                    lfs.get('revision') == '6cb4e86540eca0d9ba62500a298385c9d863c8be', 'unapproved littlefs build profile')
            require({'lfs_mount', 'lfs_unmount', 'lfs_dir_read', 'lfs_file_read', 'nih_storage_probe'}.issubset(sql_funcs), 'missing littlefs reader functions')
            require(not {'lfs_format', 'lfs_file_write', 'lfs_remove', 'lfs_mkdir', 'lfs_rename', 'lfs_file_truncate'}.intersection(symbols), 'littlefs write API linked')
            sql_report['littlefs'] = lfs
            if 'api_version' in lfs:
                require(lfs['api_version'] == 1 and lfs.get('workspace_bytes') == 8192, 'invalid file API workspace profile')
                require({'nih_ro_init', 'nih_ro_mount', 'nih_ro_stat', 'nih_ro_open', 'nih_ro_read_at', 'nih_ro_close',
                         'nih_ro_release_owner', 'nih_ro_unmount', 'nih_ro_destroy'}.issubset(sql_funcs), 'missing read-only file API functions')
        stack_data = [elf[section[4]:section[4] + section[5]] for section in sections
                      if string(names, section[0]) == ".stack_sizes"]
        require(len(stack_data) == 1, "missing/duplicate C stack metadata")
        sql_report["static_c_stack"] = decode_stack_sizes(stack_data[0], functions)
        if fatfs_native is not None:
            require(profile == 'device' and 'broker' in sqlite_manifest and 'service' not in sqlite_manifest.get('littlefs', {}),
                    'native FatFs requires exclusive broker/storage phase')
            sql_report['fatfs_native'] = fatfs_native_profile.audit(fatfs_native, symbols, symbol_sizes, low, high,
                ro_start, sql_ro, stack_size_rows(stack_data[0], functions), sqlite_manifest['objects'])
            sql_report['static_c_stack']['includes_zig'] = True
        sql_payload = flash_tables + bytes((-len(flash_tables)) % 4) + sql_pad + sql_code + sql_ro
        sql_payload += bytes((-len(sql_payload)) % 4)
        sql_report["padding_bytes"] = len(sql_pad)
    boot_start = FLASH_SECTIONS[".flash.boot"][0]
    boot_end = boot_start + len(boot_code)
    require(symbols.get("__flash_boot_start") == boot_start and symbols.get("__flash_boot_end") == boot_end,
            "Flash boot symbols differ from section")
    graph_report, graph_payload = None, None
    if allow_graphics:
        graph_report, sql_span, graph_payload = audit_graphics(graph_sections, symbols, symbol_sizes, functions, sqlite_manifest, flash_tables)
    allowed_sql = list(sqlite_manifest["allowed_functions"]) if allow_sql or allow_graphics else []
    service = sqlite_manifest.get('littlefs', {}).get('service') if allow_sql else None
    if service is not None:
        require(service.get('version') in (1, 2, 3) and service.get('ipc_start') == '0x48004000' and service.get('ipc_bytes') == 8192 and service.get('clock_group') == 1 and service.get('clock_channel') == 0, 'invalid storage service manifest')
        require({'nih_storage_task_entry', 'nih_storage_runtime_init', 'nih_storage_runtime_finish'}.issubset(sql_funcs), 'missing storage service functions')
        hooks = ('nih_storage_cancel_requested',) if service.get('version') in (2, 3) else ()
        for hook in hooks + ('nih_storage_register', 'nih_storage_pending', 'nih_storage_task_exited', 'nih_storage_cleanup_ready', 'nih_storage_retired'):
            require(hook in symbols and low <= symbols[hook] < high, 'storage IRQ hook outside internal SRAM')
    sd_boot = (symbols.get("__flash_sdmmc_boot_start", 0), symbols.get("__flash_sdmmc_boot_end", 0))
    require(("__flash_sdmmc_boot_start" in symbols) == ("__flash_sdmmc_boot_end" in symbols), "partial SDMMC boot extent")
    if sd_boot[0] != sd_boot[1]:
        require(boot_start <= sd_boot[0] < sd_boot[1] == boot_end, "invalid SDMMC boot extent")
    card_span = None if card_start is None else (card_start, card_start + len(card_code))
    if card_span:
        require(card_start == (boot_end + 15) & ~15 and symbols.get('__flash_card_start') == card_start and symbols.get('__flash_card_end') == card_span[1], 'invalid card foreground symbols')
        handoff = keypad_manifest.get('scene_handoff')
        require(handoff in (None, 'dma-eof-panel-held-v1'), 'unapproved scene handoff')
        exercise = keypad_manifest.get('automatic_cards', {}).get('scene_exercise', False)
        if exercise:
            require(not any(name.startswith('usb_probe.Device.') for name, _, _ in functions), 'card transport linked into card-free scene exercise')
        diagnostics = keypad_manifest.get('diagnostic_reports', [])
        require(diagnostics in ([], ['main.resourceReport', 'main.stackReport'], ['main.taskReport', 'main.floatingReport', 'main.resourceReport', 'main.stackReport']), 'unapproved diagnostic Flash functions')
        require(keypad_manifest.get('allowed_functions') == (([] if keypad_manifest.get('automatic_cards') else ['card_read.prepare', 'card_read.run'] + (['card_read.redraw', 'graphics.card_read_result.Canvas.sizedFlash'] if handoff else [])) + ['keypad_display.prepare'] + ((['keypad_display.bind'] if allow_photo else ['keypad_display.stage', 'keypad_display.bind']) if handoff else []) + ['keypad_display.paintTextures'] + ([] if exercise else ['usb_probe.Device.send', 'usb_probe.Device.scrub', 'usb_probe.Device.powerCut']) + ['display_runtime.start'] + (['display_runtime.replaceCard'] if handoff else []) + diagnostics + (['photo_runtime.prepare'] + ([] if keypad_manifest.get('automatic_cards', {}).get('read_enabled') is False else ['photo_runtime.decode']) + ['photo_runtime.close'] if allow_photo else [])), 'unapproved foreground manifest')
        for prefix in keypad_manifest['allowed_functions']:
            require(sum(1 for name, address, stop in functions if card_span[0] <= address < stop <= card_span[1] and (name == prefix or re.fullmatch(re.escape(prefix) + r'__func_[0-9]+', name))) == 1, 'missing/duplicate card foreground entry: ' + prefix)
        if service_sram:
            for name in ('nih_base_sram_take', 'nih_base_sram_release', 'nih_display_keypad_fits'):
                require(sum(n == name and card_span[0] <= a < b <= card_span[1] for n, a, b in functions) == 1,
                        'missing/duplicate base SRAM foreground entry: ' + name)
    if allow_ui and keypad_manifest.get('card_boot'):
        for name in CARD_BOOT_FUNCTIONS:
            require(sum(n == name and card_span[0] <= a < b <= card_span[1] for n, a, b in functions) == 1,
                    'missing/duplicate card boot foreground entry: ' + name)
    device_span = None if device_start is None else (device_start, device_start + len(device_code))
    device_functions = None
    require(symbols.get('__native_devices', 0) == int(allow_devices), 'device profile marker differs from section')
    if device_span:
        require(device_start == (boot_end + 15) & ~15 and symbols.get('__flash_devices_start') == device_start and symbols.get('__flash_devices_end') == device_span[1], 'invalid device foreground symbols')
        device_functions = audit_device_functions(functions, device_span)
    time_span = None if time_start is None else (time_start, time_start + len(time_code))
    time_functions = None
    require(symbols.get('__native_network', 0) == int(allow_time), 'network profile marker differs from time section')
    if time_span:
        preceding_end = device_span[1] if device_span else boot_end
        require(time_start == (preceding_end + 15) & ~15 and symbols.get('__flash_time_start') == time_start and symbols.get('__flash_time_end') == time_span[1], 'invalid network/time foreground symbols')
        time_functions = audit_time_functions(functions, time_span)
    pmp_span = None if pmp_start is None else (pmp_start, pmp_start + len(pmp_code))
    require(pmp_span is not None and symbols.get("__flash_pmp_start") == pmp_start and symbols.get("__flash_pmp_end") == pmp_span[1],
            "PMP Flash symbols differ from section")
    pmp_functions = audit_pmp_flash(functions, pmp_span)
    user_span = None if user_start is None else (user_start, user_start + len(user_code))
    if user_span:
        require(user_start % 128 == 0 and user_span[1] % 128 == 0 and user_start >= pmp_span[1], "invalid user probe extent")
        require(symbols.get("__user_probe_start") == user_start and symbols.get("__user_probe_end") == user_span[1], "user probe symbols differ from section")
        require({name for name, address, stop in functions if user_span[0] <= address < stop <= user_span[1]} == USER_PROBE_FUNCTIONS, "user probe functions differ")
    flash_start = FLASH_SECTIONS[".flash.rodata"][0]
    xy_span = None
    xy_report = None
    xy_payload = None
    if allow_xy:
        require(set(xy_sections) == XY_SECTIONS, 'missing xy code or data')
        gap_start, gap_data = xy_sections['.flash.xypad']
        preceding = fs_sections['.flash.fsrodata'] if allow_fs else (flash_start, flash_tables)
        require(gap_start == preceding[0] + len(preceding[1]) and gap_start + len(gap_data) == 0x40060000 and not any(gap_data), 'xy padding differs from preceding payload')
        xy_start, xy_code = xy_sections['.flash.xytext']
        xy_ro, xy_data = xy_sections['.flash.xyrodata']
        xy_span = (xy_start, xy_start + len(xy_code))
        require(xy_ro == (xy_span[1] + 15) & ~15 and symbols.get('__flash_xy_start') == xy_start and symbols.get('__flash_xy_text_end') == xy_span[1] and symbols.get('__flash_xy_rodata_start') == xy_ro and symbols.get('__flash_xy_end') == xy_ro + len(xy_data), 'xy linker symbols differ')
        xy_functions = audit_xy_functions(functions, xy_span)
        base = fs_payload if allow_fs else flash_tables + bytes((-len(flash_tables)) % 4)
        require(flash_start + len(base) <= xy_start, 'xy overlaps preceding Flash payload')
        xy_payload = base + bytes(xy_start - flash_start - len(base)) + xy_code + bytes(xy_ro - xy_span[1]) + xy_data
        xy_payload += bytes((-len(xy_payload)) % 4)
        xy_report = {'start': hex(xy_start), 'end': hex(xy_ro + len(xy_data)), 'code_bytes': len(xy_code), 'rodata_bytes': len(xy_data), 'functions': xy_functions, 'foreground_only': True, 'heap_allocated': 'nih_xy_render' in xy_functions, 'render_stack_bytes': 524288 if 'nih_xy_render' in xy_functions else 0}
    sqld_report = None
    require(symbols.get('__native_sqld', 0) == int(allow_sqld), 'sqld symbol/manifest mismatch')
    require(not allow_fs or normal_fs_manifest.get('sqld_enabled', False) == allow_sqld, 'SD write grant/sqld profile mismatch')
    if allow_sqld:
        require(set(sqld_sections) == sqld_profile.SECTIONS, 'missing sqld sections')
        pad_start, pad = sqld_sections['.flash.sqldpad']
        text_start, code = sqld_sections['.flash.sqldtext']
        ro_start, data = sqld_sections['.flash.sqldrodata']
        require(pad_start == flash_start + len(xy_payload) and pad_start + len(pad) == text_start == 0x40400000 and not any(pad), 'sqld padding differs')
        require(text_start == symbols.get('__flash_sqld_start') and text_start + len(code) == symbols.get('__flash_sqld_text_end') and ro_start == symbols.get('__flash_sqld_rodata_start') and ro_start + len(data) == symbols.get('__flash_sqld_end'), 'sqld linker bounds differ')
        identity = b'NIHOS_SQLD1:' + sqld_manifest['identity'].encode() + b'\0'
        at = symbols.get('nih_sqld_identity', 0) - ro_start
        require(0 <= at <= len(data) - len(identity) and data[at:at + len(identity)] == identity, 'sqld linked identity differs')
        allowed_sql = set(sqld_manifest['allowed_functions']) | sqld_profile.FOREGROUND
        allowed_sql |= {n for n,a,b in functions if n.startswith(('compiler_rt.addf3.', 'compiler_rt.mulf3.', 'compiler_rt.divf3.', 'compiler_rt.divsf3.', 'compiler_rt.divdf3.', 'compiler_rt.comparef.', 'compiler_rt.float_from_int.', 'compiler_rt.int_from_float.', 'compiler_rt.extendf.', 'compiler_rt.truncf.')) or n in {'__cmpdf2','__adddf3','__subdf3','__muldf3','__divdf3','__eqdf2','__nedf2','__ltdf2','__ledf2','__gtdf2','__gedf2','__unorddf2','__fixdfsi','__fixdfdi','__fixunsdfsi','__fixunsdfdi','__floatsidf','__floatunsidf','__floatdidf','__floatundidf','__extendsfdf2','__truncdfsf2'} }
        allowed_sql |= {n for n,a,b in functions if re.fullmatch(r'diagnostic_ui\.(?:input|poll|sessionKey|service)__func_[0-9]+',n)}
        sql_span = (text_start, text_start + len(code))
        require(not {'malloc','calloc','realloc','free','fopen','f_write','f_mkfs'}.intersection(symbols), 'libc heap or FAT writer linked in sqld')
        xy_payload += pad + code + bytes(ro_start - text_start - len(code)) + data
        sqld_report = {'identity': sqld_manifest['identity'], 'text_bytes':len(code), 'rodata_bytes':len(data), 'reservation':sqld_manifest['reservation'], 'heap':sqld_manifest['heap'], 'stack':sqld_manifest['stack'], 'media':sqld_manifest['media'], 'provision_cid':sqld_manifest['provision_cid'], 'physical_qualified':False}
    boot_functions = audit_boot_functions(functions, boot_start, boot_end, low, high, sql_span, allowed_sql, card_span, (list(keypad_manifest.get('allowed_functions', ())) + (sorted(SERVICE_SRAM_FUNCTIONS) if service_sram else []) + (sorted(CARD_BOOT_FUNCTIONS) if keypad_manifest.get('card_boot') else [])) if allow_ui else (), photo_span, (keypad_manifest['codec']['allowed_functions']+keypad_manifest.get('license_crypto',{}).get('allowed_functions',[])+(['photo_runtime.cryptoExecute'] if keypad_manifest.get('automatic_cards',{}).get('read_enabled') else [])+(['nih_display_scene_mismatches'] if keypad_manifest.get('automatic_cards',{}).get('scene_exercise') else [])) if allow_photo else (), bool(keypad_manifest.get('automatic_cards')) if allow_ui else False, device_span=device_span, time_span=time_span, sdmmc_span=sd_boot if sd_boot[0] != sd_boot[1] else None, fs_span=fs_span, fs_functions=normal_fs_manifest['allowed_functions'] if allow_fs else (), render_span=(int(graph_report["render"]["start"],16), int(graph_report["render"]["end"],16)) if allow_graphics else None, pmp_span=pmp_span, user_span=user_span, xy_span=xy_span)
    if sd_boot[0] != sd_boot[1]:
        audit_sdmmc_resident(symbols, symbol_sizes, low, high)
    io_lifetimes = sqlite_manifest.get('io_lifetimes') if allow_sql else None
    if io_lifetimes is not None:
        audit_io_lifetimes(io_lifetimes, symbols, symbol_sizes, low, high)
    flash_start = FLASH_SECTIONS[".flash.rodata"][0]
    require(symbols.get("__flash_records_start") == flash_start and
            symbols.get("__flash_records_end") == flash_start + len(flash_tables),
            "Flash record symbols differ from section")
    require(symbols.get("nih_native_start") == entry, "wrong native entry")
    require(symbols.get("__native_profile") == revision, "ELF profile differs from requested layout")
    for name, address in ROM_SYMBOLS.items():
        require(symbols.get(name) == address, "wrong ROM ABI: " + name)
    for name, address in (OPTIONAL_ROM_SYMBOLS | OPTIONAL_ROM_DATA).items():
        if name in symbols:
            require(symbols[name] == address, "wrong optional ROM ABI: " + name)
    fp_linked = "nih_riscv_fpu_save" in symbols
    if fp_linked:
        required = ["nih_riscv_fpu_restore", "nih_riscv_fpu_snapshot"]
        if mode != "compiled":
            required += ["nih_riscv_fpu_task_check", "nih_riscv_fpu_task_probe"]
        require(all(name in symbols for name in required), "partial native FP support")
    require("nih_riscv_fpu_probe_loop" not in symbols and
            "nih_riscv_preemption_budget_expired" not in symbols, "hosted test watchdog linked")
    expected_abi = 2 if mode == "compiled" else 0
    require(header[6] & 0xE == expected_abi, "native FP ABI differs from requested mode")
    fp_counts = {"app": 0, "c": 0, "zig": 0, "transfer_helpers": 0}
    helpers = {"nih_riscv_fpu_save", "nih_riscv_fpu_restore", "nih_riscv_fpu_snapshot",
               "nih_riscv_fpu_task_check", "nih_riscv_fpu_task_probe"}
    for name, address, data in executable:
        position = 0
        while position + 2 <= len(data):
            half = struct.unpack_from("<H", data, position)[0]
            width = 2 if half & 3 != 3 else 4
            require(position + width <= len(data), "truncated executable instruction")
            word = half if width == 2 else struct.unpack_from("<I", data, position)[0]
            if is_fp_instruction(word, width):
                pc = address + position
                owners = [symbol for symbol, low, high in functions if low <= pc < high]
                if any(owner in helpers for owner in owners):
                    fp_counts["transfer_helpers"] += 1
                else:
                    require(mode == "compiled" and name == ".fp_app", "FP instruction outside approved task/helper code")
                    fp_counts["app"] += 1
                    fp_counts["c" if any(owner.startswith("nih_fp_c_") for owner in owners) else "zig"] += 1
            position += width
    if mode == "compiled":
        require(fp_linked and fp_counts["c"] > 0 and fp_counts["zig"] > 0, "missing compiled C/Zig FP instructions")
    stacks = audit_stack_layout(symbols, symbol_sizes, allocated)
    heap = audit_heap_layout(symbols, allocated, low, high)
    high_sram = audit_high_layout(symbols, allocated)
    report = {"schema": 1, "backend": "native-sram", "rtos_linked": False,
              "fp_assembly_linked": fp_linked, "riscv_flags": hex(header[6]), "fp_instructions": fp_counts,
              "entry": hex(entry), "elf_sha256": hashlib.sha256(elf).hexdigest(), "sqld": sqld_report,
              "memory": {"profile": profile, "origin": hex(low), "end": hex(high), "bytes": high - low,
                         "total_bytes": high - low + stacks["bytes"],
                         "regions": [{"name": "resident", "origin": hex(low), "end": hex(high), "bytes": high - low},
                                     {"name": "stacks", "origin": hex(STACK_LOW), "end": hex(STACK_HIGH), "bytes": stacks["bytes"]}]},
              "sram_reserved_bytes": symbols["__heap_start"] - low + stacks["bytes"],
              "primary_static_bytes": symbols["__heap_start"] - low, "stacks": stacks, "heap": heap,
              "flash_boot": {"start": hex(boot_start), "end": hex(boot_end), "bytes": len(boot_code),
                             "sha256": hashlib.sha256(boot_code).hexdigest(), "functions": boot_functions},
              "pmp_flash": {"start": hex(pmp_span[0]), "end": hex(pmp_span[1]), "bytes": len(pmp_code),
                            "sha256": hashlib.sha256(pmp_code).hexdigest(), "functions": pmp_functions},
              "user_probe": None if user_span is None else {"start": hex(user_span[0]), "end": hex(user_span[1]), "bytes": len(user_code),
                            "sha256": hashlib.sha256(user_code).hexdigest(), "executable": True, "writable": False},
              "flash_records": {"start": hex(flash_start), "end": hex(flash_start + len(flash_tables)),
                                "bytes": len(flash_tables), "fnv1a": fnv1a(flash_tables),
                                "executable": False, "writable": False},
              "rom_symbols": {name: hex(value) for name, value in (ROM_SYMBOLS | OPTIONAL_ROM_SYMBOLS | OPTIONAL_ROM_DATA).items() if name in symbols}, "sections": allocated}
    if high_sram is not None:
        report["high_sram"] = high_sram
        report["memory"]["total_bytes"] += high_sram["tested_bytes"]
        report["memory"]["regions"].extend(
            {"name": name[1:], "origin": hex(start), "end": hex(stop), "bytes": stop - start}
            for name, (start, stop) in HIGH_BANKS.items())
    if service_sram:
        report['service_sram'] = service_sram
    if allow_fs:
        report["normal_fs"] = fs_report
    if allow_sql:
        require(not {"malloc", "calloc", "realloc", "free", "localtime", "gmtime", "strftime"}.intersection(symbols),
                "unexpected libc heap/time fallback in native SQLite image")
        report["sqlite"] = sql_report
        if io_lifetimes is not None:
            report["io_lifetimes"] = io_lifetimes
    if allow_ui:
        report['keypad_storage'] = ui_report
        report['memory']['regions'].extend(ui_pools)
        report['memory']['total_bytes'] += sum(pool['bytes'] for pool in ui_pools)
        report['sram_reserved_bytes'] += sum(pool['bytes'] for pool in ui_pools)
    if photo_report is not None:
        report["photo_codec"] = photo_report
        if keypad_manifest.get("automatic_cards"):
            report["automatic_cards"] = keypad_manifest["automatic_cards"]
    if xy_report is not None:
        report['xy_scheme'] = xy_report
    if time_span:
        report['time_text'] = {'start': hex(time_start), 'end': hex(time_span[1]), 'bytes': len(time_code), 'sha256': hashlib.sha256(time_code).hexdigest(), 'functions': time_functions, 'foreground_only': True, 'writable': False, 'executable': True}
    if device_span:
        report['device_text'] = {'start': hex(device_start), 'end': hex(device_span[1]), 'bytes': len(device_code), 'sha256': hashlib.sha256(device_code).hexdigest(), 'functions': device_functions, 'foreground_only': True, 'writable': False, 'executable': True}
    if card_span:
        report['card_text'] = {'start': hex(card_start), 'end': hex(card_span[1]), 'bytes': len(card_code), 'sha256': hashlib.sha256(card_code).hexdigest(), 'writable': False, 'executable': True}
    if allow_graphics:
        report["graphics"] = graph_report
        report["memory"]["regions"] += [{"name": "graphics-stack", "origin": hex(GRAPH_STACK_LOW), "end": hex(GRAPH_STACK_HIGH), "bytes": 32768},
                                         {"name": "graphics-data", "origin": hex(GRAPH_RAM_LOW), "end": hex(GRAPH_RAM_HIGH), "bytes": 32768}]
        report["memory"]["total_bytes"] += 65536
        report["graphics"]["static_occupied_span_bytes"] = symbols["__graphics_bss_end"] - GRAPH_RAM_LOW
        report["sram_reserved_bytes"] += 65536
    broker_manifest = sqlite_manifest.get('broker') if allow_sql else None
    require(('nih_broker_config' in symbols) == (broker_manifest is not None), 'broker configuration/manifest mismatch')
    if broker_manifest is not None:
        require(high_sram is not None and broker_manifest.get('version') in (1, 2), 'broker requires audited high SRAM')
        require({'nih_broker_runtime_init', 'nih_broker_runtime_poll', 'nih_broker_runtime_finish', 'nih_broker_task_entry'}.issubset(sql_funcs), 'missing broker Flash runtime')
        if broker_manifest['version'] == 2:
            require('nih_broker_io_issued' in sql_funcs, 'missing broker ordinary-context IO gate')
        address = symbols['nih_broker_config']
        offset = address - int(sql_report['rodata_start'], 16)
        sql_data = sql_sections['.flash.sqlrodata'][1]
        require(0 <= offset <= len(sql_data) - 56 and symbol_sizes.get('nih_broker_config') == 56, 'broker config outside immutable SQL rodata')
        require(struct.unpack_from('<I', sql_data, offset)[0] == broker_manifest['version'], 'broker config/manifest version mismatch')
        report['broker'] = {**audit_broker(sql_data[offset:offset+56], symbols, low, high, symbols['__heap_start'], profile),
                            'source': broker_manifest}
    cold = audit_cold_flash(sqlite_manifest.get('cold_flash') if allow_sql else None, symbols, functions,
                            low, high, symbols['__heap_start'], sql_span, profile, report.get('broker'))
    if cold is not None:
        report['cold_flash'] = cold
    if image is None:
        return report
    require(image[0] == 0xE9 and struct.unpack_from("<I", image, 4)[0] == entry,
            "image entry differs from ELF")
    position = 24
    image_segments = []
    mapped = []
    first_payload = boot_code
    if card_span:
        first_payload += bytes(card_start - boot_end) + card_code
    if device_span:
        first_payload += bytes(device_start - boot_end) + device_code
    if time_span:
        preceding_end = device_span[1] if device_span else boot_end
        first_payload += bytes(time_start - preceding_end) + time_code
    covered_end = boot_end
    if card_span:
        covered_end = card_span[1]
    if device_span:
        covered_end = device_span[1]
    if time_span:
        covered_end = time_span[1]
    require(pmp_start >= covered_end, "PMP Flash code overlaps earlier boot-page code")
    first_payload += bytes(pmp_start - covered_end) + pmp_code
    if user_span:
        require(user_start >= pmp_span[1], "user probe overlaps PMP code")
        first_payload += bytes(user_start - pmp_span[1]) + user_code
    first_length = 256 + ((len(first_payload) + 3) & ~3)
    for index in range(image[1]):
        address, length = struct.unpack_from("<II", image, position)
        position += 8
        data = image[position:position + length]
        require(len(data) == length, "truncated image segment")
        if index == 0:
            require(address == FLASH_SECTIONS[".flash.appdesc"][0] and length == first_length,
                    "invalid first descriptor/boot-code segment")
            audit_app_descriptor(data[:256])
            require(data[144:176] == hashlib.sha256(elf).digest(), "ELF digest mismatch")
            require(data[256:256 + len(first_payload)] == first_payload, "Flash boot/card bytes differ from ELF")
            report["flash_boot"]["image_offset"] = position + 256
        if address:
            mapped_length = len(xy_payload) if allow_xy else len(graph_payload) if allow_graphics else len(fs_payload) if allow_fs else len(ui_payload) if allow_ui else len(sql_payload) if allow_sql else (len(flash_tables) + 3) & ~3
            require((low <= address and address + length <= high) or
                    (allow_graphics and address == GRAPH_RAM_LOW and length == (graph_sections[".graphics.data"][2] + 3) & ~3) or
                    (address == FLASH_SECTIONS[".flash.appdesc"][0] and length == first_length) or
                    (address == flash_start and length == mapped_length), "unexpected image load range")
            if allow_graphics and address == GRAPH_RAM_LOW:
                require(data[:graph_sections[".graphics.data"][2]] == graph_sections[".graphics.data"][1] and
                        not any(data[graph_sections[".graphics.data"][2]:]), "graphics SRAM initializer differs from ELF")
            if address in (FLASH_SECTIONS[".flash.appdesc"][0], flash_start):
                require(address % 65536 == position % 65536, "Flash image/MMU offset mismatch")
                mapped.append(address)
            if address == flash_start:
                if allow_xy:
                    require(data == xy_payload, 'merged xy image bytes differ from ELF')
                require(data[:len(flash_tables)] == flash_tables, "mapped Flash bytes differ from ELF")
                if allow_fs:
                    require(data == (xy_payload if allow_xy else fs_payload), 'merged records/ordinary FS bytes differ from ELF')
                    report['normal_fs']['image_offset'] = position + SQL_START - flash_start
                if allow_sql:
                    require(data == sql_payload, "merged records/SQLite image bytes differ from ELF")
                    report["sqlite"]["image_offset"] = position + SQL_START - flash_start
                if allow_ui:
                    require(data == ui_payload, 'merged keypad image bytes differ from ELF')
                    report['keypad_storage']['image_offset'] = position + SQL_START - flash_start
                if allow_graphics:
                    require(data == graph_payload, "merged records/graphics image bytes differ from ELF")
                    report["graphics"]["image_offset"] = position + GRAPH_START - flash_start
                report["flash_records"]["image_offset"] = position
            image_segments.append({"address": hex(address), "bytes": length})
        position += length
    require(mapped == [FLASH_SECTIONS[".flash.appdesc"][0], flash_start], "stock loader requires exactly two mapped image sections")
    # ESP image checksum sits at the end of the next 16-byte block.
    checksum_end = (position + 16) & ~15
    require(image[23] == 1 and len(image) == checksum_end + 32, "missing image SHA256")
    require(hashlib.sha256(image[:checksum_end]).digest() == image[checksum_end:],
            "image SHA256 mismatch")
    report.update(image_sha256=hashlib.sha256(image).hexdigest(), image_bytes=len(image), image_segments=image_segments)
    return report


def audit_loader(report, elf):
    """Check the actual pinned loader, including allocated NOBITS data."""
    require(elf[:7] == b"\x7fELF\x01\x01\x01", "expected ELF32 loader")
    header = struct.unpack_from("<HHIIIIIHHHHHH", elf, 16)
    require(header[1] == 243 and header[10] == 40, "unexpected loader ELF")
    sections = [struct.unpack_from("<10I", elf, header[5] + index * 40) for index in range(header[11])]
    low, high = int(report["memory"]["origin"], 16), int(report["memory"]["end"], 16)
    regions = report["memory"].get("regions", [{"name": "resident", "origin": hex(low), "end": hex(high)}]) + report.get("service_sram", [])
    allocated = []
    for _, _, flags, address, _, size, *_ in sections:
        if not flags & 2 or not size:
            continue
        for region in regions:
            require(address + size <= int(region["origin"], 16) or address >= int(region["end"], 16),
                    "native SRAM overlaps live loader in " + region["name"])
        allocated.append({"address": hex(address), "bytes": size})
    higher = [int(section["address"], 16) for section in allocated
              if high <= int(section["address"], 16) < 0x50000000]
    require(bool(higher), "missing live loader SRAM allocations")
    gaps = []
    for region in regions:
        before = [int(section["address"], 16) + section["bytes"] for section in allocated
                  if int(section["address"], 16) + section["bytes"] <= int(region["origin"], 16)]
        after = [int(section["address"], 16) for section in allocated if int(section["address"], 16) >= int(region["end"], 16)]
        gaps.append({"name": region["name"], "gap_below": int(region["origin"], 16) - max(before) if before else None,
                     "gap_above": min(after) - int(region["end"], 16) if after else None})
    return {"elf_sha256": hashlib.sha256(elf).hexdigest(), "allocated": allocated,
            "nearest_higher_address": hex(min(higher)), "gap_bytes": min(higher) - high, "regions_checked": gaps}


def audit_loader_config(text, profile, report=None):
    values = dict(re.findall(r"^#define CONFIG_(CACHE_L2_CACHE_SIZE|CACHE_L2_CACHE_LINE_SIZE|ESP32P4_SELECTS_REV_LESS_V3) (\S+)$", text, re.M))
    require(int(values.get("CACHE_L2_CACHE_SIZE", "0"), 0) == 0x20000 and
            int(values.get("CACHE_L2_CACHE_LINE_SIZE", "0"), 0) == 64,
            "loader cache geometry differs from native layout")
    require(bool(int(values.get("ESP32P4_SELECTS_REV_LESS_V3", "0"), 0)) == (profile == "device"),
            "loader silicon selection differs from native layout")
    # Pinned v5.4.4 application memory.ld.in: early silicon's high RW
    # window ends below the cache; rev3 excludes its low cache prefix.
    supported_low = 0x4ff40000 if profile == "device" else 0x4ff00000 + 0x20000
    supported_high = 0x4ffc0000 - 0x20000 if profile == "device" else 0x4ffaefc0
    require(supported_low <= STACK_LOW < STACK_HIGH <= supported_high, "stack bank outside source-supported SRAM")
    if report is not None and "graphics" in report:
        for start, end in [(GRAPH_STACK_LOW, GRAPH_STACK_HIGH), (GRAPH_RAM_LOW, GRAPH_RAM_HIGH)]:
            require(supported_low <= start < end <= supported_high, "graphics reservation outside source-supported SRAM")
    return {"l2_bytes": 0x20000, "line_bytes": 64, "profile": profile,
            "stack_source_window": {"origin": hex(supported_low), "end": hex(supported_high)},
            "config_sha256": hashlib.sha256(text.encode()).hexdigest()}


def main():
    sqld_manifest = None
    if '--sqld' in sys.argv:
        i = sys.argv.index('--sqld')
        path = Path(sys.argv[i+1]);sqld_manifest = json.loads(path.read_text())
        sqld_profile.verify(path.parent, sqld_manifest)
        del sys.argv[i:i+2]
    normal_manifest = None
    if '--normal-fs' in sys.argv:
        i = sys.argv.index('--normal-fs')
        require(i == len(sys.argv) - 2, 'normal FS manifest must be the last argument')
        path = Path(sys.argv[i + 1])
        normal_manifest = json.loads(path.read_text())
        normal_fs_profile.verify_files(path.parent, normal_manifest)
        sys.argv = sys.argv[:i]
    if len(sys.argv) not in (4, 5, 6, 7, 8, 9, 10):
        raise SystemExit("usage: check-native-image.py ELF BIN|--elf-only REPORT.json [MODE [PROFILE [LOADER.elf [CONFIG.h [SQLITE-MANIFEST.json|--none [KEYPAD-MANIFEST.json]]]]]]")
    try:
        image = None if sys.argv[2] == "--elf-only" else Path(sys.argv[2]).read_bytes()
        report = audit(Path(sys.argv[1]).read_bytes(), image, sys.argv[4] if len(sys.argv) >= 5 else None,
                       sys.argv[5] if len(sys.argv) >= 6 else "device",
                       json.loads(Path(sys.argv[8]).read_text()) if len(sys.argv) >= 9 and sys.argv[8] != '--none' else None,
                       json.loads(Path(sys.argv[9]).read_text()) if len(sys.argv) == 10 else None,
                       normal_fs_manifest=normal_manifest, sqld_manifest=sqld_manifest)
        if len(sys.argv) == 10:
            manifest = json.loads(Path(sys.argv[9]).read_text())
            root = Path(sys.argv[9]).resolve().parents[2]
            if 'codec' in manifest:
                require(all(hashlib.sha256((Path(sys.argv[9]).parent/name).read_bytes()).hexdigest()==obj['sha256'] for name,obj in manifest['codec']['objects'].items()), 'photo object differs from manifest')
            require(all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in manifest['sources'].items()), 'keypad generated source hashes differ')
        if len(sys.argv) >= 5:
            require(sys.argv[4] in ("integer", "floating", "compiled", "sqlite", "graphics"), "invalid FP mode")
            require(report["fp_assembly_linked"] == (sys.argv[4] in ("floating", "compiled")), "FP assembly differs from requested mode")
        if len(sys.argv) >= 7:
            report["loader"] = audit_loader(report, Path(sys.argv[6]).read_bytes())
        if len(sys.argv) >= 8:
            report["loader_config"] = audit_loader_config(Path(sys.argv[7]).read_text(), sys.argv[5], report)
            if 'keypad_storage' in report:
                window = report['loader_config']['stack_source_window']
                require(all(int(window['origin'], 16) <= int(pool['origin'], 16) < int(pool['end'], 16) <= int(window['end'], 16) for pool in report['keypad_storage']['pools']), 'keypad pool outside source-supported SRAM')
    except (ValueError, IndexError, KeyError, struct.error) as error:
        raise SystemExit("Native image audit failed: " + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native image audit passed: SRAM runtime, approved Flash code/tables, known ROM ABI, no RTOS symbols")


if __name__ == "__main__":
    main()

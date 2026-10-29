#!/usr/bin/env python3
"""Reject missing/partial passes, traps, reboots and stopped hart/timer progress."""
import json
from pathlib import Path
import re
import sys
import zlib
import fatfs_native_profile


PSRAM_SIZES = {"0": 0, "4M": 4 << 20, "8M": 8 << 20, "16M": 16 << 20,
               "32M": 32 << 20, "64M": 64 << 20}
STORAGE_FIELDS = ("status", "error_code", "passes", "block_size", "block_count", "entries", "files", "directories", "directory_digest", "file_bytes", "file_crc", "file_name_digest", "reads", "denied_writes")
USB_FIELDS = ("status", "stage", "error_code", "core_id", "port", "speed", "vid", "pid", "config_bytes", "interfaces", "ccid", "bulk_in", "bulk_out", "interrupt_in", "max_message", "transfers", "slot_queries", "card_state", "last_irq", "last_descriptor", "dma_stopped")
JPKI_FIELDS = ("status", "stage", "error_code", "power_status", "power_error", "atr_bytes", "card_state", "apdu_count", "rejected", "pin_data_sent", "auth_before", "auth_after", "last_sw", "serial_bytes", "poweroff")
DISPLAY_PREP_FIELDS = ("status", "stage", "error_code", "panel", "transactions", "frame_start", "frame_bytes", "reserve_bytes", "checksum", "phy_trim", "phy_status", "scanout", "backlight")
CARD_FIELDS = ("status", "stage", "usb", "card", "remaining", "card_fault", "poweroff", "dma_erased", "pin_data_sent", "touch", "width", "height", "slots", "samples", "fresh", "releases", "contacts", "max_contacts", "last_type", "last_flags", "last_error", "last_parameter", "last_bytes", "vbus_off")


def check_display_preparation(log):
    r = fixed_record(log, 'NIHOS_NATIVE_DISPLAY_PREP', DISPLAY_PREP_FIELDS)
    if (r['status'] != 1 or r['stage'] != 6 or r['error_code'] != 0 or r['panel'] not in (1, 2, 3) or
            not 0 < r['transactions'] <= 256 or r['frame_start'] != 0x48030000 or
            r['frame_bytes'] != 720 * 1280 * 2 or r['reserve_bytes'] != 29 * 65536 or
            r['phy_status'] != 3 or r['scanout'] != 0 or r['backlight'] != 0):
        raise ValueError('incomplete display preparation or invalid reservation')
    return r


def check_card(log):
    if log.count('NIHOS_NATIVE_CARD_CHECK_START pin_enabled=0') != 1:
        raise ValueError('missing/duplicate PIN-disabled card mode')
    r = fixed_record(log, 'NIHOS_NATIVE_CARD_CHECK', CARD_FIELDS)
    if (r['status'] != 1 or r['stage'] != 3 or r['usb'] != 1 or r['card'] != 1 or
            r['remaining'] not in (0, 1, 2, 3) or
            r['card_fault'] != {0: 6, 1: 7, 2: 1, 3: 1}[r['remaining']] or
            r['poweroff'] not in (1, 2) or r['dma_erased'] != 1 or r['vbus_off'] != 1 or r['pin_data_sent'] != 0 or
            r['touch'] != 1 or (r['width'], r['height']) != (720, 1280) or not 1 <= r['slots'] <= 10 or
            r['samples'] != 64 or r['fresh'] > 64 or r['contacts'] + r['releases'] != r['fresh'] or
            r['max_contacts'] > r['slots'] or (r['max_contacts'] == 0) != (r['contacts'] == 0) or
            r['last_type'] != 0x81 or r['last_flags'] != (1 if r['poweroff'] == 1 else 0) or r['last_error'] != 0 or
            r['last_parameter'] > 3 or r['last_bytes'] != 0):
        raise ValueError('incomplete PIN-free card/touch readiness check')
    if not log.index('NIHOS_NATIVE_FP_PASS') < log.index('NIHOS_NATIVE_CARD_CHECK_START') < log.index('NIHOS_NATIVE_CARD_CHECK '):
        raise ValueError('card check must follow native qualification')
    return r


def check_jpki(log):
    if log.count('NIHOS_NATIVE_JPKI_MODE pin_input=disabled') != 1:
        raise ValueError('missing/duplicate PIN-free JPKI mode')
    record = fixed_record(log, 'NIHOS_NATIVE_JPKI', JPKI_FIELDS)
    if (record['status'] != 1 or record['stage'] != 6 or record['error_code'] != 0 or
            record['power_status'] != 0 or record['power_error'] != 0 or
            not 2 <= record['atr_bytes'] <= 33 or record['card_state'] != 0 or
            record['apdu_count'] != 7 or record['rejected'] != 0 or record['pin_data_sent'] != 0 or
            not 1 <= record['auth_before'] <= 3 or record['auth_before'] != record['auth_after'] or
            record['last_sw'] != 0x63c0 + record['auth_before'] or
            not 1 <= record['serial_bytes'] <= 20 or record['poweroff'] != 1):
        raise ValueError('incomplete PIN-free JPKI read or changed retry count')
    serials = re.findall(r'^NIHOS_NATIVE_JPKI_SERIAL hex=([0-9a-f]+)$', log, re.M)
    if len(serials) != 1 or log.count('NIHOS_NATIVE_JPKI_SERIAL') != 1 or len(serials[0]) != record['serial_bytes'] * 2:
        raise ValueError('missing/duplicate/malformed JPKI certificate serial')
    # The private raw log contains the requested serial. The public summary
    # records only its length, not the value or the certificate prefix.
    return record


def check_authenticated_owner(log, image, evidence):
    storage = image.get('keypad_storage', {}) if image else {}
    text = image.get('card_text', {}) if image else {}
    if image and image.get('automatic_cards'):
        boot = fixed_record(log, 'NIHOS_NATIVE_CARD_AUTO_BOOT', ('selftest','error_code','stack_used','erased','crypto_selftest','crypto_stack'))
        read_enabled=image['automatic_cards'].get('read_enabled')
        if boot['crypto_selftest'] != int(read_enabled) or (not 0<boot['crypto_stack']<65408 if read_enabled else boot['crypto_stack']!=0):raise ValueError('licence crypto self-test / private stack evidence missing')
        if (evidence != 'physical-device' or storage.get('ui_mode') != 'runtime' or text.get('executable') is not True or text.get('writable') is not False or
                log.count('NIHOS_NATIVE_USB_MODE enabled=1') != 1 or boot['selftest'] != 1 or boot['error_code'] or not 0 < boot['stack_used'] < 12224 or boot['erased'] != 1 or
                any(marker in log for marker in ('NIHOS_NATIVE_USB ', 'NIHOS_NATIVE_JPKI_MODE', 'NIHOS_NATIVE_CARD_CHECK_START'))):
            raise ValueError('incomplete automatic-card owner preparation')
        return {'scope':'automatic card owner; no boot USB/JPKI probe', **boot}
    ready = fixed_record(log, 'NIHOS_NATIVE_CARD_READ_READY', ('remaining_before', 'verifies', 'preflight_cut'))
    if (evidence != 'physical-device' or storage.get('ui_mode') != 'runtime' or storage.get('font_bytes', 0) <= 0 or
            text.get('writable') is not False or text.get('executable') is not True or
            log.count('NIHOS_NATIVE_USB_MODE enabled=1') != 1 or
            ready['remaining_before'] not in (2, 3) or ready['verifies'] != 0 or ready['preflight_cut'] != 1 or
            any(marker in log for marker in ('NIHOS_NATIVE_USB ', 'NIHOS_NATIVE_JPKI_MODE', 'NIHOS_NATIVE_CARD_CHECK_START'))):
        raise ValueError('incomplete authenticated-owner preparation')
    return {'scope': 'PIN-free authenticated-owner preparation; boot USB probe not run', **ready}


def check_usb(log):
    if log.count("NIHOS_NATIVE_USB_MODE enabled=1") != 1:
        raise ValueError("missing/duplicate native USB mode")
    record = fixed_record(log, "NIHOS_NATIVE_USB", USB_FIELDS)
    if (record['status'] != 1 or record['stage'] != 8 or record['error_code'] != 0 or
            record['core_id'] not in (0x4f54400a, 0x4f54430a) or
            record['port'] & 0x15 != 5 or record['speed'] not in (0, 1) or
            not 0 < record['vid'] <= 0xffff or not 0 < record['pid'] <= 0xffff or
            not 9 <= record['config_bytes'] <= 512 or not 0 < record['interfaces'] <= 255 or
            record['ccid'] != 1 or not 0x81 <= record['bulk_in'] <= 0x8f or
            not 1 <= record['bulk_out'] <= 15 or
            record['interrupt_in'] not in (0, *range(0x81, 0x90)) or
            not 10 <= record['max_message'] <= 4096 or record['transfers'] != 22 or
            record['slot_queries'] != 3 or record['card_state'] not in (0, 1, 2) or
            record['last_irq'] & 3 != 3 or record['last_irq'] & 0x190c != 0 or
            record['last_descriptor'] & 0xb0000000 != 0 or record['dma_stopped'] != 1):
        raise ValueError("incomplete native USB/CCID qualification")
    return record

REBIND_FIELDS = ("rebound", "replacement_owner", "old_epoch_rejected", "old_reply_rejected", "old_handle_rejected", "old_exit_rejected", "replacement_exit", "replacement_bytes", "replacement_crc")
CANCEL_FIELDS = ("forced_exit", "inflight_completed", "discarded_requests", "discarded_responses")
SERVICE_FIELDS = ("status", "requests", "responses", "queue_full", "rejected", "bytes", "crc", "owner", "exit_seen", "released", "stale_rejected", "owner_stack", "client_stack", "peer_polls", "elapsed_us", "clock_ok", "fs_cleared", "ipc_cleared")
STORAGE_API_FIELDS = ('status', 'opens', 'closes', 'cancelled', 'rejected', 'read_calls', 'workspace_bytes', 'used_bytes', 'cleared')


FATFS_FIELDS = ('version', 'source', 'status', 'fixture_id', 'parent_used', 'parent_charged',
                'requests', 'replies', 'forced_exit', 'cancelled', 'discarded_requests', 'discarded_replies',
                'rebound', 'stale_epoch', 'stale_handle', 'stale_reply', 'stale_exit', 'bytes', 'crc',
                'owner_stack', 'client_stack', 'parent_cleared', 'recovered')
FATFS_CARD_FIELDS = ('status','generation','sectors','kind','partition','first','count','bytes','crc','repeated_crc',
               'file_name_crc','reads','destroyed','charged','cleared','recovered')

def check_fatfs_card(log, image, evidence):
    config = (image or {}).get('sqlite',{}).get('fatfs_native',{}).get('card')
    marker = 'NIHOS_NATIVE_FATFS_CARD'
    if config is None:
        if marker in log or 'NIHOS_FATFS_SD_READY' in log:
            raise ValueError('physical card record without bound source profile')
        return None
    if evidence != 'physical-device' or image.get('memory',{}).get('profile')!='device':
        raise ValueError('card read requires physical evidence')
    fatfs_native_profile.validate_profile(image['sqlite']['fatfs_native'])
    r = fixed_record(log,marker,FATFS_CARD_FIELDS)
    stack = fixed_record(log,'NIHOS_NATIVE_FATFS_CARD_STACK',('used','preserved'))
    if stack['preserved']!=1 or not 0<stack['used']<(3920 if config.get('rpc') else 8000):
        raise ValueError('physical card stack margin/guard failed')
    if (any(r[k]!=1 for k in ('status','destroyed','cleared','recovered')) or r['generation']==0 or
        r['kind'] not in (1,2,3,4) or not 0<=r['partition']<=4 or r['charged']!=config['charged'] or
        not 0<r['count']<=r['sectors']-r['first'] or not 0<r['bytes']<=4096 or
        r['reads']==0 or r['crc']!=r['repeated_crc']):
        raise ValueError('incomplete physical card read/cleanup')
    order = ('NIHOS_NATIVE_FATFS_RPC ', 'NIHOS_FATFS_SD_READY', marker+' ', 'NIHOS_NATIVE_FP_PASS ')
    if config.get('rpc'):order=(order[1],order[0],order[2],order[3])
    if any(part not in log for part in order) or any(log.index(a)>=log.index(b) for a,b in zip(order,order[1:])):
        raise ValueError('physical card phases out of order')
    return {**r, 'stack':stack, 'source':config['source'], 'comparison':'same file prefix read twice; no external content oracle',
            'native_rpc_over_sd_qualified':config.get('rpc',False),
            'stack_scope':'FSD/client workers maximum' if config.get('rpc') else 'bootstrap owner'}


def check_sqlite_spans(record, image, evidence):
    end = 0x400c0000
    config = (image or {}).get('sqlite', {}).get('fatfs_native')
    if config is not None:
        if evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device':
            raise ValueError('expanded SQLite Flash requires audited physical fixture')
        fatfs_native_profile.validate_profile(config)
        end = int(config['flash_end'], 16)
    if not (record['text_start'] == 0x40020000 < record['text_end'] <= record['rodata_start'] < record['rodata_end'] <= end):
        raise ValueError('invalid SQLite Flash spans')


def check_fatfs_native(log, image, evidence):
    config = (image or {}).get('sqlite', {}).get('fatfs_native')
    marker = 'NIHOS_NATIVE_FATFS_RPC'
    if config is None:
        if marker in log:
            raise ValueError('FatFs fixture record without bound image')
        return None
    if evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device':
        raise ValueError('native FatFs task record requires physical device evidence')
    if config.get('source') != 'embedded sparse/RLE FAT12 fixture; not SD FatFs' or config.get('version') not in (1, 2, 3):
        raise ValueError('unknown native FatFs fixture source/version')
    record = fixed_record(log, marker, FATFS_FIELDS)
    expected = dict.fromkeys(FATFS_FIELDS, 1)
    expected.update(fixture_id=config['fixture']['fixture_id'], parent_used=38656, parent_charged=65536,
                    requests=8, replies=6, bytes=24, crc=zlib.crc32(b'nihos read-only fixture\n'))
    if config.get('card',{}).get('rpc'):
        card=check_fatfs_card(log,image,evidence)
        expected.update(version=2,source=2,fixture_id=0,parent_used=config['card']['rpc_parent_used'],
                        requests=11,replies=9,bytes=card['bytes'],crc=card['crc'])
    for key, value in expected.items():
        if key in ('owner_stack', 'client_stack'):
            if not 0 < record[key] < 3920:
                raise ValueError('FatFs worker stack guard not preserved')
        elif record[key] != value:
            raise ValueError('incomplete native FatFs fixture gate: ' + key)
    if config.get('card',{}).get('rpc') and card['stack']['used']!=max(record['owner_stack'],record['client_stack']):
        raise ValueError('card RPC stack records disagree')
    order = ('NIHOS_NATIVE_BROKER ', 'NIHOS_NATIVE_IO_LIFETIMES ', marker + ' ', 'NIHOS_NATIVE_FP_PASS ')
    if not all(part in log for part in order) or any(log.index(a) >= log.index(b) for a, b in zip(order, order[1:])):
        raise ValueError('native FatFs task phases out of order')
    return {**record, 'input_source': config['card']['source'] if config.get('card',{}).get('rpc') else config['source'],
            'physical_sd_fatfs_qualified':config.get('card',{}).get('rpc',False),
            **({'controller_abort_qualified':False} if config.get('card',{}).get('cancel_relay') else {})}


def check_storage_api(record, storage):
    count = 4 if storage['status'] == 2 else 0
    reads = 2 * ((storage['file_bytes'] + 511) // 512 + 2) if count else 0
    if (record['status'] != 1 or record['opens'] != count or record['closes'] != count or
            record['cancelled'] != count // 2 or record['rejected'] != count * 2 or record['read_calls'] != reads or
            record['workspace_bytes'] != 8192 or not 0 < record['used_bytes'] <= 8192 or record['cleared'] != 1):
        raise ValueError('incomplete file API ownership/cleanup qualification')
    return record


def check_storage(record, sectors):
    if (record['status'] not in (1, 2) or record['error_code'] != 0 or record['passes'] != 2 or
            record['block_size'] not in (512, 4096) or record['block_count'] * record['block_size'] != sectors * 512 or
            record['entries'] > 128 or record['files'] + record['directories'] != record['entries'] or
            not 0 < record['reads'] <= 8192 or record['denied_writes'] != 0):
        raise ValueError('incomplete read-only littlefs qualification')
    if record['status'] == 2:
        if not 0 < record['file_bytes'] <= 65536 or record['files'] == 0:
            raise ValueError('incomplete littlefs file read')
    elif record['file_bytes'] or record['file_crc'] or record['file_name_digest']:
        raise ValueError('unexpected file data in directory-only qualification')
    return record


def check_boot_headers(log, automatic_cards=False, card_boot=False):
    headers = re.findall(r"^NIHOS_[A-Z0-9_]*_BOOT(?= |$)", log, re.MULTILINE)
    expected = (["NIHOS_NATIVE_BOOT"] + (["NIHOS_NATIVE_CARD_BOOT"] * 2 if card_boot else []) +
                (["NIHOS_NATIVE_CARD_AUTO_BOOT"] if automatic_cards else []))
    if (log.count("NIHOS_NATIVE_BOOT backend=zig-sram rtos=none") != 1 or
            headers != expected or log.count("ESP-ROM:esp32p4") > 1):
        raise ValueError("missing boot, unexpected reboot or mixed firmware capture")


def repeated_records(log, marker, names):
    pattern = re.escape(marker) + "".join(" " + name + r"=([0-9a-f]{8})" for name in names)
    found = [match.groups() for match in re.finditer(pattern + r"(?:\n|$)", log)]
    if len(found) != log.count(marker + " "):
        raise ValueError("missing/duplicate/malformed " + marker)
    return [dict(zip(names, (int(value, 16) for value in row))) for row in found]


def fixed_record(log, marker, names):
    found = repeated_records(log, marker, names)
    if len(found) != 1:
        raise ValueError("missing/duplicate/malformed " + marker)
    return found[0]


def check_fast_psram(log, evidence, normal_boot=False):
    if 'NIHOS_NATIVE_PSRAM_TUNING ' not in log:
        if 'NIHOS_NATIVE_PSRAM_LINK ' in log:
            raise ValueError('PSRAM200 register report requires tuning evidence')
        return None
    if evidence != 'physical-device':
        raise ValueError('PSRAM200 requires physical-device evidence')
    pll = fixed_record(log, 'NIHOS_NATIVE_PSRAM_MPLL', ('status', 'mhz', 'reused', 'divider', 'error_code'))
    tuning = fixed_record(log, 'NIHOS_NATIVE_PSRAM_TUNING',
                          ('status', 'stage', 'phase_mask', 'phase', 'delay_mask', 'delay', 'repetitions', 'reads', 'writes', 'error_code'))
    link = fixed_record(log, 'NIHOS_NATIVE_PSRAM_LINK',
                        ('core', 'bus', 'command', 'sctrl', 'cmd', 'ddr', 'dll_cache', 'dll_command', 'dqs0', 'dqs1'))
    def window(mask, count):
        best = (0, 0)
        run = 0
        for index in range(count):
            run = run + 1 if mask & (1 << index) else 0
            if run > best[1]:
                best = (index + 1 - run, run)
        return best
    valid_taps = bin(tuning['delay_mask']).count('1')
    reads_valid = tuning['reads'] == 99392
    if normal_boot:
        reads_valid = ((6 + valid_taps * 100 + 31 - valid_taps) * 32 <= tuning['reads'] <= 99392 and tuning['reads'] % 32 == 0)
    phase, phase_length = window(tuning['phase_mask'], 4)
    delay_start, delay_length = window(tuning['delay_mask'], 31)
    delay = delay_start + (delay_length - 1) // 2
    if (pll['status'] != 1 or pll['mhz'] != 400 or pll['reused'] not in (0, 1) or
            pll['divider'] != 0x99 or pll['error_code'] or
            tuning['status'] != 1 or tuning['stage'] != 4 or tuning['error_code'] or
            tuning['phase_mask'] >> 4 or tuning['delay_mask'] >> 31 or
            not phase_length or delay_length < 2 or tuning['phase'] != phase or tuning['delay'] != delay or
            tuning['repetitions'] != 100 or not reads_valid or tuning['writes'] != 32):
        raise ValueError('incomplete PSRAM200 PLL/tuning qualification')
    dqs = max(15 - delay, 0)
    if (link['core'] >> 12 & 3 != 1 or link['core'] >> 16 & 255 != 0 or
            link['bus'] != 0x10001 or link['command'] != 0x10001 or
            link['sctrl'] >> 6 & 63 != 25 or link['sctrl'] >> 22 & 63 != 11 or
            link['cmd'] & (3 << 26) != 3 << 26 or link['ddr'] & 31 != 3 or
            not link['dll_cache'] & 32 or not link['dll_command'] & 32 or
            any(value >> 1 & 3 != phase or value >> 7 & 15 != dqs or value >> 17 & 15 != dqs
                for value in (link['dqs0'], link['dqs1']))):
        raise ValueError('PSRAM200 register readback does not match selected timing')
    return {'mpll': pll, 'tuning': tuning, 'link': link}


def check_cpu_clock(log, image, evidence):
    cpu_clock = None
    clock_function = image.get('flash_boot',{}).get('functions',{}).get('clock') if image else None
    if clock_function is not None or 'NIHOS_NATIVE_CPU_CLOCK ' in log:
        cpu_clock = fixed_record(log,'NIHOS_NATIVE_CPU_CLOCK',('status','error_code','pc','source','cpll_mhz','before_mhz','after_mhz','mem_mhz','apb_mhz','ctrl0','ctrl1','ctrl2','rom_mhz'))
        c = cpu_clock
        if (clock_function is None or evidence != 'physical-device' or c['status'] != 1 or c['error_code'] or c['source'] != 1 or
                c['cpll_mhz'] != 360 or c['rom_mhz'] != 360 or c['mem_mhz'] != 180 or c['apb_mhz'] != 90 or
                not 358 <= c['after_mhz'] <= 362 or not any(abs(c['before_mhz']-mhz) <= 2 for mhz in (90,180,360)) or
                c['ctrl0'] & 0x1ffffff0 or c['ctrl1'] != 1 or c['ctrl2'] & 0x00ffffff != 0x10000 or
                not int(clock_function['start'],16) <= c['pc'] < int(clock_function['end'],16) or c['pc']%2 or
                log.index('NIHOS_NATIVE_CPU_CLOCK ') > log.index('NIHOS_NATIVE_PSRAM ')):
            raise ValueError('incomplete native CPU clock initialization')
    return cpu_clock


HIGH_FIELDS = ('status', 'bytes', 'passes', 'reads', 'writes', 'peer_reads', 'peer_writes', 'owner_reads', 'heap_bytes', 'free_bytes', 'guards', 'rejected', 'checks0', 'checks1', 'checks2', 'checks3', 'recovered')
PAGE_FIELDS = ('status', 'start', 'bytes', 'requested4', 'charged4', 'requested8', 'charged8', 'reads', 'writes', 'boundary_ok', 'recovered')
BROKER_FIELDS_V1 = ('status','old_api_denied','metadata','internal_bytes','internal_free','external_bytes','external_free',
                 'internal_floor','external_floor','requested4','charged4','requested8','charged8','client','replacement',
                 'requests','responses','rejected','exits','reaped','pin_waited','borrow_completed','stale_identity',
                 'stale_lease','guards','recovered','client_stack')
BROKER_IO_FIELDS = ('forced_client','after_forced','forced_exit','io_issued','io_completed','io_bytes','io_crc',
                    'expected_crc','pinned_after_kill','completion_after_exit','discarded_responses','io_clock_acquired','io_clock_released')
BROKER_FIELDS = BROKER_FIELDS_V1 + BROKER_IO_FIELDS


SDMMC_FIELDS = ("status", "stage", "command", "interrupts", "response", "commands", "sectors_low", "sectors_high", "reads", "crc0", "crc1", "crc_middle", "crc_last", "bus_bits", "clock_khz", "writes", "error_code", "host_status", "data_words", "dma")
IO_LIFETIME_FIELDS = ('version', 'status', 'normal_reads', 'cancelled', 'removed', 'stale_rejected',
                      'idle_denied', 'fences', 'unpublished', 'crc', 'ctrl', 'dma_mode', 'dma_fsm',
                      'irq_mask', 'dma_mask', 'descriptor', 'descriptor_word')
SD_REMOVAL_FIELDS = ('version', 'status', 'before_reads', 'failed_command', 'failed_interrupts',
                     'unpublished', 'fenced', 'idle_denied', 'stale_rejected', 'reinserted',
                     'after_reads', 'crc', 'generation_before', 'generation_after',
                     'ctrl', 'dma_mode', 'dma_fsm', 'irq_mask', 'dma_mask', 'descriptor', 'descriptor_word')


def parse_reset_capture(log, image):
    capture_format = image.get('io_lifetimes', {}).get('capture_format', 1)
    if type(capture_format) is not int or capture_format not in (1, 2):
        raise ValueError('unknown capture format')
    fields = ('cpu0', 'ack')
    if capture_format == 2:
        fields += ('raw_cause', 'lp', 'cpu1', 'reset_flags', 'saved_pc0', 'saved_pc1',
                   'clock_gates', 'wdt_valid', 'wdt0', 'wdt1')
    record = fixed_record(log, 'NIHOS_NATIVE_RESET', fields)
    if not 0 < record['cpu0'] < 64 or record['ack'] != 1:
        raise ValueError('invalid reset reason/acknowledgment')
    if capture_format == 2:
        raw = record['raw_cause']
        valid = (record['clock_gates'] >> 21) & 3
        flags = ((raw >> 6) & 1) | (((raw >> 13) & 1) << 1) | (((raw >> 20) & 1) << 2)
        if (record['cpu0'] != (raw >> 7) & 63 or record['lp'] != raw & 63 or
                record['cpu1'] != (raw >> 14) & 63 or record['reset_flags'] != flags or
                record['wdt_valid'] != valid or (not valid & 1 and record['wdt0']) or
                (not valid & 2 and record['wdt1'])):
            raise ValueError('inconsistent early reset snapshot')
    return record


def check_boot_capture(log, image, evidence):
    configured = (image or {}).get('io_lifetimes', {}).get('capture_handshake') is True
    if not configured:
        if 'NIHOS_NATIVE_RESET' in log or 'NIHOS_CAPTURE_WAIT' in log:
            raise ValueError('capture record without bound image configuration')
        return None
    if evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device':
        raise ValueError('boot capture requires physical device evidence')
    record = parse_reset_capture(log, image)
    if ('NIHOS_CAPTURE_WAIT\n' not in log or
            not log.index('NIHOS_CAPTURE_WAIT\n') < log.index('NIHOS_NATIVE_RESET ') < log.index('NIHOS_NATIVE_BOOT ')):
        raise ValueError('incomplete early reset capture/acknowledgment')
    reasons = re.findall(r'rst:0x([0-9a-f]+)\s*\(', log)
    if len(reasons) > 1 or any(int(value, 16) != record['cpu0'] for value in reasons):
        raise ValueError('mixed ROM and latched reset evidence')
    return record


def check_sd_removal(log, image, evidence, sdmmc):
    config = (image or {}).get('io_lifetimes', {})
    if config.get('removal_test') is not True:
        if 'NIHOS_NATIVE_SD_REMOVAL' in log or 'NIHOS_SD_REMOVE_READY' in log or 'NIHOS_SD_INSERT_READY' in log:
            raise ValueError('SD removal record without opt-in image configuration')
        return None
    if (evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device' or
            config.get('version') != 1 or config.get('qualification') is not True):
        raise ValueError('SD removal qualification requires bound physical device evidence')
    record = fixed_record(log, 'NIHOS_NATIVE_SD_REMOVAL', SD_REMOVAL_FIELDS)
    for marker in ('NIHOS_SD_REMOVE_READY', 'NIHOS_SD_INSERT_READY'):
        if log.count(marker + '\n') != 1:
            raise ValueError('missing/duplicate SD operator phase')
    if not (log.index('NIHOS_NATIVE_IO_LIFETIMES ') < log.index('NIHOS_SD_REMOVE_READY\n') <
            log.index('NIHOS_SD_INSERT_READY\n') < log.index('NIHOS_NATIVE_SD_REMOVAL ')):
        raise ValueError('SD removal phases out of order')
    expected = dict.fromkeys(SD_REMOVAL_FIELDS, 0)
    expected.update(version=1, status=1, before_reads=record['before_reads'], failed_command=17,
                    failed_interrupts=record['failed_interrupts'], unpublished=1, fenced=1, idle_denied=1,
                    stale_rejected=2, reinserted=1, after_reads=2, crc=sdmmc['crc0'],
                    generation_before=record['generation_before'], generation_after=record['generation_before'] + 1)
    if record != expected or not 0 < record['before_reads'] < 20000 or record['generation_before'] < 3:
        raise ValueError('incomplete SD read failure, quiescence or reinsertion qualification')
    # Operator confirmation is external evidence. This record alone cannot
    # prove that a person physically removed the card rather than another fault.
    return record


def check_io_lifetimes(log, image, evidence, sdmmc):
    config = (image or {}).get('io_lifetimes')
    if config is None or not config.get('qualification'):
        if 'NIHOS_NATIVE_IO_LIFETIMES' in log:
            raise ValueError('I/O lifetime record without image qualification configuration')
        return None
    if config.get('version') != 1 or evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device':
        raise ValueError('I/O lifetime qualification requires bound physical device evidence')
    record = fixed_record(log, 'NIHOS_NATIVE_IO_LIFETIMES', IO_LIFETIME_FIELDS)
    expected = dict.fromkeys(IO_LIFETIME_FIELDS, 0)
    expected.update(version=1, status=1, normal_reads=2, cancelled=1, removed=1, stale_rejected=3,
                    idle_denied=1, fences=2, unpublished=2, crc=sdmmc['crc0'])
    if record != expected:
        raise ValueError('incomplete SD stop, quarantine or cache/descriptor handback qualification')
    return record


def check_broker(log, image, evidence):
    config = (image or {}).get('broker')
    if config is None:
        if 'NIHOS_NATIVE_BROKER' in log:
            raise ValueError('broker record without image configuration')
        return None
    if evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device':
        raise ValueError('broker handoff requires bound physical device evidence')
    version = config.get('version', 1)
    if version not in (1, 2):
        raise ValueError('unsupported broker qualification version')
    record = fixed_record(log, 'NIHOS_NATIVE_BROKER', BROKER_FIELDS if version == 2 else BROKER_FIELDS_V1)
    expected = {'status':1,'old_api_denied':4,'metadata':config['metadata_bytes'],
                'internal_bytes':config['internal_bytes'],'internal_free':config['internal_bytes'],
                'external_bytes':config['external_bytes'],'external_free':config['external_bytes'],
                'internal_floor':config['internal_floor'],'external_floor':config['external_floor'],
                'requested4':4<<20,'charged4':4<<20,'requested8':8<<20,'charged8':8<<20,
                'requests':9,'responses':9,'rejected':5,'exits':2,'reaped':2,'pin_waited':2,'borrow_completed':2,
                'stale_identity':2,'stale_lease':1,'guards':16384,'recovered':1}
    if version == 2:
        sd = fixed_record(log, 'NIHOS_NATIVE_SDMMC', SDMMC_FIELDS)
        expected.update({'requests':16,'responses':15,'rejected':8,'exits':4,'reaped':4,'pin_waited':4,
                         'borrow_completed':4,'stale_identity':3,'stale_lease':2,'forced_exit':1,
                         'io_issued':1,'io_completed':1,'io_bytes':512,'io_crc':sd['crc0'],'expected_crc':sd['crc0'],
                         'pinned_after_kill':1,'completion_after_exit':1,'discarded_responses':1,'io_clock_acquired':1,'io_clock_released':1})
        ids = [record[key] for key in ('client','replacement','forced_client','after_forced')]
        if any(b & 65535 != a & 65535 or b >> 16 != (a >> 16) + 1 for a,b in zip(ids, ids[1:])):
            raise ValueError('broker forced exit generation/rebind mismatch')
    if any(record[key] != value for key,value in expected.items()):
        raise ValueError('incomplete broker retirement, lease or recovery qualification')
    first,second = record['client'],record['replacement']
    if (first & 65535 == 0 or first >> 16 == 0 or first & 65535 != second & 65535 or
            second >> 16 != (first >> 16) + 1 or not 0 < record['client_stack'] < 3920):
        raise ValueError('broker client generation/reap/stack mismatch')
    return record


def check_high(log, image, evidence):
    metadata = (image or {}).get('high_sram')
    if metadata is None:
        if 'NIHOS_NATIVE_HIGH_SRAM' in log or 'NIHOS_NATIVE_PAGE_LEASE' in log:
            raise ValueError('high SRAM evidence without image reservation')
        return None, None
    if evidence != 'physical-device' or image.get('memory', {}).get('profile') != 'device':
        raise ValueError('high SRAM requires bound physical device evidence')
    high = fixed_record(log, 'NIHOS_NATIVE_HIGH_SRAM', HIGH_FIELDS)
    page = fixed_record(log, 'NIHOS_NATIVE_PAGE_LEASE', PAGE_FIELDS)
    expected = (1, metadata['tested_bytes'], 2, 167936, 167936, 83968, 83968, 83968,
                metadata['heap_bytes'], metadata['heap_bytes'], metadata['guard_bytes'], 3)
    if tuple(high[key] for key in HIGH_FIELDS[:12]) != expected or high['recovered'] != 1 or any(high[key] < 4 for key in HIGH_FIELDS[12:16]):
        raise ValueError('incomplete high SRAM read/write, lease or guard qualification')
    if tuple(page.values()) != (1, int(metadata['temporary_psram']['start'], 16), metadata['temporary_psram']['bytes'],
                                 4 << 20, 4 << 20, 8 << 20, 8 << 20, 3145728, 3145728, 1, 1):
        raise ValueError('incomplete exact-size PSRAM lease qualification')
    return high, page


def check(log, expected_mode=None, expected_psram_bytes=0, image=None, evidence="emulator",
          require_qualification=False, require_sdmmc=False, require_sdmmc_fast=False, require_storage=False,
          external_reserved_bytes=3 * 65536, require_normal=False, headless_case=0,
          require_usb=False, require_jpki=False, require_card=False, canvas_offscreen=False):
    if external_reserved_bytes not in (3 * 65536, 2 << 20):
        raise ValueError("unknown external reservation")
    if (image or {}).get('broker') is not None and expected_psram_bytes != 32 << 20:
        raise ValueError('broker handoff requires exactly 32 MiB PSRAM')
    if evidence not in ("emulator", "physical-device"):
        raise ValueError("invalid evidence source")
    service_metadata = image.get('sqlite', {}).get('littlefs', {}).get('service') if image is not None else None
    service_expected = service_metadata is not None
    rebind_expected = service_expected and service_metadata.get('version') == 3
    cancel_expected = service_expected and service_metadata.get('version') in (2, 3)
    profile = image.get("memory", {}).get("profile") if image is not None else None
    if evidence == "physical-device" and profile != "device":
        raise ValueError("physical evidence requires a device-profile image audit")
    if evidence == "emulator" and profile == "device":
        raise ValueError("device image requires explicit physical evidence source")
    log = log.replace("\\r", "").replace("\r", "")
    headless = headless_case in (1, 2)
    if headless_case and (not headless or not require_normal or profile != 'emulator' or evidence != 'emulator'):
        raise ValueError('headless normal boot requires an explicit emulator test case')
    if headless:
        case = fixed_record(log, 'NIHOS_NATIVE_BOOT_TEST', ('case',))
        if case['case'] != headless_case or 'NIHOS_NATIVE_UI_' in log:
            raise ValueError('headless test case mismatch or invented display evidence')
    elif 'NIHOS_NATIVE_BOOT_TEST ' in log:
        raise ValueError('emulator test evidence cannot qualify device boot')
    normal_boot = log.count("NIHOS_NATIVE_PROFILE normal=1 qualification=0") == 1
    if require_normal != normal_boot or (normal_boot and (require_qualification or require_sdmmc or require_sdmmc_fast or require_storage or (profile != 'device' and not headless))):
        raise ValueError('normal boot must be explicitly requested and cannot qualify a soak/storage run')
    check_boot_headers(log, bool(image and image.get('automatic_cards')),
                       bool(image and image.get('keypad_storage', {}).get('card_boot')))
    if "NIHOS_NATIVE_FAIL" in log or "NIHOS_NATIVE_TRAP" in log:
        raise ValueError("native failure/trap")
    modes = re.findall(r"NIHOS_NATIVE_MODE floating=([01])", log)
    if len(modes) != 1:
        raise ValueError("missing/duplicate native mode")
    mode = "floating" if modes[0] == "1" else "integer"
    compiled_modes = re.findall(r"NIHOS_NATIVE_COMPILER enabled=([01])", log)
    if len(compiled_modes) != 1 or (compiled_modes[0] == "1" and mode != "floating"):
        raise ValueError("missing/incompatible compiler FP mode")
    if compiled_modes[0] == "1":
        mode = "compiled"
    sql_modes = re.findall(r"NIHOS_NATIVE_SQLITE_MODE enabled=([01])", log)
    if sql_modes:
        if sql_modes != ["1"] or log.count("NIHOS_NATIVE_SQLITE_MODE") != 1 or mode != "integer":
            raise ValueError("invalid/incompatible SQLite build mode")
        mode = "sqlite"
    if expected_mode is not None and mode != expected_mode:
        raise ValueError("native mode differs from requested build")
    if "NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned" not in log:
        raise ValueError("missing CRT/exception pass")
    psram_names = ("status", "configuration", "identity", "bytes", "transactions", "mapped", "allocatable")
    pattern = "NIHOS_NATIVE_PSRAM" + "".join(" " + name + r"=([0-9a-f]{8})" for name in psram_names)
    discovered = re.findall(pattern, log)
    if len(discovered) != 1:
        raise ValueError("missing/duplicate PSRAM discovery")
    psram = dict(zip(psram_names, (int(value, 16) for value in discovered[0])))
    if (psram["status"] not in (0, 1) or psram["bytes"] != expected_psram_bytes or
            psram["transactions"] != 4 or psram["mapped"] != expected_psram_bytes or psram["allocatable"] != 0 or
            psram["configuration"] > 0xffff or psram["identity"] > 0xffff):
        raise ValueError("incomplete PSRAM discovery or premature memory exposure")
    if psram["status"] == 0:
        if psram["bytes"] != 0 or (psram["configuration"], psram["identity"]) not in ((0, 0), (0xffff, 0xffff)):
            raise ValueError("invalid absent PSRAM evidence")
    else:
        density_bytes = {1: 4 << 20, 3: 8 << 20, 5: 16 << 20, 7: 32 << 20, 6: 64 << 20}
        if (((psram["configuration"] >> 8) & 31) not in (0x0d, 0x1a) or
                ((psram["identity"] >> 5) & 7) != 6 or
                density_bytes.get(psram["identity"] & 7, 0) != psram["bytes"] or psram["bytes"] == 0):
            raise ValueError("invalid detected PSRAM identity/capacity")
    supply_names = ("programmed", "calibrated", "dref", "mul", "control", "analog", "settled")
    pattern = "NIHOS_NATIVE_PSRAM_SUPPLY" + "".join(" " + name + r"=([0-9a-f]{8})" for name in supply_names)
    matches = re.findall(pattern, log)
    if len(matches) != 1:
        raise ValueError("missing/duplicate PSRAM supply evidence")
    supply = dict(zip(supply_names, (int(value, 16) for value in matches[0])))
    if (supply["programmed"] != 1 or supply["settled"] != 1 or supply["calibrated"] not in (0, 1) or
            not 1 <= supply["dref"] <= 15 or not 1 <= supply["mul"] <= 7 or supply["control"] != 0x180 or
            supply["analog"] != (supply["dref"] << 28) | (supply["mul"] << 23) | (1 << 26) or
            (supply["calibrated"] == 0 and (supply["dref"], supply["mul"]) != (6, 5))):
        raise ValueError("incomplete PSRAM supply programming/readback")
    fast_psram = check_fast_psram(log, evidence, normal_boot)
    io_names = ("status", "mr0", "mr4", "mr8", "addresses", "passes", "reads", "writes", "transactions")
    pattern = "NIHOS_NATIVE_PSRAM_IO" + "".join(" " + name + r"=([0-9a-f]{8})" for name in io_names)
    matches = re.findall(pattern, log)
    if len(matches) != 1:
        raise ValueError("missing/duplicate PSRAM data evidence")
    psram_io = dict(zip(io_names, (int(value, 16) for value in matches[0])))
    if psram["status"] == 0:
        if any(psram_io[name] != 0 for name in io_names[:-1]) or psram_io["transactions"] != 4:
            raise ValueError("absent PSRAM received data/mode writes")
    else:
        addresses = psram["bytes"].bit_length() - 1
        if (psram_io["status"] != 1 or psram_io["addresses"] != addresses or psram_io["passes"] != 2 or
                psram_io["reads"] != 2 * addresses or psram_io["writes"] != 2 * addresses or
                psram_io["transactions"] != (4 + 18 + 8 * addresses + 32 + fast_psram["tuning"]["reads"] if fast_psram else 13 + 4 * addresses) or
                any(psram_io[name] > 255 for name in ("mr0", "mr4", "mr8")) or
                psram_io["mr0"] & 63 != (0x30 if fast_psram else 0x28) or
                psram_io["mr4"] & 0xe0 != (0x20 if fast_psram else 0x40) or
                psram_io["mr8"] & 0x4f != (0x4b if fast_psram else 0x0b)):
            raise ValueError("incomplete PSRAM data/mode qualification")
    mapping_names = ("status", "failure", "line_bytes", "last_address", "last_actual", "last_expected",
                     "bytes", "entries", "cpu_checks", "command_checks", "transactions", "syncs")
    pattern = "NIHOS_NATIVE_PSRAM_MAP" + "".join(" " + name + r"=([0-9a-f]{8})" for name in mapping_names)
    matches = re.findall(pattern, log)
    if len(matches) != 1:
        raise ValueError("missing/duplicate PSRAM mapping evidence")
    mapped = dict(zip(mapping_names, (int(value, 16) for value in matches[0])))
    expected_mapping = [1, 0, 64, 0, 0, 0, expected_psram_bytes, 1024, 36, 36, 72, 5] if psram["status"] else [0] * 12
    if list(mapped.values()) != expected_mapping:
        raise ValueError("incomplete PSRAM nonidentity mapping/cache evidence")
    smp_names = ("status", "rounds", "owner_checks", "peer_checks", "command_checks", "syncs")
    pattern = "NIHOS_NATIVE_PSRAM_SMP" + "".join(" " + name + r"=([0-9a-f]{8})" for name in smp_names)
    matches = re.findall(pattern, log)
    if len(matches) != 1:
        raise ValueError("missing/duplicate PSRAM SMP evidence")
    psram_smp = dict(zip(smp_names, (int(value, 16) for value in matches[0])))
    if list(psram_smp.values()) != ([1, 1 if normal_boot else 64, 48 if normal_boot else 3072, 48 if normal_boot else 3072, 48, 1] if psram["status"] else [0] * 6):
        raise ValueError("incomplete PSRAM cross-core handoff evidence")
    if normal_boot:
        if mode != 'integer' or (fast_psram is None and not headless):
            raise ValueError('normal boot requires native integer PSRAM200 profile')
        for forbidden in ('NIHOS_NATIVE_QUALIFICATION ', 'NIHOS_NATIVE_PSRAM_SWEEP ', 'NIHOS_NATIVE_HEARTBEAT ', 'NIHOS_NATIVE_SOAK_PASS ', 'NIHOS_NATIVE_TASKS '):
            if forbidden in log:
                raise ValueError('qualification workload in normal boot')
        health = fixed_record(log, 'NIHOS_NATIVE_BOOT_HEALTH', ('cpu0_ticks','cpu1_ticks','ipi0','ipi1'))
        if min(health.values()) < 1 or health['ipi0'] != 1 or health['ipi1'] != 1:
            raise ValueError('incomplete normal boot CPU/timer/IPI health')
        times = repeated_records(log, 'NIHOS_NATIVE_BOOT_TIME', ('stage','elapsed_us'))
        if ([row['stage'] for row in times] != ([1,4,6] if headless else [1,3,5,7,4,6]) or
                not times[0]['elapsed_us'] or any(a['elapsed_us'] >= b['elapsed_us'] for a,b in zip(times,times[1:]))):
            raise ValueError('missing or out-of-order normal boot stage timestamps')
        order = ('NIHOS_NATIVE_BOOT_HEALTH ', 'NIHOS_NATIVE_CONSOLE ', 'NIHOS_NATIVE_UI_READY ')
        if headless:
            order = ('NIHOS_NATIVE_BOOT_HEALTH ', 'NIHOS_NATIVE_NORMAL_READY ', 'NIHOS_NATIVE_NORMAL_IDLE ')
        if [log.index(m) for m in order] != sorted(log.index(m) for m in order):
            raise ValueError('normal boot READY precedes health checks')
        return {'normal_boot': True, 'headless_emulator': headless, 'qualification': None, 'evidence': evidence, 'psram': psram,
                'psram_fast': fast_psram, 'psram_mapping': mapped, 'psram_smp': psram_smp,
                'cpu_clock': check_cpu_clock(log, image, evidence), 'health': health, 'boot_times': times,
                'ready_us_from_diagnostic_clock': times[-1]['elapsed_us']}
    pattern = (r"NIHOS_NATIVE_HEARTBEAT round=([0-9a-f]{8}) cpu0=([0-9a-f]{8}) "
               r"cpu1=([0-9a-f]{8}) ticks0=([0-9a-f]{8}) ticks1=([0-9a-f]{8})")
    samples = [tuple(int(value, 16) for value in match)
               for match in re.findall(pattern, log)]
    if len(samples) < 31 or samples[0][0] != 1 or samples[-1][0] < 300:
        raise ValueError("incomplete heartbeat sequence")
    for previous, current in zip(samples, samples[1:]):
        if any(value <= old for value, old in zip(current, previous)):
            raise ValueError("hart, timer, or round stopped progressing")
    if (log.count("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none") < 3 or
            "NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none" not in log):
        raise ValueError("missing continuous execution pass")
    pattern = (r"NIHOS_NATIVE_TASKS hart=([0-9a-f]{8}) work0=([0-9a-f]{8}) "
               r"work1=([0-9a-f]{8}) cap0=([0-9a-f]{8}) cap1=([0-9a-f]{8}) "
               r"switches=([0-9a-f]{8}) calls=([0-9a-f]{8}) reaped=([0-9a-f]{8}) "
               r"sleeps=([0-9a-f]{8}) elapsed=([0-9a-f]{8})")
    owners = [[], []]
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2:
            raise ValueError("invalid task owner")
        work0, work1, cap0, cap1, switches, calls, reaped, sleeps, elapsed = values
        if (min(work0, work1) == 0 or min(cap0, cap1) < 4 or switches < 8 or
                calls < 12 or reaped != 3 or sleeps != 2 or elapsed == 0):
            raise ValueError("incomplete task lifecycle/preemption")
        if owners[hart] and any(values[index] <= owners[hart][-1][index]
                                for index in (0, 1, 2, 3, 4, 8)):
            raise ValueError("worker or preemption stopped progressing")
        owners[hart].append(values)
    if any(len(records) != 3 for records in owners):
        raise ValueError("missing per-hart task checkpoints")
    names = ("sent", "received", "ipis", "delivered", "woken", "rejected",
             "from_idle", "entries", "returns", "pending_before_wfi", "self_ipi", "timer_start", "timer_end", "queued")
    pattern = r"NIHOS_NATIVE_IPI hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in names)
    ipi_owners = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in ipi_owners:
            raise ValueError("invalid/duplicate IPI owner")
        record = dict(zip(names, values))
        if (any(record[name] != 64 for name in ("sent", "received", "delivered", "woken")) or
                record["ipis"] < 64 or record["from_idle"] < 64 or
                record["returns"] < 64 or record["entries"] < record["returns"] or
                record["pending_before_wfi"] != 1 or
                record["self_ipi"] != 1 or
                record["rejected"] != 0 or record["queued"] != 0):
            raise ValueError("incomplete IPI delivery/idle wake")
        if record["timer_start"] != record["timer_end"]:
            raise ValueError("periodic timer used during IPI-only idle")
        ipi_owners[hart] = record
    if (set(ipi_owners) != {0, 1} or
            "NIHOS_NATIVE_IPI_IDLE_PASS exchanges=64 timer_fallback=none" not in log):
        raise ValueError("missing native IPI/idle evidence")
    fp_names = ("checks0", "checks1", "checks2", "timer", "calls", "ipi", "saves", "restores", "initial", "app_timer", "confirmed")
    pattern = r"NIHOS_NATIVE_FP hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in fp_names)
    fp_owners = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in fp_owners:
            raise ValueError("invalid/duplicate FP owner")
        record = dict(zip(fp_names, values))
        if (record["confirmed"] != 1 or record["saves"] != record["restores"] or
                record["saves"] != record["timer"] + record["calls"] + record["ipi"]):
            raise ValueError("FP copy/return accounting mismatch")
        if mode in ("integer", "sqlite"):
            if any(record[name] != 0 for name in fp_names[:-1]):
                raise ValueError("integer tasks paid FP transfer overhead")
        elif (record["initial"] != 5 or min(record["checks0"], record["checks1"], record["checks2"]) < 4 or
                record["timer"] < 8 or record["calls"] < 12 or record["ipi"] < 1):
            raise ValueError("missing FP task/trap coverage")
        if mode == "compiled" and record["app_timer"] < 4:
            raise ValueError("missing compiler-generated task preemption")
        if mode != "compiled" and record["app_timer"] != 0:
            raise ValueError("unexpected compiler-generated task evidence")
        fp_owners[hart] = record
    if (set(fp_owners) != {0, 1} or
            "NIHOS_NATIVE_FP_PASS floating=" + modes[0] not in log):
        raise ValueError("missing final FP evidence")
    memory_names = ("start", "end", "capacity", "used", "free", "checks0", "checks1", "rejected", "confirmed")
    pattern = r"NIHOS_NATIVE_MEMORY hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in memory_names)
    memory_owners = {}
    # Rev1/2 silicon uses the lower SRAM bank. The emulator profile skips
    # its cache bank; never apply that emulated lower bound to physical logs.
    memory_low, memory_high = ((0x4ff00000, 0x4ff28000) if profile == "device"
                               else (0x4ff20000, 0x4ff48000))
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in memory_owners:
            raise ValueError("invalid/duplicate memory owner")
        record = dict(zip(memory_names, values))
        if (not memory_low <= record["start"] < record["end"] <= memory_high or
                record["start"] % 64 or record["end"] % 64 or
                record["capacity"] != record["end"] - record["start"] - 128 or
                record["used"] != 448 or record["used"] + record["free"] != record["capacity"] or
                min(record["checks0"], record["checks1"]) < 4 or
                record["rejected"] != 3 or record["confirmed"] != 1):
            raise ValueError("incomplete memory ownership/guard accounting")
        memory_owners[hart] = record
    if set(memory_owners) != {0, 1}:
        raise ValueError("missing per-hart memory evidence")
    if memory_owners[0]["end"] > memory_owners[1]["start"]:
        raise ValueError("overlapping memory owners")
    if image is not None:
        heap = image["heap"]
        start = int(heap["start"], 16)
        stride = heap["bytes"] // 2 // 64 * 64
        if any(record["start"] != start + hart * stride or record["end"] != start + (hart + 1) * stride
               for hart, record in memory_owners.items()):
            raise ValueError("memory owners differ from audited heap")
    pattern = r"NIHOS_NATIVE_EXTERNAL hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in memory_names)
    external_owners = {}
    display_preparation = None
    if require_card:
        external_reserved_bytes = 2 << 20
    if canvas_offscreen:
        if evidence != 'emulator' or image is None or image.get('memory', {}).get('profile') != 'emulator' or expected_psram_bytes < 4 << 20 or require_card:
            raise ValueError('canvas offscreen requires emulator image and PSRAM')
        external_reserved_bytes = 2 << 20
    if external_reserved_bytes == 2 << 20 and not canvas_offscreen:
        if evidence != 'physical-device':
            raise ValueError('native display preparation requires physical-device evidence')
        display_preparation = check_display_preparation(log)
        if expected_psram_bytes < 4 << 20:
            raise ValueError('invalid display external reservation')
    external_start = 0x48000000 + external_reserved_bytes
    stride = (expected_psram_bytes - external_reserved_bytes) // 2 if psram["status"] else 0
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in external_owners:
            raise ValueError("invalid/duplicate external memory owner")
        record = dict(zip(memory_names, values))
        if not psram["status"]:
            if any(values):
                raise ValueError("external allocation without a mapped die")
        elif (record["start"] != external_start + hart * stride or
              record["end"] != external_start + (hart + 1) * stride or
              record["capacity"] != stride - 128 or record["used"] != record["capacity"] or
              record["free"] != 0 or
              min(record["checks0"], record["checks1"]) < 4 or
              record["rejected"] != 3 or record["confirmed"] != 1):
            raise ValueError("incomplete external ownership/guard accounting")
        external_owners[hart] = record
    if set(external_owners) != {0, 1}:
        raise ValueError("missing per-hart external memory evidence")
    heap_names = ("start", "end", "metadata", "capacity", "free", "live", "allocations", "frees", "rejected",
                  "checks0", "checks1", "levels", "max_steps", "confirmed")
    pattern = r"NIHOS_NATIVE_HEAP hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in heap_names)
    heaps = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in heaps:
            raise ValueError("invalid/duplicate reusable heap owner")
        record = dict(zip(heap_names, values))
        if not psram["status"]:
            if any(values):
                raise ValueError("reusable heap without mapped PSRAM")
        else:
            start = external_owners[hart]["start"] + 128
            end = external_owners[hart]["end"] - 64 - 2 * 65728
            units = (end - start - 128) // 64
            levels = (units - 1).bit_length()
            metadata = max(64, 2 * (1 << levels))
            capacity = end - start - metadata - 128
            if (record["start"] != start or record["end"] != end or
                    record["metadata"] != metadata or record["capacity"] != capacity or record["free"] != capacity or
                    record["live"] != 0 or record["allocations"] < 8 or record["allocations"] != record["frees"] or
                    record["rejected"] != 13 or min(record["checks0"], record["checks1"]) < 4 or
                    record["levels"] != levels or record["max_steps"] != 3 * levels + 2 or record["confirmed"] != 1):
                raise ValueError("incomplete reusable heap recovery/bounds evidence")
        heaps[hart] = record
    if set(heaps) != {0, 1}:
        raise ValueError("missing per-hart reusable heap evidence")
    resource_names = ("opened", "closed", "completed", "reclaimed", "reuses", "owned", "pending", "stale", "full", "forced", "pool_objects", "pool_rejected", "slab_objects", "slab_frees", "slab_rejected", "object_moves", "object_inplace", "object_rejected", "object_copy_bytes", "c_probes")
    pattern = r"NIHOS_NATIVE_RESOURCES hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in resource_names)
    resources = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in resources:
            raise ValueError("invalid/duplicate task resource owner")
        expected = [7, 6, 6, 10 if psram["status"] else 0, 3, 0, 0, 3, 3 if psram["status"] else 0, 1,
                    18 if psram["status"] else 0, 6 if psram["status"] else 0,
                    120 if psram["status"] else 0, 24 if psram["status"] else 0, 27 if psram["status"] else 0,
                    8 if psram["status"] else 0, 4 if psram["status"] else 0,
                    8 if psram["status"] else 0, 4208 if psram["status"] else 0, 2 if psram["status"] else 0]
        if service_expected:
            for index in (0, 1, 2, 4, 7): expected[index] += 2 if rebind_expected and hart == 1 else 1
            if cancel_expected and hart == 1: expected[9] += 1
        if values != expected:
            raise ValueError("incomplete deferred task resource cleanup")
        resources[hart] = dict(zip(resource_names, values))
    if set(resources) != {0, 1}:
        raise ValueError("missing per-hart task resource evidence")
    flash_names = ("start", "end", "bytes", "initial", "final", "checks", "confirmed")
    pattern = r"NIHOS_NATIVE_FLASH hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in flash_names)
    flash = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in flash:
            raise ValueError("invalid/duplicate Flash table owner")
        record = dict(zip(flash_names, values))
        if (record["start"] != 0x40010020 or not 0 < record["bytes"] <= 65504 or
                record["end"] != record["start"] + record["bytes"] or
                record["initial"] != record["final"] or record["checks"] != 2 * record["bytes"] or
                record["confirmed"] != 1):
            raise ValueError("incomplete mapped Flash table evidence")
        if image is not None:
            expected = image["flash_records"]
            if (record["start"] != int(expected["start"], 16) or record["end"] != int(expected["end"], 16) or
                    record["bytes"] != expected["bytes"] or record["initial"] != expected["fnv1a"]):
                raise ValueError("Flash tables differ from audited image")
        flash[hart] = record
    if set(flash) != {0, 1} or flash[0] != flash[1]:
        raise ValueError("missing/inconsistent per-hart Flash table evidence")
    stack_names = ("start", "end", "boot_start", "boot_end", "irq_start", "irq_end", "task_start", "task_end",
                   "boot_frame", "irq_sp", "task0_frame", "task1_frame", "task2_frame", "frames", "zeroed", "confirmed")
    pattern = r"NIHOS_NATIVE_STACKS hart=([0-9a-f]{8})" + "".join(" " + name + r"=([0-9a-f]{8})" for name in stack_names)
    stacks = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in stacks:
            raise ValueError("invalid/duplicate stack owner")
        record = dict(zip(stack_names, values))
        base = 0x4ff60000
        expected = {"start": base, "end": 0x4ff6e000, "boot_start": base + hart * 8192, "boot_end": base + (hart + 1) * 8192,
                    "irq_start": base + 16384 + hart * 8192, "irq_end": base + 16384 + (hart + 1) * 8192,
                    "task_start": base + 32768 + hart * 12288, "task_end": base + 32768 + (hart + 1) * 12288}
        if any(record[name] != value for name, value in expected.items()) or record["zeroed"] != 20480 or record["confirmed"] != 1 or record["frames"] < 4:
            raise ValueError("incomplete stack bank layout/initialization evidence")
        for field, low, high, width in [("boot_frame", record["boot_start"], record["boot_end"], 128),
                                        ("irq_sp", record["irq_start"], record["irq_end"], 1)] + [
                ("task{}_frame".format(index), record["task_start"] + index * 4096, record["task_start"] + (index + 1) * 4096, 128)
                for index in range(3)]:
            if record[field] % 16 or not low + 16 <= record[field] <= high - width:
                raise ValueError("stack sample outside owned stack")
        if image is not None and (record["start"] != int(image["stacks"]["start"], 16) or record["end"] != int(image["stacks"]["end"], 16)):
            raise ValueError("stack bank differs from audited image")
        stacks[hart] = record
    if set(stacks) != {0, 1}:
        raise ValueError("missing per-hart stack evidence")
    boot_names = ("start", "end", "probe", "mapping", "completed")
    pattern = "NIHOS_NATIVE_BOOT_CODE" + "".join(" " + name + r"=([0-9a-f]{8})" for name in boot_names)
    matches = re.findall(pattern, log)
    if len(matches) != 1:
        raise ValueError("missing/duplicate Flash boot execution")
    boot = dict(zip(boot_names, (int(value, 16) for value in matches[0])))
    if (boot["start"] != 0x40000120 or not boot["start"] < boot["end"] <= 0x40010000 or
            not boot["start"] <= boot["probe"] < boot["end"] or boot["probe"] % 2 != 0 or boot["completed"] != 1 or
            (psram["status"] == 0 and boot["mapping"] != 0) or
            (psram["status"] != 0 and (not boot["start"] <= boot["mapping"] < boot["end"] or
                                      boot["mapping"] % 2 != 0 or boot["mapping"] == boot["probe"]))):
        raise ValueError("incomplete Flash boot execution")
    if image is not None:
        expected = image["flash_boot"]
        if boot["start"] != int(expected["start"], 16) or boot["end"] != int(expected["end"], 16):
            raise ValueError("Flash boot extent differs from audited image")
        for role in ("probe", "mapping"):
            if role == "mapping" and psram["status"] == 0:
                continue
            function = expected["functions"][role]
            if not int(function["start"], 16) <= boot[role] < int(function["end"], 16):
                raise ValueError("Flash boot PC outside audited function")
    cpu_clock = check_cpu_clock(log, image, evidence)
    sdmmc_code = None
    sd_boot = image.get("flash_boot", {}).get("functions", {}).get("sdmmc") if image is not None else None
    if sd_boot is not None or "NIHOS_NATIVE_SDMMC_CODE " in log:
        if sd_boot is None or evidence != "physical-device" or "NIHOS_NATIVE_SDMMC_MODE enabled=1" not in log:
            raise ValueError("SD boot execution requires bound physical image")
        sdmmc_code = fixed_record(log, "NIHOS_NATIVE_SDMMC_CODE", ("start", "end", "pc", "completed"))
        if (sdmmc_code["start"] != int(sd_boot["start"], 16) or sdmmc_code["end"] != int(sd_boot["end"], 16) or
                not sdmmc_code["start"] <= sdmmc_code["pc"] < sdmmc_code["end"] or
                sdmmc_code["pc"] % 2 != 0 or sdmmc_code["completed"] != 1):
            raise ValueError("SD boot PC/extent/completion differs from image")
    sql_report = None
    sql_names = ("status", "owner", "sessions", "queries", "open_pc", "text_start", "text_end", "rodata_start", "rodata_end", "heap_before", "heap_after", "stack_low", "stack_high", "painted_to", "observed_used", "mie")
    sql_records = re.findall("NIHOS_NATIVE_SQLITE" + "".join(" " + name + r"=([0-9a-f]{8})" for name in sql_names), log)
    if mode == "sqlite":
        if len(sql_records) != 1 or sum(line.startswith("NIHOS_NATIVE_SQLITE ") for line in log.splitlines()) != 1:
            raise ValueError("missing/duplicate SQLite execution evidence")
        sql_report = dict(zip(sql_names, (int(value, 16) for value in sql_records[0])))
        q = sql_report
        check_sqlite_spans(q, image, evidence)
        runtime_fields = ("owner", "sessions", "queries", "open_pc", "heap_before", "heap_after", "stack_low", "stack_high", "painted_to", "observed_used", "mie")
        if psram["status"] == 0:
            if q["status"] != 0 or any(q[name] for name in runtime_fields):
                raise ValueError("SQLite ran without PSRAM")
        elif not (q["status"] == 1 and q["owner"] == 1 and q["sessions"] == 2 and q["queries"] == 26 and
                  q["text_start"] <= q["open_pc"] < q["text_end"] and q["heap_before"] > 65536 and
                  q["heap_after"] == q["heap_before"] == heaps[0]["free"] and q["stack_low"] == 0x4ff60010 and q["stack_high"] == 0x4ff62000 and
                  q["stack_low"] < q["painted_to"] < q["stack_high"] and
                  q["stack_high"] - q["painted_to"] <= q["observed_used"] <= q["stack_high"] - q["stack_low"] - 160 and q["mie"] == 8):
            raise ValueError("incomplete SQLite query/recovery/stack evidence")
        class_names = ("c8", "c16", "c32", "c64", "c128", "c256", "c512", "c1024", "c2048", "c4096")
        class_records = re.findall("NIHOS_NATIVE_SQLITE_CLASSES" + "".join(" " + name + r"=([0-9a-f]{8})" for name in class_names), log)
        if len(class_records) != 1 or log.count("NIHOS_NATIVE_SQLITE_CLASSES") != 1:
            raise ValueError("missing/duplicate native SQLite allocation trace")
        peaks = [int(value, 16) for value in class_records[0]]
        quotas = image["sqlite"]["pool_quotas"] if image is not None else [24, 12, 64, 64, 64, 4, 8, 12, 8, 1]
        if any(peak > quota for peak, quota in zip(peaks, quotas)) or (not q["status"] and any(peaks)) or (q["status"] and not any(peaks)):
            raise ValueError("invalid native SQLite class peaks")
        if q["status"] and peaks != [20, 10, 22, 23, 16, 3, 6, 8, 3, 0]:
            raise ValueError("native SQLite allocation trace differs from fixed workload")
        sql_report["class_peaks"] = dict(zip(class_names, peaks))
        if image is not None:
            audited = image.get("sqlite")
            if audited is None or any(q[name] != int(audited[name], 16) for name in ("text_start", "text_end", "rodata_start", "rodata_end")):
                raise ValueError("SQLite spans differ from audited image")
            if q["status"]:
                function = audited["functions"]["nih_sqlite_session_open"]
                if not int(function["start"], 16) <= q["open_pc"] < int(function["end"], 16):
                    raise ValueError("SQLite execution PC outside actual open function")
    elif "NIHOS_NATIVE_SQLITE" in log:
        raise ValueError("unexpected SQLite evidence in ordinary build")
    qualification = None
    qualification_marker = "NIHOS_NATIVE_QUALIFICATION enabled=1"
    if require_qualification or "NIHOS_NATIVE_QUALIFICATION" in log:
        if log.count(qualification_marker) != 1 or expected_psram_bytes == 0:
            raise ValueError("missing/invalid qualification mode")
        sweep = fixed_record(log, "NIHOS_NATIVE_PSRAM_SWEEP", ("bytes", "passes", "reads", "writes", "syncs", "confirmed"))
        if list(sweep.values()) != [expected_psram_bytes, 2, expected_psram_bytes // 2, expected_psram_bytes // 2, 4, 1]:
            raise ValueError("incomplete full PSRAM sweep")
        qualification = {"psram_sweep": sweep}
        if mode == "sqlite":
            soak = fixed_record(log, "NIHOS_NATIVE_SQLITE_SOAK", ("loops", "sessions", "queries", "heap_before", "heap_after", "max_stack", "confirmed"))
            if (soak["loops"] != 1000 or soak["sessions"] != 2000 or soak["queries"] != 26000 or
                    soak["heap_before"] != soak["heap_after"] or soak["heap_before"] != sql_report["heap_before"] or
                    not 0 < soak["max_stack"] <= 8000 or soak["confirmed"] != 1):
                raise ValueError("incomplete SQLite soak")
            qualification["sqlite_soak"] = soak
    elif "NIHOS_NATIVE_PSRAM_SWEEP" in log or "NIHOS_NATIVE_SQLITE_SOAK" in log:
        raise ValueError("qualification records without mode")
    sdmmc = None
    sdmmc_stages = []
    sdmmc_sweeps = []
    if require_sdmmc or require_sdmmc_fast or "NIHOS_NATIVE_SDMMC" in log:
        if log.count("NIHOS_NATIVE_SDMMC_MODE enabled=1") != 1:
            raise ValueError("missing/invalid SDMMC mode")
        sdmmc = fixed_record(log, "NIHOS_NATIVE_SDMMC", SDMMC_FIELDS)
        sectors = sdmmc["sectors_low"] + (sdmmc["sectors_high"] << 32)
        profiles = {(1, 400): 1, (4, 400): 2, (4, 20000): 3}
        phases = profiles.get((sdmmc["bus_bits"], sdmmc["clock_khz"]), 0)
        sample_count = 1024 if phases > 1 else 0
        if (sdmmc["status"] != 1 or sdmmc["stage"] != 4 or not 1024 <= sectors <= 1 << 32 or phases == 0 or
                sdmmc["reads"] != (8 + sample_count) * phases or sdmmc["writes"] != 0 or
                sdmmc["error_code"] != 0 or sdmmc["commands"] < sdmmc["reads"] + 9 + (4 if phases > 1 else 0) or sdmmc["data_words"] != 128 or sdmmc["dma"] != 1):
            raise ValueError("incomplete read-only SDMMC probe")
        if require_sdmmc_fast and phases != 3:
            raise ValueError("required 4-bit/20 MHz profile missing")
        sdmmc_stages = repeated_records(log, "NIHOS_NATIVE_SDMMC_STAGE", ("index", "bus_bits", "clock_khz", "scr_widths", "host_width", "divider", "reads", "crc0", "crc1", "crc_middle", "crc_last"))
        if phases > 1 or sdmmc_stages:
            if len(sdmmc_stages) != phases:
                raise ValueError("missing SDMMC transition stages")
            for i, stage in enumerate(sdmmc_stages):
                bits, khz, host, divider = ((1, 400, 0, 50), (4, 400, 1, 50), (4, 20000, 1, 1))[i]
                if (stage["index"] != i or stage["bus_bits"] != bits or stage["clock_khz"] != khz or
                        stage["host_width"] != host or stage["divider"] != divider or stage["reads"] != 8 + sample_count or
                        (i == 0 and stage["scr_widths"] != 0) or (i > 0 and stage["scr_widths"] & 5 != 5) or
                        any(stage[name] != sdmmc[name] for name in ("crc0", "crc1", "crc_middle", "crc_last"))):
                    raise ValueError("invalid SDMMC transition/readback/CRC evidence")
        sdmmc_sweeps = repeated_records(log, "NIHOS_NATIVE_SDMMC_SWEEP", ("index", "samples", "digest"))
        if sample_count:
            if len(sdmmc_sweeps) != phases or any(row["index"] != i or row["samples"] != sample_count or
                                                row["digest"] != sdmmc_sweeps[0]["digest"] for i, row in enumerate(sdmmc_sweeps)):
                raise ValueError("missing/inconsistent SDMMC distributed sweep")
        elif sdmmc_sweeps:
            raise ValueError("unexpected SDMMC distributed sweep")
    storage = None
    storage_stack = None
    storage_api = None
    storage_workspace = None
    card_direct = (image or {}).get('sqlite',{}).get('fatfs_native',{}).get('card',{}).get('mode')=='inserted'
    if card_direct and (require_storage or any(marker in log for marker in ('NIHOS_NATIVE_STORAGE ', 'NIHOS_NATIVE_STORAGE_STACK ', 'NIHOS_NATIVE_STORAGE_API ', 'NIHOS_NATIVE_STORAGE_WORKSPACE '))):
        raise ValueError('inserted card profile cannot claim legacy littlefs qualification')
    storage_expected = image is not None and image.get('sqlite', {}).get('littlefs') is not None and not card_direct
    if require_storage or storage_expected or 'NIHOS_NATIVE_STORAGE ' in log:
        if evidence != 'physical-device' or sdmmc is None or mode != 'sqlite':
            raise ValueError('storage requires physical SDMMC and SQLite mapped span')
        if image.get('sqlite', {}).get('littlefs', {}).get('read_only') is not True:
            raise ValueError('storage log requires a littlefs image audit')
        storage = check_storage(fixed_record(log, 'NIHOS_NATIVE_STORAGE', STORAGE_FIELDS), sdmmc['sectors_low'] + (sdmmc['sectors_high'] << 32))
        storage_stack = fixed_record(log, 'NIHOS_NATIVE_STORAGE_STACK', ('low', 'high', 'painted_to', 'used', 'confirmed'))
        if (storage_stack['low'] != stacks[0]['boot_start'] + 16 or storage_stack['high'] != stacks[0]['boot_end'] or
                not storage_stack['low'] < storage_stack['painted_to'] < storage_stack['high'] or
                not storage_stack['high'] - storage_stack['painted_to'] <= storage_stack['used'] < 8176 - 160 or storage_stack['confirmed'] != 1):
            raise ValueError('incomplete littlefs stack qualification')
        api_version = image.get('sqlite', {}).get('littlefs', {}).get('api_version')
        if api_version is not None or 'NIHOS_NATIVE_STORAGE_API ' in log:
            if api_version != 1:
                raise ValueError('file API log/image differs')
            storage_api = check_storage_api(fixed_record(log, 'NIHOS_NATIVE_STORAGE_API', STORAGE_API_FIELDS), storage)
            storage_workspace = fixed_record(log, 'NIHOS_NATIVE_STORAGE_WORKSPACE', ('start', 'bytes', 'cleared'))
            if storage_workspace != {'start': 0x48001000, 'bytes': 8192, 'cleared': 1} or mapped['status'] != 1:
                raise ValueError('invalid reserved PSRAM file workspace')
    elif any(marker in log for marker in ('NIHOS_NATIVE_STORAGE_STACK ', 'NIHOS_NATIVE_STORAGE_API ', 'NIHOS_NATIVE_STORAGE_WORKSPACE ')):
        raise ValueError('orphan storage record')
    service = None
    if service_expected or 'NIHOS_NATIVE_STORAGE_SERVICE ' in log:
        if not service_expected or storage is None or evidence != 'physical-device':
            raise ValueError('storage service requires a bound physical image')
        if service_metadata.get('version') not in (1, 2, 3):
            raise ValueError('unknown storage service version')
        service = fixed_record(log, 'NIHOS_NATIVE_STORAGE_SERVICE', SERVICE_FIELDS + (CANCEL_FIELDS if cancel_expected else ()) + (REBIND_FIELDS if rebind_expected else ()))
        if cancel_expected and any(service[key] != value for key, value in zip(CANCEL_FIELDS, (1, 1, 2, 2))):
            raise ValueError('incomplete forced storage cancellation/drain')
        replies = storage['entries'] + 13 + (storage['file_bytes'] + 511) // 512
        chunks = (storage['file_bytes'] + 511) // 512
        if rebind_expected and (any(service[key] != 1 for key in ('rebound','old_epoch_rejected','old_reply_rejected','old_exit_rejected','replacement_exit')) or
                service['old_handle_rejected'] != 2 or service['replacement_owner'] >> 16 != service['owner'] >> 16 or
                service['replacement_owner'] & 0xffff != (service['owner'] & 0xffff) + 1 or
                service['replacement_bytes'] != storage['file_bytes'] or service['replacement_crc'] != storage['file_crc']):
            raise ValueError('incomplete storage endpoint rebind/generation qualification')
        if (any(service[key] != 1 for key in ('status','queue_full','exit_seen','released','stale_rejected','clock_ok','fs_cleared','ipc_cleared')) or
                storage['status'] != 2 or service['responses'] != replies + (chunks + 4 if rebind_expected else 0) or service['requests'] != replies - (0 if cancel_expected else 2) + (chunks + 3 if rebind_expected else 0) or service['rejected'] != (8 if rebind_expected else 5) or
                service['bytes'] != storage['file_bytes'] or service['crc'] != storage['file_crc'] or
                service['owner'] >> 24 != 1 or service['owner'] & 0xffff == 0 or
                not 0 < service['owner_stack'] < 3920 or not 0 < service['client_stack'] < 3920 or
                service['peer_polls'] == 0 or service['elapsed_us'] == 0):
            raise ValueError('incomplete storage task/IPC/EXIT cleanup qualification')
    high_sram, page_lease = check_high(log, image, evidence)
    broker = check_broker(log, image, evidence)
    io_lifetimes = check_io_lifetimes(log, image, evidence, sdmmc)
    sd_removal = check_sd_removal(log, image, evidence, sdmmc)
    boot_capture = check_boot_capture(log, image, evidence)
    fatfs_native = check_fatfs_native(log, image, evidence)
    fatfs_card = check_fatfs_card(log, image, evidence)
    usb = None
    authenticated_usb = None
    authenticated_image = image is not None and image.get('keypad_storage', {}).get('ui_mode') == 'runtime' and image.get('card_text') is not None
    if authenticated_image and not (require_usb or require_jpki or require_card):
        authenticated_usb = check_authenticated_owner(log, image, evidence)
    elif require_usb or require_jpki or 'NIHOS_NATIVE_USB ' in log or 'NIHOS_NATIVE_USB_MODE' in log:
        if evidence != 'physical-device':
            raise ValueError('native USB requires physical-device evidence')
        usb = check_usb(log)
    jpki = None
    if require_jpki or 'NIHOS_NATIVE_JPKI_MODE' in log or 'NIHOS_NATIVE_JPKI ' in log:
        if evidence != 'physical-device' or usb is None:
            raise ValueError('PIN-free JPKI requires physical USB evidence')
        jpki = check_jpki(log)
    card = None
    if require_card or 'NIHOS_NATIVE_CARD_CHECK_START' in log or 'NIHOS_NATIVE_CARD_CHECK ' in log:
        if evidence != 'physical-device' or usb is None or display_preparation is None:
            raise ValueError('card readiness requires physical USB and display preparation')
        card = check_card(log)
    return {**({'fatfs_card':fatfs_card} if fatfs_card is not None else {}), "schema": 1, "backend": "native-sram", "evidence": evidence, "mode": mode, "storage": storage, "storage_stack": storage_stack,
            "high_sram": high_sram, "page_lease": page_lease,
            "fatfs_native": fatfs_native, "broker": broker, "io_lifetimes": io_lifetimes, "sd_removal": sd_removal, "boot_capture": boot_capture,
            "storage_api": storage_api, "storage_workspace": storage_workspace, "storage_service": service,
            "usb": usb, "authenticated_usb": authenticated_usb, "jpki": jpki,
            "card_readiness": card, "display_preparation": display_preparation,
            "qualification": qualification, "sdmmc": sdmmc, "sdmmc_stages": sdmmc_stages, "sdmmc_sweeps": sdmmc_sweeps,
            "image_elf_sha256": image["elf_sha256"] if image is not None else None,
            "flash_records": [{"hart": hart, **flash[hart]} for hart in (0, 1)],
            "flash_boot": boot, "cpu_clock": cpu_clock, "sdmmc_code": sdmmc_code, "sqlite": sql_report,
            "stacks": [{"hart": hart, **stacks[hart]} for hart in (0, 1)],
            "rounds": samples[-1][0], "samples": len(samples), "psram": psram,
            "psram_supply": supply, "psram_io": psram_io, "psram_fast": fast_psram,
            "psram_mapping": mapped, "psram_smp": psram_smp,
            "cpu0_progress": samples[-1][1], "cpu1_progress": samples[-1][2],
            "cpu0_interrupts": samples[-1][3], "cpu1_interrupts": samples[-1][4],
            "tasks": [{"hart": hart, "progress": values[-1][:2],
                       "timer_captures": values[-1][2:4], "switches": values[-1][4],
                       "calls": values[-1][5], "reaped": values[-1][6],
                       "sleeps": values[-1][7], "elapsed_ticks": values[-1][8]}
                      for hart, values in enumerate(owners)],
            "ipi_idle": [{"hart": hart, **ipi_owners[hart]} for hart in (0, 1)],
            "floating": [{"hart": hart, **fp_owners[hart]} for hart in (0, 1)],
            "memory": [{"hart": hart, **memory_owners[hart]} for hart in (0, 1)],
            "external_memory": [{"hart": hart, **external_owners[hart]} for hart in (0, 1)],
            "heaps": [{"hart": hart, **heaps[hart]} for hart in (0, 1)],
            "task_resources": [{"hart": hart, **resources[hart]} for hart in (0, 1)],
            "external_registered_bytes": sum(owner["capacity"] for owner in external_owners.values()),
            "external_allocatable_bytes": sum(heap["capacity"] for heap in heaps.values())}


def main():
    if len(sys.argv) not in (3, 4, 5, 6, 7, 8):
        raise SystemExit("usage: check-native-log.py LOG REPORT.json [integer|floating|compiled|sqlite] [0|4M|8M|16M|32M|64M] [IMAGE-AUDIT.json] [emulator|physical-device] [qualification|sdmmc|sdmmc-fast|storage|usb|jpki|card|comma-separated requirements]")
    try:
        size = sys.argv[4] if len(sys.argv) >= 5 else "0"
        if size not in PSRAM_SIZES:
            raise ValueError("invalid expected PSRAM size")
        image = json.loads(Path(sys.argv[5]).read_text()) if len(sys.argv) >= 6 else None
        extra = set(sys.argv[7].split(",")) if len(sys.argv) == 8 else set()
        if not extra <= {"qualification", "sdmmc", "sdmmc-fast", "storage", "usb", "jpki", "card"}:
            raise ValueError("invalid required extra evidence")
        report = check(Path(sys.argv[1]).read_text(), sys.argv[3] if len(sys.argv) >= 4 else None,
                       PSRAM_SIZES[size], image, sys.argv[6] if len(sys.argv) >= 7 else "emulator",
                       require_qualification="qualification" in extra, require_sdmmc="sdmmc" in extra,
                       require_sdmmc_fast="sdmmc-fast" in extra, require_storage="storage" in extra,
                       require_usb="usb" in extra, require_jpki="jpki" in extra, require_card="card" in extra)
    except ValueError as error:
        raise SystemExit("Native smoke failed: " + str(error)) from error
    Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native smoke passed (" + report["mode"] + "): 300 rounds, lifecycle, IPI/idle, FP and owned memory")


if __name__ == "__main__":
    main()

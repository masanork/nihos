"""Verify the restored Flash and boot it after the operator returned the card."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

RUN = Path(__file__).resolve().parent
SOURCE = Path('/Users/masanork/Documents/Codex/2026-10-28/nihos-fatfs-card-rpc-candidate/source')
sys.path.insert(0, str(SOURCE / 'tools'))
import esptool
from esptool.reset import HardReset
import serial
from native_serial import capture_serial_class, disable_hangup

PORT = '/dev/cu.usbmodem101'
ALIASES = [PORT, PORT.replace('/cu.', '/tty.')]
EXPECTED_DEVICE = {'chip': 'ESP32-P4 (revision v1.3)', 'mac': 'e8:f6:0a:e2:e8:9c'}
backup = RUN / 'flash-before.bin'
expected = json.loads((RUN / 'backup.json').read_text())['flash_sha256']
assert hashlib.sha256(backup.read_bytes()).hexdigest() == expected
assert json.loads((RUN / 'restored.json').read_text()) == {'verified': True, 'sha256': expected}
owners = subprocess.run(['lsof', '-t', *ALIASES], capture_output=True, text=True, check=False)
if owners.stdout.strip():
    raise RuntimeError('Serial already in use: ' + owners.stdout.strip())

result = {'operator_original_card_returned': True, 'flash_written': False,
          'expected_flash_sha256': expected, 'verified': False, 'reset_sent': False,
          'exclusive_serial': False, 'kernel_exclusive_serial': False}
port = capture_serial_class(serial.Serial)(None, baudrate=115200, timeout=.2, exclusive=True)
port.passive_open = True
port.dtr = False
port.rts = False
port.port = PORT
try:
    port.open()
    owners = subprocess.run(['lsof', '-t', *ALIASES], capture_output=True, text=True, check=False)
    foreign = {int(pid) for pid in owners.stdout.split()} - {os.getpid()}
    if foreign:
        raise RuntimeError('Another serial writer is present: ' + str(sorted(foreign)))
    result['exclusive_serial'] = result['kernel_exclusive_serial'] = True
    port.passive_open = False
    with (RUN / 'verify-before-normal-reset.log').open('w') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        esp = esptool.detect_chip(port=port, baud=115200)
        identity = {'chip': esp.get_chip_description(), 'mac': ':'.join(f'{v:02x}' for v in esp.read_mac())}
        result['device'] = identity
        if identity != EXPECTED_DEVICE:
            raise RuntimeError('Device identity changed; refusing reset')
        esptool.main(['--chip', 'esp32p4', '--baud', '460800', '--after', 'no_reset',
                      'verify_flash', '0', str(backup)], esp=esp)
    result['verified'] = True
    print('Full restored Flash verified; requesting normal boot', flush=True)
    port.baudrate = 115200
    port.reset_input_buffer()
    HardReset(port, uses_usb=True)()
    result['reset_sent'] = True
    raw = bytearray()
    began = time.monotonic()
    passed_at = None
    path = RUN / 'normal-reset.log'
    while time.monotonic() - began < 45:
        raw.extend(port.read(max(1, port.in_waiting)))
        path.write_bytes(raw)
        if b'NIHOS_NATIVE_FAIL' in raw or b'NIHOS_NATIVE_TRAP' in raw:
            raise RuntimeError('Normal firmware reported a failure; see normal-reset.log')
        if b'NIHOS_NATIVE_FP_PASS' in raw and passed_at is None:
            passed_at = time.monotonic()
        if passed_at is not None and time.monotonic() - passed_at >= 3:
            break
    result.update({'log_sha256': hashlib.sha256(raw).hexdigest(), 'bytes_captured': len(raw),
                   'rom_boot_seen': b'ESP-ROM:' in raw, 'native_boot_seen': b'NIHOS_NATIVE_BOOT' in raw,
                   'native_fp_pass_seen': b'NIHOS_NATIVE_FP_PASS' in raw,
                   'capture_seconds': round(time.monotonic() - began, 3)})
    if not result['native_boot_seen'] or not result['native_fp_pass_seen']:
        raise RuntimeError('Normal boot capture incomplete; see normal-reset.log')
    print('Normal boot and final native FP_PASS observed', flush=True)
except Exception as error:
    result['error'] = str(error)
    raise
finally:
    if port.is_open:
        disable_hangup(port)
    port.close()
    result['serial_released'] = not port.is_open
    (RUN / 'return-to-normal.json').write_text(json.dumps(result, indent=2) + '\n')

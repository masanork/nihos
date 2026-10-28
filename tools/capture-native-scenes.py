#!/usr/bin/env python3
"""Install and observe one finite card-free scene exercise under an exclusive lease."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

SPEC = importlib.util.spec_from_file_location('scene_usb', Path(__file__).with_name('capture-native-usb.py'))
USB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(USB)


def main():
    import serial
    from esptool.reset import HardReset
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port')
    parser.add_argument('output', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--prior', type=Path, required=True)
    args = parser.parse_args()
    audit_path = args.candidate / 'image-audit.json'
    profile = json.loads(audit_path.read_text()).get('automatic_cards', {})
    if profile.get('scene_exercise') is not True or profile.get('read_enabled') is not False:
        parser.error('only audited card-free scene images may be installed')
    args.output.mkdir(parents=True, exist_ok=False)
    paths, audit_path = USB.snapshot_install(args.candidate, audit_path, args.output)
    with serial.Serial(args.port, 115200, timeout=.15, exclusive=True) as console:
        print('Exclusive card-free scene lease acquired', flush=True)
        USB.tool(console, args.output / 'verify-prior.log', 'verify_flash',
                 {address: args.prior / name for address, name in (('0x2000', 'bootloader.bin'), ('0x8000', 'partition-table.bin'), ('0x10000', 'nihos-native.bin'))})
        USB.tool(console, args.output / 'flash.log', 'write_flash', paths)
        USB.tool(console, args.output / 'verify-before.log', 'verify_flash', paths)
        console.dtr = False
        console.reset_input_buffer()
        HardReset(console, uses_usb=True)()
        data = bytearray()
        announced = set()
        started = time.monotonic()
        finished = None
        with (args.output / 'boot.raw.log').open('wb') as raw:
            while time.monotonic() - started < 120:
                block = console.read(max(1, console.in_waiting))
                if block:
                    data.extend(block)
                    raw.write(block)
                    raw.flush()
                text = data.decode('ascii', errors='replace').replace('\r', '')
                for line in text.splitlines():
                    if line.startswith(('NIHOS_NATIVE_CARD_SCENE ', 'NIHOS_NATIVE_CARD_SCENE_HANDOFF ', 'NIHOS_NATIVE_CARD_AUTO_DISPLAY ')) and line not in announced:
                        print(line, flush=True)
                        announced.add(line)
                if ('NIHOS_NATIVE_CARD_SCENE step=0000000c\n' in text or 'NIHOS_NATIVE_FAIL ' in text) and finished is None:
                    finished = time.monotonic()
                if finished is not None and time.monotonic() - finished > 2:
                    break
        (args.output / 'boot.log').write_bytes(data)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('check-native-scene-log.py')),
                                 str(args.output / 'boot.log'), str(audit_path), str(args.output / 'report.json')])
        if result.returncode:
            raise SystemExit('Scene exercise failed; evidence retained; no post-failure reset')
        (args.output / 'exclusive-complete.json').write_text(json.dumps({'card_free': True, 'scenes': 12, 'exclusive_descriptor_held': True, 'post_reset': False}) + '\n')
        print('Scene evidence passed; synthetic wait screen left on the device', flush=True)


if __name__ == '__main__':
    main()

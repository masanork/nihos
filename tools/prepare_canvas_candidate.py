#!/usr/bin/env python3
"""Inspect a local canvas fixture before any device access; does not flash."""
import argparse
import hashlib
import json
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def inspect(build):
    audit = json.loads((build / 'image-audit.json').read_text())
    image = (build / 'nihos-native.bin').read_bytes()
    elf = (build / 'nihos-native.elf').read_bytes()
    options = (build / 'native_options.zig').read_text()
    flags = {'canvas_demo': True, 'qualification': True, 'display_scanout': True,
             'psram_200': True, 'console': False, 'console_live': False,
             'card_read': False, 'keypad_demo': False, 'network': False,
             'devices': False, 'usb': False, 'sdmmc': False}
    for name, expected in flags.items():
        expected_line = f'pub const {name} = {str(expected).lower()};'
        if options.splitlines().count(expected_line) != 1:
            raise ValueError(f'candidate option {name} missing, duplicated or wrong')
    if (audit.get('rtos_linked') is not False or audit.get('memory', {}).get('profile') != 'device' or
            audit.get('image_sha256') != sha(image) or audit.get('elf_sha256') != sha(elf)):
        raise ValueError('candidate image or ELF does not match device audit')
    if image.count(b'NIHOS_NATIVE_CANVAS_PATTERN') != 1:
        raise ValueError('canvas evidence marker absent or duplicated in application image')
    binaries = {'bootloader': build / 'loader/bootloader/bootloader.bin',
                'partitions': build / 'loader/partition_table/partition-table.bin',
                'application': build / 'nihos-native.bin', 'elf': build / 'nihos-native.elf'}
    result = {name: {'path': str(path.resolve()), 'sha256': sha(path.read_bytes()), 'bytes': path.stat().st_size}
              for name, path in binaries.items()}
    return {'schema': 'nihos-canvas-candidate-v1', 'artifacts': result,
            'native_options_sha256': sha(options.encode()), 'audit_sha256': sha((build / 'image-audit.json').read_bytes()),
            'cpu_frame_fnv1a': '549e3481', 'physical_tested': False,
            'scope': 'local artifact consistency only; exact source provenance and device identity require separate evidence'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    parser.add_argument('receipt', type=Path)
    args = parser.parse_args()
    args.receipt.write_text(json.dumps(inspect(args.build), indent=2) + '\n')
    print('Canvas candidate artifacts and options checked; no device accessed')


if __name__ == '__main__':
    main()

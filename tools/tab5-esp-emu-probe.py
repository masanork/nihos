#!/usr/bin/env python3
"""Capture a bounded ESP-EMU Tab5 boot investigation; never touches a device."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('emulator', 'firmware', 'elf', 'rom', 'efuse', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--psram-size', choices=('0', '4M', '8M', '16M', '32M', '64M'), default='32M')
    parser.add_argument('--seconds', type=int, default=20)
    parser.add_argument('--expect', help='require this string in the captured console')
    args = parser.parse_args()
    if not 1 <= args.seconds <= 300:
        parser.error('--seconds must be between 1 and 300')
    paths = {name: getattr(args, name).resolve(strict=True) for name in ('emulator', 'firmware', 'elf', 'rom', 'efuse')}
    if any(not path.is_file() for path in paths.values()):
        parser.error('all inputs must be regular files')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # ESP-EMU may write the eFuse even without --save-state; isolate both mutable inputs.
    flash = output / 'flash.bin'
    efuse = output / 'efuse.bin'
    shutil.copyfile(paths['firmware'], flash)
    shutil.copyfile(paths['efuse'], efuse)
    before = {name: sha256(path) for name, path in paths.items()}
    cmd = [str(paths['emulator']), '--chip', 'esp32p4', '--firmware', str(flash),
           '--elf', str(paths['elf']), '--rom', str(paths['rom']), '--efuse', str(efuse),
           '--psram-size', args.psram_size, '--console', 'usb-jtag', '--timeout', f'{args.seconds}s']
    start = time.monotonic()
    with (output / 'console.log').open('wb') as stdout, (output / 'diagnostics.log').open('wb') as stderr:
        try:
            result = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                    timeout=args.seconds + 15, check=False)
            returncode = result.returncode
            host_timeout = False
        except subprocess.TimeoutExpired:
            returncode = None
            host_timeout = True
    elapsed = time.monotonic() - start
    console = (output / 'console.log').read_bytes()
    found = args.expect is None or args.expect.encode() in console
    report = {'schema': 1, 'scope': 'ESP-EMU Tab5 boot probe; not physical evidence',
              'inputs': {name: {'path': str(path), 'sha256': before[name]} for name, path in paths.items()},
              'psram_size': args.psram_size, 'seconds': args.seconds, 'command': cmd,
              'elapsed_seconds': round(elapsed, 3), 'returncode': returncode, 'host_timeout': host_timeout,
              'expect': args.expect, 'expect_found': found,
              'console_sha256': sha256(output / 'console.log'),
              'diagnostics_sha256': sha256(output / 'diagnostics.log'),
              'final_flash_sha256': sha256(flash), 'final_efuse_sha256': sha256(efuse)}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'report': str(output / 'report.json'), 'returncode': returncode,
                      'host_timeout': host_timeout, 'expect_found': found}))
    return 0 if returncode == 0 and not host_timeout and found else 1


if __name__ == '__main__':
    raise SystemExit(main())

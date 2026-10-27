#!/usr/bin/env python3
"""Retain build inputs/artifacts for private normal-boot networking images."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output, sdk = map(Path, sys.argv[1:])
    audit = json.loads((output / 'image-audit.json').read_text())
    if digest(output / 'nihos-native.bin') != audit['image_sha256']:
        raise ValueError('image/audit mismatch')
    names = git('ls-files', '--cached', '--others', '--exclude-standard', '--',
                'src', 'include', 'tools', 'probes', 'ports/esp32p4-native', 'provenance.toml').splitlines()
    names = sorted(set(names))
    artifacts = ('nihos-native.bin', 'nihos-native.elf', 'image-audit.json',
                 'native_options.zig', 'native-layout.ld', 'loader/sdkconfig')
    receipt = {'scope': 'normal-boot network integration build; execution unqualified',
               'commit': git('rev-parse', 'HEAD'), 'dirty': bool(git('status', '--porcelain')),
               'sdk_commit': git('rev-parse', 'HEAD', cwd=sdk),
               'sdk_dirty': bool(git('status', '--porcelain', cwd=sdk)),
               'sources': {name: digest(ROOT / name) for name in names},
               'artifacts': {name: digest(output / name) for name in artifacts},
               'private_configuration_withheld': True}
    (output / 'network-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Private network integration receipt retained; credentials withheld')


if __name__ == '__main__':
    main()

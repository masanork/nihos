#!/usr/bin/env python3
"""Reject an old linked ordinary-FS identity paired with edited metadata."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import runpy
import normal_fs_manifest

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    directory = args.directory
    manifest = json.loads((directory / 'normal-fs-manifest.json').read_text())
    elf = (directory / 'nihos-native.elf').read_bytes()
    image = (directory / 'nihos-native.bin').read_bytes()
    normal_fs_manifest.verify_files(directory, manifest)
    audit = runpy.run_path(str(ROOT / 'tools/check-native-image.py'))['audit']
    report = audit(elf, image, 'integer', 'device', normal_fs_manifest=manifest)
    cases = []
    changed = copy.deepcopy(manifest)
    changed['sources']['src/platform/native/normal_fs.zig'] = '0' * 64
    cases.append(('edited-source-sidecar', changed, elf))
    changed = copy.deepcopy(manifest)
    changed['objects']['normal_fs_runtime.o']['sha256'] = '0' * 64
    cases.append(('edited-object-sidecar', changed, elf))
    changed = copy.deepcopy(manifest)
    changed['profile'][1] = 32768
    cases.append(('smaller-parent-claim', changed, elf))
    changed = copy.deepcopy(manifest)
    changed['objects']['normal_fs_runtime.o']['functions'].append('arbitrary.irq')
    changed['allowed_functions'] = sorted(set(changed['allowed_functions']) | {'arbitrary.irq'})
    cases.append(('expanded-function-sidecar', changed, elf))
    cases.append(('missing-service-sidecar', None, elf))
    results = []
    for name, changed, binary in cases:
        try:
            audit(binary, None, 'integer', 'device', normal_fs_manifest=changed)
        except ValueError as error:
            results.append({'name': name, 'rejected': True, 'reason': str(error)})
        else:
            raise RuntimeError('ordinary FS identity mutation accepted: ' + name)
    result = {'passed': True, 'hardware_executed': False, 'elf_sha256': hashlib.sha256(elf).hexdigest(),
        'image_sha256': hashlib.sha256(image).hexdigest(), 'profile': report['normal_fs'], 'cases': results}
    (directory / 'normal-fs-negative-controls.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Ordinary FS linked identity and 5 negative controls passed; no hardware execution')


if __name__ == '__main__':
    main()

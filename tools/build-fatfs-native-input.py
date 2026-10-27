#!/usr/bin/env python3
"""Create a pinned private FAT12 image and lossless sparse/RLE Flash fixture."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(directory):
    directory.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='fatfs-input-', dir=directory))
    bootstrap = runpy.run_path(str(ROOT / 'tools/bootstrap-fatfs.py'))
    cache = work / 'upstream'
    cache.mkdir()
    for name, _, expected in bootstrap['INPUTS']:
        cached = ROOT / '.tools/fatfs-r016-p2' / name
        if cached.is_file() and sha(cached) == expected:
            shutil.copyfile(cached, cache / name)
    source = bootstrap['bootstrap'](cache)
    probe = ROOT / 'probes/fatfs-disk'
    cc = shlex.split(os.environ.get('CC', 'cc'))
    writer = work / 'writer'
    subprocess.run([*cc, '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror', '-DNIHOS_FIXTURE_WRITER=1',
                    '-I' + str(probe), '-I' + str(source), str(probe / 'make_fixture.c'),
                    str(probe / 'host_disk.c'), str(source / 'ff.c'), str(source / 'ffunicode.c'), '-o', str(writer)], check=True)
    image = work / 'fat12.img'
    fixture = json.loads(subprocess.check_output([str(writer), str(image), 'fat12'], text=True))
    original = image.read_bytes()
    encoded = bytearray()
    entries = []
    decoded = bytearray(len(original))
    for lba in range(len(original) // 512):
        sector = original[lba * 512:(lba + 1) * 512]
        if not any(sector):
            continue
        start = len(encoded)
        at = 0
        while at < 512:
            end = at + 1
            while end < 512 and end - at < 255 and sector[end] == sector[at]:
                end += 1
            encoded.extend((end - at, sector[at]))
            decoded[lba * 512 + at:lba * 512 + end] = bytes([sector[at]]) * (end - at)
            at = end
        entries.append((lba, start, len(encoded) - start))
    if decoded != original or len(encoded) > 65535:
        raise RuntimeError('Fixture encoding is not lossless or exceeds u16 bounds')
    checksum = sha(image)
    header = work / 'fatfs_fixture_data.h'
    header.write_text('/* Generated private fixture, not an SD card image write. */\n'
        '#define NIH_FATFS_FIXTURE_SECTORS ' + str(len(original) // 512) + 'u\n'
        '#define NIH_FATFS_FIXTURE_ID 0x' + checksum[:8] + 'u\n'
        'typedef struct { uint32_t lba; uint16_t offset, length; } nih_fixture_entry;\n'
        'const uint8_t nih_fatfs_fixture_payload[] = {' + ','.join(str(x) for x in encoded) + '};\n'
        'const nih_fixture_entry nih_fatfs_fixture_index[] = {' + ','.join('{%d,%d,%d}' % x for x in entries) + '};\n'
        'const uint32_t nih_fatfs_fixture_geometry[4] = {NIH_FATFS_FIXTURE_SECTORS, sizeof nih_fatfs_fixture_payload, '
        'sizeof nih_fatfs_fixture_index / sizeof *nih_fatfs_fixture_index, NIH_FATFS_FIXTURE_ID};\n')
    manifest = {'schema': 1, 'source': 'embedded sparse/RLE FAT12 fixture; not SD FatFs',
        'image_sha256': checksum, 'image_bytes': len(original), 'fixture_id': int(checksum[:8], 16),
        'payload_bytes': len(encoded), 'index_entries': len(entries), 'fixture': fixture,
        'header': str(header), 'header_sha256': sha(header), 'source_directory': str(source), 'image': str(image),
        'upstream': {p.name: sha(p) for p in source.iterdir()},
        'sources': {str(p.relative_to(ROOT)): sha(p) for p in (Path(__file__), probe / 'make_fixture.c',
                     probe / 'host_disk.c', probe / 'host_disk.h', probe / 'ffconf.h', ROOT / 'tools/bootstrap-fatfs.py')}}
    path = work / 'manifest.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    return path


if __name__ == '__main__':
    import sys
    print(build(Path(sys.argv[1]).resolve()))

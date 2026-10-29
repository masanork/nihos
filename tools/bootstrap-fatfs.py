#!/usr/bin/env python3
"""Fetch FatFs R0.16 plus official patches, verifying every input and output."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INPUTS = (
    ("ff16.zip", "https://elm-chan.org/fsw/ff/arc/ff16.zip", "99f7dc1f7e095356e4a9e3dbe29959090d8b948afe2bbc5441e52fdf4b85449e"),
    ("ff16p1.diff", "https://elm-chan.org/fsw/ff/patch/ff16p1.diff", "7996ddc3135f3d534a8153f7d75d587030e5c8551b003c3b7ee823ffb7fc64bf"),
    ("ff16p2.diff", "https://elm-chan.org/fsw/ff/patch/ff16p2.diff", "5cd39f1fc299f0f1dec9fa1ce544dc0bc048b2f6eb3b8161476ed20f9cf1e290"),
)
PATCHED_HASH = "3c30280ffe2d0fb19a5241d9ed9f20a2c3911c2861652ebf6ad57f74fb369250"
# The pinned archive's extracted headers and Unicode table, including CRLF.
SOURCE_HASHES = {
    'ff.h': '42920ae4d6080bfc2a72d92a9969b5e94eeaff070e5e71d90da9ab6d7d8e158e',
    'ffunicode.c': '3f1632c1f1e64b0b683b0d7e51341b9870728f398604869dd8211f1819509a8e',
    'diskio.h': '1c2b29f53e061c55d43b2e412c3a61320b2621bac7561a05e275514baa44785a',
}
MIRROR_PATCHED = 'https://raw.githubusercontent.com/zephyrproject-rtos/fatfs/1df06d036cc57f0abbadfd56b567970d5ccf827c/ff.c'
MIRROR_SOURCE = 'https://raw.githubusercontent.com/rondlh/3D-printer-USB-bootloader-for-MAX3421-on-STM32H723/ad13fadc5e0610562364d6d582477e3fa62a7d5c/FATFS/'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read(4 * 1024 * 1024)


def official(stage, cache):
    for name, url, expected in INPUTS:
        dest = cache / name
        if not dest.exists() or digest(dest) != expected:
            data = fetch(url)
            if hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError(f"FatFs checksum mismatch: {name}")
            dest.write_bytes(data)
        if digest(dest) != expected:
            raise RuntimeError(f"FatFs cache checksum mismatch: {name}")
    with zipfile.ZipFile(cache / 'ff16.zip') as archive:
        for name in ('ff.c', *SOURCE_HASHES):
            data = archive.read(f'source/{name}')
            if name == 'ff.c':
                data = data.replace(b'\r\n', b'\n')
            (stage / name).write_bytes(data)
    for name, _, _ in INPUTS[1:]:
        subprocess.run(['patch', '-s', str(stage / 'ff.c'), str(cache / name)], check=True)


def fallback(stage):
    # Mirrors transport the same source bytes, not a fork of the implementation.
    patched = fetch(MIRROR_PATCHED).replace(b'\r\n', b'\n')
    if hashlib.sha256(patched).hexdigest() != PATCHED_HASH:
        raise RuntimeError('FatFs fallback patched ff.c checksum mismatch')
    (stage / 'ff.c').write_bytes(patched)
    for name, expected in SOURCE_HASHES.items():
        data = fetch(MIRROR_SOURCE + name).replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f'FatFs fallback checksum mismatch: {name}')
        (stage / name).write_bytes(data)


def bootstrap(cache=None):
    cache = Path(cache) if cache is not None else ROOT / '.tools' / 'fatfs-r016-p2'
    cache.mkdir(parents=True, exist_ok=True)
    source = cache / 'source'
    expected_sources = {'ff.c': PATCHED_HASH, **SOURCE_HASHES}
    # Content hashes, rather than existence, make reuse safe across CI builds.
    if all((source / name).is_file() and digest(source / name) == expected for name, expected in expected_sources.items()):
        return source
    # Reconstruct whenever any cached source is absent or modified.
    with tempfile.TemporaryDirectory(prefix='source-', dir=cache) as temp:
        stage = Path(temp)
        try:
            official(stage, cache)
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            fallback(stage)
        if digest(stage / 'ff.c') != PATCHED_HASH:
            raise RuntimeError('Patched ff.c checksum mismatch')
        for name, expected in SOURCE_HASHES.items():
            if digest(stage / name) != expected:
                raise RuntimeError(f'FatFs extracted checksum mismatch: {name}')
        source = cache / 'source'
        source.mkdir(exist_ok=True)
        for name in ('ff.c', *SOURCE_HASHES):
            (source / name).write_bytes((stage / name).read_bytes())
    return source


if __name__ == '__main__':
    print(bootstrap())

#!/usr/bin/env python3
"""Fetch FatFs R0.16 plus official patches, verifying every input and output."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INPUTS = (
    ("ff16.zip", "https://elm-chan.org/fsw/ff/arc/ff16.zip", "99f7dc1f7e095356e4a9e3dbe29959090d8b948afe2bbc5441e52fdf4b85449e"),
    ("ff16p1.diff", "https://elm-chan.org/fsw/ff/patch/ff16p1.diff", "7996ddc3135f3d534a8153f7d75d587030e5c8551b003c3b7ee823ffb7fc64bf"),
    ("ff16p2.diff", "https://elm-chan.org/fsw/ff/patch/ff16p2.diff", "5cd39f1fc299f0f1dec9fa1ce544dc0bc048b2f6eb3b8161476ed20f9cf1e290"),
)
PATCHED_HASH = "3c30280ffe2d0fb19a5241d9ed9f20a2c3911c2861652ebf6ad57f74fb369250"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bootstrap(cache=None):
    cache = Path(cache) if cache is not None else ROOT / ".tools" / "fatfs-r016-p2"
    cache.mkdir(parents=True, exist_ok=True)
    for name, url, expected in INPUTS:
        dest = cache / name
        if not dest.exists() or digest(dest) != expected:
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read(4 * 1024 * 1024)
            if hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError(f"FatFs checksum mismatch: {name}")
            dest.write_bytes(data)
        if digest(dest) != expected:
            raise RuntimeError(f"FatFs cache checksum mismatch: {name}")
    # Reconstruct source each run; cached edits are never silently accepted.
    with tempfile.TemporaryDirectory(prefix="source-", dir=cache) as temp:
        stage = Path(temp)
        with zipfile.ZipFile(cache / "ff16.zip") as archive:
            for name in ("ff.c", "ff.h", "ffunicode.c", "diskio.h"):
                data = archive.read(f"source/{name}")
                if name == "ff.c":
                    data = data.replace(b"\r\n", b"\n")
                (stage / name).write_bytes(data)
        for name, _, _ in INPUTS[1:]:
            subprocess.run(["patch", "-s", str(stage / "ff.c"), str(cache / name)], check=True)
        if digest(stage / "ff.c") != PATCHED_HASH:
            raise RuntimeError("Patched ff.c checksum mismatch")
        source = cache / "source"
        source.mkdir(exist_ok=True)
        for path in stage.iterdir():
            if path.name in ("ff.c", "ff.h", "ffunicode.c", "diskio.h"):
                (source / path.name).write_bytes(path.read_bytes())
    return source


if __name__ == "__main__":
    print(bootstrap())

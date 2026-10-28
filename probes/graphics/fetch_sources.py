#!/usr/bin/env python3
"""Checksum-pinned host experiment dependencies. Never accesses a device."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/graphics-probe/sources"

MODULES = """/* nihos static TrueType host experiment; see sources.json. */
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
"""


def fetch(item):
    target = OUT / item["name"]
    if not target.exists():
        temporary = target.with_suffix(target.suffix + ".next")
        subprocess.run(["curl", "-fsSL", "--retry", "2", item["url"], "-o", str(temporary)], check=True)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("download checksum mismatch: " + item["name"])
        temporary.replace(target)
    if hashlib.sha256(target.read_bytes()).hexdigest() != item["sha256"]:
        raise ValueError("cached checksum mismatch: " + item["name"])
    if "extract" in item:
        destination = OUT / item["extract"]
        with tarfile.open(target) as archive:
            for member in archive:
                parts = PurePosixPath(member.name).parts
                if member.name.startswith("/") or ".." in parts:
                    raise ValueError("unsafe archive path")
                if not member.isfile() or len(parts) < 2:
                    continue
                path = destination.joinpath(*parts[1:])
                data = archive.extractfile(member).read()
                path.parent.mkdir(parents=True, exist_ok=True)
                if not path.exists() or path.read_bytes() != data:
                    path.write_bytes(data)


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "probes/graphics/sources.json").read_text())
    with ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(fetch, manifest))
    # Restore the pinned archive before applying each tracked local patch.
    patch = ROOT / "probes/graphics/patches/freetype-autofit-map-error.patch"
    subprocess.run(["patch", "--batch", "--forward", "-s", "-p1", "-i", str(patch)], cwd=OUT / "freetype", check=True, capture_output=True)
    # Select only the modules used by the experiment.
    path = OUT / "freetype/include/freetype/config/ftmodule.h"
    if path.read_text() != MODULES:
        path.write_text(MODULES)


def snapshot(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob("*")) if p.is_file() and
            p.name not in (".nihos-prepared.json", ".nihos-prepared.next")}


def verify_prepared(directory, state, key):
    if state.get("schema") != 1 or state.get("key") != key:
        raise ValueError("prepared source version differs; use a fresh generated source cache")
    if state.get("files") != snapshot(directory):
        raise ValueError("prepared source cache changed; refusing to mutate sources used by builds")


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256((ROOT / "probes/graphics/sources.json").read_bytes() +
                         (ROOT / "probes/graphics/patches/freetype-autofit-map-error.patch").read_bytes() +
                         MODULES.encode()).hexdigest()
    # One preparer publishes a complete snapshot; all later builds only verify.
    # Holding a lock just during repeated extraction would still let a compiler
    # observe the temporary unpatched source after that lock was released.
    with (OUT.parent / "graphics-sources.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        witness = OUT / ".nihos-prepared.json"
        if witness.exists():
            verify_prepared(OUT, json.loads(witness.read_text()), key)
        else:
            prepare()
            state = {"schema": 1, "key": key, "files": snapshot(OUT)}
            temporary = OUT / ".nihos-prepared.next"
            temporary.write_text(json.dumps(state, indent=2) + "\n")
            temporary.replace(witness)
        print(OUT)

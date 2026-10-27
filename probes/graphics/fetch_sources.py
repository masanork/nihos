#!/usr/bin/env python3
"""Checksum-pinned host experiment dependencies. Never accesses a device."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/graphics-probe/sources"


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


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "probes/graphics/sources.json").read_text())
    with ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(fetch, manifest))
    # Restore the pinned archive before applying each tracked local patch.
    patch = ROOT / "probes/graphics/patches/freetype-autofit-map-error.patch"
    subprocess.run(["patch", "-s", "-p1", "-i", str(patch)], cwd=OUT / "freetype", check=True)
    # Select only the modules used by the experiment.
    modules = """/* nihos static TrueType host experiment; see sources.json. */
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
"""
    path = OUT / "freetype/include/freetype/config/ftmodule.h"
    if path.read_text() != modules:
        path.write_text(modules)
    print(OUT)

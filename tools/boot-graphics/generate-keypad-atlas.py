#!/usr/bin/env python3
"""Bake the real Zig demo renderer's immutable pixel spans for read-only Flash."""
import ctypes
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ('src/graphics/card_pin.zig', 'src/graphics/card_pin.rle',
           'src/graphics/card_pin_assets.zig', 'src/graphics/keypad_plan.zig',
           'src/card_pin_preview.zig', 'tools/boot-graphics/generate-keypad-atlas.py',
           'src/platform/native/dma_memory.zig', 'src/platform/native/memory.zig', 'src/platform/native/base_sram.c', 'src/platform/native/sram_pool.h', 'src/platform/native/esp32p4.ld',
           'src/graphics/surface.zig', 'src/platform/native/card_boot.zig', 'src/graphics/card_boot/masks.rle',
           'src/platform/native/main.zig', 'src/graphics/card_boot/assets.zig', 'src/graphics/card_splash.zig',
           'src/graphics/card_boot/manifest.json', 'tools/design/card-splash-assets.py', 'tools/design/shape-mask.cpp')


def main():
    out = ROOT / 'build/keypad-atlas-generator'
    out.mkdir(parents=True, exist_ok=True)
    library = out / ('preview.dylib' if sys.platform == 'darwin' else 'preview.so')
    subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'build-lib', '-dynamic', '-OReleaseSafe',
                    str(ROOT / 'src/card_pin_preview.zig'), f'-femit-bin={library}'], check=True)
    loaded = ctypes.CDLL(str(library))
    frame = (ctypes.c_ubyte * (720 * 1280 * 2))()
    paint = loaded.nih_keypad_demo_preview
    paint.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t, ctypes.c_ubyte, ctypes.c_bool]
    paint.restype = ctypes.c_bool
    assert paint(frame, len(frame), 0, True)
    class Span(ctypes.Structure):
        _fields_ = [('kind', ctypes.c_uint32), ('offset', ctypes.c_uint32),
                    ('words', ctypes.c_uint32), ('reserved', ctypes.c_uint32)]
    spans = (Span * 2048)()
    build = loaded.nih_keypad_copy_plan
    build.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_size_t, ctypes.POINTER(Span), ctypes.c_size_t]
    build.restype = ctypes.c_size_t
    count = build(frame, len(frame), spans, len(spans))
    assert 0 < count <= 1024
    pixels = bytes(frame)
    atlas = bytearray()
    encoded = bytearray()
    for span in spans[:count]:
        offset = span.offset
        if span.kind == 3:
            offset = len(atlas)
            atlas += pixels[span.offset:span.offset + span.words * 8]
        encoded += struct.pack('<IIII', span.kind, offset, span.words, span.reserved)
    path = ROOT / 'src/graphics'
    (path / 'keypad_atlas.bin').write_bytes(atlas)
    (path / 'keypad_atlas_plan.bin').write_bytes(encoded)
    manifest = {'schema': 1, 'plan_bytes': len(encoded), 'plan_sha256': hashlib.sha256(encoded).hexdigest(),
                'atlas_bytes': len(atlas), 'atlas_sha256': hashlib.sha256(atlas).hexdigest(),
                'nodes': count, 'frame_words': 230400,
                'sources': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}}
    (path / 'keypad_atlas.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{count} descriptors, {len(atlas)} immutable pixel bytes')


if __name__ == '__main__':
    main()

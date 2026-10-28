#!/usr/bin/env python3
"""Render the production boot compositor and sparse plan on the host."""
import argparse
import ctypes
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/card-boot/preview.png')
    args = parser.parse_args()
    directory = ROOT / 'build/card-boot'
    directory.mkdir(parents=True, exist_ok=True)
    library = directory / ('preview.dylib' if sys.platform == 'darwin' else 'preview.so')
    subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'build-lib', '-dynamic', '-OReleaseSafe',
                    str(ROOT / 'src/card_boot_preview.zig'), '-femit-bin=' + str(library)], check=True)
    renderer = ctypes.CDLL(str(library))
    renderer.paint.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t]
    renderer.paint.restype = ctypes.c_bool
    renderer.spans.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                              ctypes.POINTER(ctypes.c_uint32), ctypes.c_size_t]
    renderer.spans.restype = ctypes.c_size_t
    frame = (ctypes.c_uint8 * (720 * 1280 * 2))()
    plan = (ctypes.c_uint32 * (2048 * 4))()
    if not renderer.paint(frame, len(frame)):
        raise SystemExit('production boot painter rejected frame')
    count = renderer.spans(frame, len(frame), plan, 2048)
    if not 0 < count <= 1280:
        raise SystemExit('production sparse plan outside descriptor capacity')
    data = bytes(frame)
    (directory / 'frame.bin').write_bytes(data)
    (directory / 'plan.bin').write_bytes(bytes(plan)[:count * 16])
    rgb = bytearray()
    for (pixel,) in struct.iter_unpack('<H', data):
        rgb.extend((((pixel >> 11) & 31) * 255 // 31, ((pixel >> 5) & 63) * 255 // 63, (pixel & 31) * 255 // 31))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    Image.frombytes('RGB', (720, 1280), bytes(rgb)).save(args.output)
    previous = [None, None]
    pixel_bytes = 0
    for i in range(count):
        kind, offset, words, _ = plan[i * 4:i * 4 + 4]
        if kind != 3:
            continue
        group = int(offset % 1440 >= 912 and 192 <= offset // 1440 < 448)
        segment = data[offset:offset + words * 8]
        if segment != previous[group]:
            pixel_bytes += len(segment)
        previous[group] = segment
    result = {'scope': 'host raster and plan; production C capacity replay is checked separately',
              'nodes': count, 'descriptor_bytes': count * 64, 'pixel_bytes': pixel_bytes,
              'dynamic_texture_bytes': 0, 'estimated_scanout_bytes': count * 64 + pixel_bytes,
              'frame_sha256': hashlib.sha256(data).hexdigest(), 'png_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}
    (directory / 'preview.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()

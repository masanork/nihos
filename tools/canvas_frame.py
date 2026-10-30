"""Validate and convert an emulated RGB565LE frame to a portable PNG."""
import array
import functools
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

WIDTH, HEIGHT = 720, 1280
FRAME_BYTES = WIDTH * HEIGHT * 2
EXPECTED_FNV = 0x549e3481


def fnv1a(data):
    value = 0x811c9dc5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xffffffff
    return value


def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)


@functools.lru_cache(maxsize=1)
def rgb565_table():
    # Keep the same nearest-integer expansion used by the previous converter.
    return tuple(bytes((((pixel >> 11) * 255 + 15) // 31,
                        (((pixel >> 5) & 63) * 255 + 31) // 63,
                        ((pixel & 31) * 255 + 15) // 31)) for pixel in range(65536))


def png_rgb565(data, width, height):
    if width <= 0 or height <= 0 or len(data) != width * height * 2:
        raise ValueError('invalid RGB565 frame dimensions')
    pixels = array.array('H')
    if pixels.itemsize != 2:
        raise RuntimeError('platform has non-16-bit unsigned short')
    pixels.frombytes(data)
    if sys.byteorder != 'little':
        pixels.byteswap()
    table = rgb565_table()
    scan = bytearray()
    for row in range(height):
        scan.append(0)
        scan.extend(b''.join(map(table.__getitem__, pixels[row * width:(row + 1) * width])))
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(scan)) + chunk(b'IEND', b'')


def save_frame(raw, png, receipt):
    data = Path(raw).read_bytes()
    if len(data) != FRAME_BYTES or fnv1a(data) != EXPECTED_FNV:
        raise ValueError('emulated framebuffer size or checksum mismatch')
    image = png_rgb565(data, WIDTH, HEIGHT)
    Path(png).write_bytes(image)
    result = {'source': 'esp32p4-emulator-psram-gdb', 'width': WIDTH, 'height': HEIGHT,
              'pixel_format': 'RGB565LE', 'frame_fnv1a': f'{EXPECTED_FNV:08x}',
              'raw_sha256': hashlib.sha256(data).hexdigest(), 'png_sha256': hashlib.sha256(image).hexdigest()}
    Path(receipt).write_text(json.dumps(result, indent=2) + '\n')
    return result

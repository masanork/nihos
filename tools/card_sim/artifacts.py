"""Lossless view of the reconstructed RGB565 frame, using Python stdlib only."""
import struct
import zlib


def png(rgb565, landscape=False):
    if len(rgb565) != 720 * 1280 * 2:
        raise ValueError('invalid frame geometry')
    pixels = bytearray()
    words = struct.unpack('<' + 'H' * (720 * 1280), rgb565)
    width, height = (1280, 720) if landscape else (720, 1280)
    for y in range(height):
        pixels.append(0)  # PNG filter: None
        row = (words[(1279 - x) * 720 + y] for x in range(1280)) if landscape else words[y * 720:(y + 1) * 720]
        for p in row:
            pixels.extend((((p >> 11) * 255 + 15) // 31,
                           (((p >> 5) & 63) * 255 + 31) // 63,
                           ((p & 31) * 255 + 15) // 31))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))

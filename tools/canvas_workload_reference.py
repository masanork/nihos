"""Independent per-pixel reference for small deterministic RV32 workloads."""
import struct

WIDTH, HEIGHT = 320, 200
BYTES = WIDTH * HEIGHT * 2


def editor_pixel(x, y):
    # Clipped axis lines are drawn after scrolling; vertical line wins at crossings.
    if x == 15 and y == 15:
        return 0xffff
    if x == 270 and 12 <= y < 182:
        return 0x001f
    if y == 20 and 10 <= x < 290:
        return 0xf800
    # Scroll reads the original row 16 pixels lower; newly exposed rows are blank.
    if y >= 184:
        return 0x1082
    old_y = y + 16
    if 30 <= x < 150 and 56 <= old_y < 65:
        return 0x07ff
    for line in range(12):
        if 8 <= x < 228 and 8 + line * 12 <= old_y < 15 + line * 12:
            return (line * 997 + 0x1234) & 0xffff
    return 0x1082


def indexed_pixel(x, y):
    index = ((x // 2) * 3 + (y // 2) * 5) & 255
    return (index * 257) ^ 0x5a5a


def reference(kind):
    pixel = {'scroll': editor_pixel, 'indexed': indexed_pixel}[kind]
    out = bytearray(BYTES)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            struct.pack_into('<H', out, (y * WIDTH + x) * 2, pixel(x, y))
    return bytes(out)


def verify(kind, actual):
    expected = reference(kind)
    if len(actual) != len(expected):
        raise ValueError(f'{kind}: wrong frame length')
    if actual != expected:
        index = next(i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1])
        raise ValueError(f'{kind}: pixel mismatch at byte {index}')

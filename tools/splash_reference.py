"""Independent per-pixel model of the fixed RV32 splash workload."""
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 720, 1280
BACKGROUND = (17, 17, 17)
PAPER = (225, 225, 225)
MUTED = (132, 132, 132)
VERMILION = (220, 94, 66)
SPRITE = re.compile(r'\.\{ \.x = (\d+), \.y = (\d+), \.width = (\d+), \.height = (\d+), \.offset = (\d+), \.length = (\d+), \.ink = \.(normal|muted|dye|@"error"), \.group = (\d+), \.status = (\d+), \.layout = \.(portrait|landscape) \}')


def mix(a, b, amount):
    return tuple((x * (255 - amount) + y * amount + 127) // 255 for x, y in zip(a, b))


def rgb565(color):
    r, g, b = color
    return (r >> 3) << 11 | (g >> 2) << 5 | b >> 3


def reference(layout, progress, status=5):
    if layout not in ('portrait', 'landscape') or not isinstance(progress, int) or not 0 <= progress <= 255 or status not in range(1, 8):
        raise ValueError('invalid splash workload')
    frame = bytearray(struct.pack('<H', rgb565(BACKGROUND)) * (WIDTH * HEIGHT))
    assets = ROOT / 'src/graphics/boot'
    text = (assets / 'assets.zig').read_text()
    sprites = SPRITE.findall(text)
    if not sprites:
        raise ValueError('no splash sprites')
    masks = (assets / 'masks.rle').read_bytes()

    def put(x, y, color):
        px, py = (x, y) if layout == 'portrait' else (y, 1279 - x)
        if not 0 <= px < WIDTH or not 0 <= py < HEIGHT:
            raise ValueError('splash pixel outside framebuffer')
        struct.pack_into('<H', frame, (py * WIDTH + px) * 2, color)

    for sx, sy, sw, sh, offset, length, ink, group, sprite_status, which in sprites:
        sx, sy, sw, sh, offset, length, group, sprite_status = map(int, (sx, sy, sw, sh, offset, length, group, sprite_status))
        if which != layout or sprite_status not in (0, status):
            continue
        dye = min(max(progress - group * 64, 0) * 255 // 127, 255)
        color = {'normal': PAPER, 'muted': MUTED, 'dye': mix(PAPER, VERMILION, dye), '@"error"': VERMILION}[ink]
        index = 0
        runs = masks[offset:offset + length]
        if len(runs) != length:
            raise ValueError('truncated splash mask')
        for run in runs:
            alpha, count = (run >> 4) * 17, (run & 15) + 1
            if alpha:
                pixel = rgb565(mix(BACKGROUND, color, alpha))
                for i in range(index, index + count):
                    put(sx + i % sw, sy + i // sw, pixel)
            index += count
        if index != sw * sh:
            raise ValueError('invalid splash mask geometry')
    marker = rgb565(VERMILION if status == 6 else mix(MUTED, VERMILION, progress))
    mx, my = (92, 1166) if layout == 'portrait' else (102, 647)
    for y in range(6):
        for x in range(6):
            put(mx + x, my + y, marker)
    return bytes(frame)

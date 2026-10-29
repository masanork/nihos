"""Independent per-pixel model of the fixed RV32 console workload."""
import re
import struct
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/console'))
from font_rle import decode

WIDTH, HEIGHT = 720, 1280
BACKGROUND, FOREGROUND, ACCENT = 0x1082, 0xa5f5, 0x85b5
CONTROL_BORDER, CONTROL_INK = 0x3186, 0x528a


def blend(background, foreground, alpha):
    r = ((background >> 11) * (15 - alpha) + (foreground >> 11) * alpha + 7) // 15
    g = (((background >> 5) & 63) * (15 - alpha) + ((foreground >> 5) & 63) * alpha + 7) // 15
    b = ((background & 31) * (15 - alpha) + (foreground & 31) * alpha + 7) // 15
    return (r << 11) | (g << 5) | b


def reference(font):
    if font not in ('basic-light', 'jetbrains', 'source-code'):
        raise ValueError('unknown console face')
    small = font == 'basic-light'
    cell_w, cell_h, margin_x, margin_y, columns, rows = (16, 16, 16, 16, 78, 43) if small else (15, 30, 40, 24, 80, 22)
    lines = ['NIHOS RV32 CONSOLE'] + ['fixed header'] * 6
    lines += [chr(ord('A') + row % 26) + ' deterministic console line' for row in range(9, rows - 1)]
    lines += ['first scroll', 'second scroll', '']
    lines[9] = '> ' + lines[9]  # independently expected result of the edit trace
    assert len(lines) == rows and all(len(line) <= columns for line in lines)
    frame = bytearray(struct.pack('<H', BACKGROUND) * (WIDTH * HEIGHT))

    def put(logical_x, logical_y, color):
        struct.pack_into('<H', frame, ((1279 - logical_x) * WIDTH + logical_y) * 2, color)

    basic = (ROOT / 'src/graphics/ascii/basic.bin').read_bytes()
    if not small:
        name = font.replace('-', '_')
        text = (ROOT / 'src/graphics/ascii' / (name + '.zig')).read_text()
        entries = [tuple(map(int, pair)) for pair in re.findall(r'offset = (\d+), \.length = (\d+)', text)]
        blob = (ROOT / 'src/graphics/ascii' / (name + '.rle')).read_bytes()
        masks = [decode(blob[offset:offset + length]) for offset, length in entries]
        if len(masks) != 95 or any(len(mask) != cell_w * cell_h for mask in masks):
            raise ValueError('invalid console font')
    for row, line in enumerate(lines):
        foreground = ACCENT if row == 0 else FOREGROUND
        for col, char in enumerate(line):
            char_index = ord(char) - 32
            if small:
                bits = basic[char_index * 8:char_index * 8 + 8]
                for y in range(16):
                    for x in range(16):
                        bx, by = x // 2, y // 2
                        if not bits[by] & (1 << bx):
                            continue
                        right = x % 2 == 1 and (bx == 7 or not bits[by] & (1 << (bx + 1)))
                        bottom = y % 2 == 1 and (by == 7 or not bits[by + 1] & (1 << bx))
                        alpha = 4 if right and bottom else 8 if right or bottom else 15
                        put(margin_x + col * cell_w + x, margin_y + row * cell_h + y, blend(BACKGROUND, foreground, alpha))
            else:
                for index, alpha in enumerate(masks[char_index]):
                    if alpha:
                        put(margin_x + col * cell_w + index % cell_w, margin_y + row * cell_h + index // cell_w, blend(BACKGROUND, foreground, alpha))
    left, top, right, bottom = 1100, 650, 1260, 706
    for x in range(left, right):
        for y in range(top, bottom):
            border = x < left + 2 or x + 2 >= right or y < top + 2 or y + 2 >= bottom
            put(x, y, CONTROL_BORDER if border else BACKGROUND)
    label = 'LOGS'
    start_x = left + (right - left - len(label) * 16) // 2
    start_y = top + (bottom - top - 16) // 2
    for char_index, char in enumerate(label):
        bits = basic[(ord(char) - 32) * 8:(ord(char) - 32) * 8 + 8]
        for y in range(16):
            for x in range(16):
                if bits[y // 2] & (1 << (x // 2)):
                    put(start_x + char_index * 16 + x, start_y + y, CONTROL_INK)
    return bytes(frame)

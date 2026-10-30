#!/usr/bin/env python3
"""Independent pixel-by-pixel RGB565 reference using captured host A8 masks."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
WIDTH, HEIGHT, STRIDE = 192, 96, 400


def fnv(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def wrapped_positions(text):
    positions = {}
    stats = {'clusters': 0, 'lines': 0, 'wrapped_runs': 0, 'transitions': 0}
    vertical = text['id'] == 8
    for run in (0, 1):
        indexed = [(i, g) for i, g in enumerate(text['glyphs']) if g['run'] == run]
        if not indexed:
            continue
        groups = []
        for item in indexed:
            if not groups or groups[-1][0][1]['cluster'] != item[1]['cluster']:
                groups.append([])
            groups[-1].append(item)
        limit = (64 if vertical and run == 0 else 96) * 64
        capacity = (3 if vertical else 2) if run == 0 else 1
        rows = [[]]
        used = 0
        for group in groups:
            amount = sum(-g['y_advance'] if vertical else g['x_advance'] for _, g in group)
            if amount < 0 or amount > limit:
                raise ValueError('unbreakable span exceeds inline limit')
            if used + amount > limit:
                rows.append([])
                used = 0
            if len(rows) > capacity:
                raise ValueError('block full')
            rows[-1].append(group)
            used += amount
        step = (40 if vertical else 32 if run == 0 else 16) * 64
        for line, row in enumerate(rows):
            inline = 0
            for group in row:
                px, py = (-line * step, -inline) if vertical else (inline, -line * step)
                for i, g in group:
                    ox = (150 if run == 0 else 178) if vertical else 8
                    oy = 8 if vertical else 18 if run else 32 if text['id'] == 9 else 48
                    positions[i] = (ox + (px + g['x_offset']) // 64 + g['left'], oy - (py + g['y_offset']) // 64 - g['top'])
                    px += g['x_advance'];py += g['y_advance']
                inline += sum(-g['y_advance'] if vertical else g['x_advance'] for _, g in group)
        stats['clusters'] += len(groups)
        stats['lines'] += len(rows)
        stats['wrapped_runs'] += int(len(rows) > 1)
        stats['transitions'] += len(rows) - 1
    return positions, stats


def compose(text, pixels, wrapped=False):
    result = bytearray([0xa5]) * (HEIGHT * STRIDE)
    for row in range(HEIGHT):
        result[row * STRIDE:row * STRIDE + WIDTH * 2] = struct.pack('<H', 0xf79e) * WIDTH
    pens = [[0, 0], [0, 0]]
    clipped = 0
    placements = wrapped_positions(text)[0] if wrapped else {}
    for index, glyph in enumerate(text['glyphs']):
        run = glyph['run']
        if text['id'] == 8:
            origin = (150 if run == 0 else 178, 8)
        else:
            origin = (-8 if text['id'] == 9 else 8, 18 if run else 80 if text['id'] == 9 else 48)
        x = origin[0] + (pens[run][0] + glyph['x_offset']) // 64 + glyph['left']
        y = origin[1] - (pens[run][1] + glyph['y_offset']) // 64 - glyph['top']
        if wrapped:
            x, y = placements[index]
        pens[run][0] += glyph['x_advance']
        pens[run][1] += glyph['y_advance']
        clipped += int(x < 0 or y < 0 or x + glyph['width'] > WIDTH or y + glyph['height'] > HEIGHT)
        ink = 0x192b if run == 0 else 0xb9a7
        # Unlike the clipped-span native implementation, visit every source
        # pixel and reject each out-of-viewport destination independently.
        for sy in range(glyph['height']):
            for sx in range(glyph['width']):
                dx, dy = x + sx, y + sy
                if not (0 <= dx < WIDTH and 0 <= dy < HEIGHT):
                    continue
                a = pixels[glyph['pixel_offset'] + sy * glyph['width'] + sx]
                offset = dy * STRIDE + dx * 2
                background = int.from_bytes(result[offset:offset + 2], 'little')
                color = 0
                for shift, mask in ((11, 31), (5, 63), (0, 31)):
                    component = (((ink >> shift) & mask) * a + ((background >> shift) & mask) * (255 - a) + 127) // 255
                    color |= component << shift
                result[offset:offset + 2] = color.to_bytes(2, 'little')
    return result, clipped


def png(data):
    rows = []
    for y in range(HEIGHT):
        row = bytearray([0])
        for x in range(WIDTH):
            value = int.from_bytes(data[y * STRIDE + x * 2:y * STRIDE + x * 2 + 2], 'little')
            r, g, b = value >> 11, (value >> 5) & 63, value & 31
            row.extend(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))
        rows.append(row)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


if __name__ == '__main__':
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    reference = ROOT / 'docs/measurements/2026-10-28-font-raster-host.json'
    source = json.loads(reference.read_text())
    frames, inputs, wraps = [], {}, []
    for text in source['texts']:
        if text['outcome']:
            continue
        path = ROOT / f'build/graphics-raster-host/raster-{text["id"]}.bin'
        pixels = path.read_bytes()
        assert len(pixels) == text['pixel_bytes'] and fnv(pixels) == text['pixel_hash']
        inputs[str(path.relative_to(ROOT))] = hashlib.sha256(pixels).hexdigest()
        data, clipped = compose(text, pixels)
        (output / f'surface-{text["id"]}.rgb565').write_bytes(data)
        (output / f'surface-{text["id"]}.png').write_bytes(png(data))
        frames.append({'id': text['id'], 'surface_hash': fnv(data), 'clipped': clipped, 'blits': text['glyph_count']})
        wrapped, wrap_clip = compose(text, pixels, wrapped=True)
        (output / f'wrapped-{text["id"]}.rgb565').write_bytes(wrapped)
        (output / f'wrapped-{text["id"]}.png').write_bytes(png(wrapped))
        _, stats = wrapped_positions(text)
        wraps.append({'id': text['id'], 'wrap_hash': fnv(wrapped), 'clipped': wrap_clip, **stats})
    result = {'schema': 1, 'status': 'pass', 'evidence': 'independent Python software reference, no native display',
              'width': WIDTH, 'height': HEIGHT, 'stride': STRIDE, 'frames': frames, 'wrapped': wraps,
              'raster_reference_sha256': hashlib.sha256(reference.read_bytes()).hexdigest(),
              'input_sha256': inputs, 'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (output / 'reference.json').write_text(json.dumps(result, indent=2) + '\n')
    print(frames)

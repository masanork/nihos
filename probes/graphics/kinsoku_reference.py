#!/usr/bin/env python3
"""Independent batch basic-prohibition layout using pinned host glyph masks.

This is a finite software reference, not native display or JLREQ conformance.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('surface_reference', Path(__file__).with_name('surface_reference.py'))
PIXELS = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PIXELS)
OPEN = set('([{‘“〈《「『【〔〖〘〚（［｛｢')
CLOSE = set(')]},.:;!?·’”、。々〉》」』】〕〗〙〛〻ぁぃぅぇぉっゃゅょゎゕゖ゛゜ゝゞァィゥェォッャュョヮヵヶ・ーヽヾ！），．：；？］｝｡｣､･')
CLOSE.update(map(chr, range(0x31f0, 0x3200)))
CLOSE.update(map(chr, range(0xff67, 0xff71)))


def boundaries(source):
    result = {}
    previous = None
    offset = 0
    for char in source:
        if char in '\r\n':
            raise ValueError('split hard breaks before layout')
        result[offset] = previous is None or (previous not in OPEN and char not in CLOSE)
        previous = char
        offset += len(char.encode())
    result[offset] = True
    return result


def plan(text, sources, prohibit=True):
    placements = {}
    stats = dict(spans=0, joined=0, lines=0, transitions=0, forbidden_starts=0, forbidden_ends=0)
    vertical = text['id'] == 8
    for run in (0, 1):
        indexed = [(i, g) for i, g in enumerate(text['glyphs']) if g['run'] == run]
        if not indexed:
            continue
        source = sources[run]
        allowed = boundaries(source)
        characters = {}
        offset = 0
        for cp in source:
            characters[offset] = cp
            offset += len(cp.encode())
        clusters = []
        for item in indexed:
            if item[1]['cluster'] not in characters:
                raise ValueError('glyph cluster is not a source scalar boundary')
            if not clusters or clusters[-1][0][1]['cluster'] != item[1]['cluster']:
                clusters.append([])
            clusters[-1].append(item)
        # Batch connected components of forbidden boundaries, independently of
        # the native adapter's forward scan from an individual span start.
        components = [[]]
        for group in clusters:
            if components[-1] and (not prohibit or allowed[group[0][1]['cluster']]):
                components.append([])
            components[-1].extend(group)
        limit = (64 if vertical and run == 0 else 80 if text['id'] == 9 and run == 0 else 96) * 64
        capacity = (4 if vertical else 3) if run == 0 else 1
        step = (40 if vertical else 32 if run == 0 else 16) * 64
        used, row = (32 * 64 if vertical and run == 0 else 0), 0
        rows = [[]]
        for group in components:
            amount = sum(-g['y_advance'] if vertical else g['x_advance'] for _, g in group)
            if amount < 0 or amount > limit:
                raise ValueError('span exceeds line')
            if used + amount > limit:
                row += 1
                used = 0
                rows.append([])
            if row >= capacity:
                raise ValueError('block full')
            px, py = (-row * step, -used) if vertical else (used, -row * step)
            rows[-1].extend(group)
            for i, g in group:
                ox = (150 if run == 0 else 178) if vertical else 8
                oy = 8 if vertical else 18 if run else 32 if text['id'] == 9 else 48
                placements[i] = (ox + (px + g['x_offset']) // 64 + g['left'], oy - (py + g['y_offset']) // 64 - g['top'])
                px += g['x_advance']
                py += g['y_advance']
            used += amount
        for row_items in rows:
            if not row_items:
                continue
            first_offset = row_items[0][1]['cluster']
            last_offset = row_items[-1][1]['cluster']
            last_end = next((g[0][1]['cluster'] for g in clusters if g[0][1]['cluster'] > last_offset), len(source.encode()))
            last_char = source.encode()[last_offset:last_end].decode()[-1]
            stats['forbidden_starts'] += int(characters[first_offset] in CLOSE and first_offset != 0)
            stats['forbidden_ends'] += int(last_char in OPEN and last_end < len(source.encode()))
        stats['spans'] += len(components)
        stats['joined'] += len(clusters) - len(components)
        stats['lines'] += len(rows)
        stats['transitions'] += len(rows) - 1
    return placements, stats


def compose(text, masks, positions):
    output = bytearray([0xa5]) * (PIXELS.HEIGHT * PIXELS.STRIDE)
    for y in range(PIXELS.HEIGHT):
        for x in range(PIXELS.WIDTH):
            output[y * PIXELS.STRIDE + 2 * x:y * PIXELS.STRIDE + 2 * x + 2] = (0xf79e).to_bytes(2, 'little')
    clipped = 0
    for i, glyph in enumerate(text['glyphs']):
        x, y = positions[i]
        clipped += int(x < 0 or y < 0 or x + glyph['width'] > PIXELS.WIDTH or y + glyph['height'] > PIXELS.HEIGHT)
        ink = 0x192b if glyph['run'] == 0 else 0xb9a7
        for sy in range(glyph['height']):
            for sx in range(glyph['width']):
                dx, dy = x + sx, y + sy
                if not (0 <= dx < PIXELS.WIDTH and 0 <= dy < PIXELS.HEIGHT):
                    continue
                alpha = masks[glyph['pixel_offset'] + sy * glyph['width'] + sx]
                offset = dy * PIXELS.STRIDE + dx * 2
                background = int.from_bytes(output[offset:offset + 2], 'little')
                channels = [((((ink >> shift) & mask) * alpha + ((background >> shift) & mask) * (255 - alpha) + 127) // 255) << shift for shift, mask in ((11, 31), (5, 63), (0, 31))]
                output[offset:offset + 2] = sum(channels).to_bytes(2, 'little')
    return output, clipped


def main():
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    raster_path = ROOT / 'docs/measurements/2026-10-28-font-raster-host.json'
    cases_path = ROOT / 'probes/graphics/text_cases.json'
    cases = json.loads(cases_path.read_text())
    raster = json.loads(raster_path.read_text())
    frames, inputs = [], {}
    for text in raster['texts']:
        if text['outcome']:
            continue
        case = cases[text['id'] - 5]
        source = case['body'], case['ruby']
        positions, stats = plan(text, source)
        naive_positions, naive_stats = plan(text, source, prohibit=False)
        path = ROOT / f'build/graphics-raster-host/raster-{text["id"]}.bin'
        masks = path.read_bytes()
        assert PIXELS.fnv(masks) == text['pixel_hash'] and len(masks) == text['pixel_bytes']
        image, clipped = compose(text, masks, positions)
        naive, _ = compose(text, masks, naive_positions)
        for kind, content in [('kinsoku', image), ('naive', naive)]:
            (directory / f'{kind}-{text["id"]}.rgb565').write_bytes(content)
            (directory / f'{kind}-{text["id"]}.png').write_bytes(PIXELS.png(content))
        assert stats['forbidden_starts'] == stats['forbidden_ends'] == 0
        frames.append(dict(id=text['id'], policy_hash=PIXELS.fnv(image), clipped=clipped, **stats,
                           naive_hash=PIXELS.fnv(naive), naive_forbidden_starts=naive_stats['forbidden_starts'], naive_forbidden_ends=naive_stats['forbidden_ends']))
        inputs[str(path.relative_to(ROOT))] = hashlib.sha256(masks).hexdigest()
    result = dict(schema=1, status='pass', evidence='independent batch Python reference; no native display', frames=frames,
                  raster_reference_sha256=hashlib.sha256(raster_path.read_bytes()).hexdigest(), cases_sha256=hashlib.sha256(cases_path.read_bytes()).hexdigest(),
                  source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), input_sha256=inputs,
                  profile='basic explicit character prohibitions; no UAX14/JIS/JLREQ conformance claim')
    (directory / 'reference.json').write_text(json.dumps(result, indent=2) + '\n')
    print(frames)


if __name__ == '__main__':
    main()

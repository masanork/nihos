#!/usr/bin/env python3
"""Independent batch group-ruby planner and pinned-mask image reference."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('kinsoku_reference', Path(__file__).with_name('kinsoku_reference.py'))
KIN = importlib.util.module_from_spec(spec)
spec.loader.exec_module(KIN)


def plan(text, sources, annotations, limit, step, capacity, prefix, cross):
    vertical = text['id'] == 8
    clusters, runs = [], []
    for run, source in enumerate(sources):
        indexed = [(i, g) for i, g in enumerate(text['glyphs']) if g['run'] == run]
        offsets = KIN.boundaries(source)
        groups = []
        for item in indexed:
            if item[1]['cluster'] not in offsets or item[1]['cluster'] == len(source.encode()):
                raise ValueError('invalid source cluster')
            if not groups or groups[-1][0][1]['cluster'] != item[1]['cluster']:
                groups.append([])
            groups[-1].append(item)
        runs.append(indexed)
        clusters.append(groups)
    body, ruby = clusters
    boundaries = KIN.boundaries(sources[0])
    previous_base, previous_ruby = 0, 0
    ranges = {}
    for annotation in annotations:
        bs, be, rs, re = [annotation[k] for k in ('base_start', 'base_end', 'ruby_start', 'ruby_end')]
        if not previous_base <= bs < be <= len(sources[0].encode()) or not previous_ruby == rs < re <= len(sources[1].encode()):
            raise ValueError('invalid or overlapping annotation range')
        for start, end, source, groups in ((bs, be, sources[0], body), (rs, re, sources[1], ruby)):
            heads = [group[0][1]['cluster'] for group in groups] + [len(source.encode())]
            if start not in heads or end not in heads:
                raise ValueError('annotation splits a shaping cluster')
        ranges[bs] = (be, [item for group in ruby if rs <= group[0][1]['cluster'] < re for item in group])
        previous_base, previous_ruby = be, re
    if previous_ruby != len(sources[1].encode()):
        raise ValueError('uncovered ruby')
    # Replace annotated body intervals, then form batch connected components of
    # forbidden boundaries. Native builds a bounded unit array and scans it.
    units = []
    covered_until = 0
    for group in body:
        offset = group[0][1]['cluster']
        if offset < covered_until:
            continue
        ruby_items = []
        if offset in ranges:
            covered_until, ruby_items = ranges[offset]
            base_items = [item for other in body if offset <= other[0][1]['cluster'] < covered_until for item in other]
        else:
            base_items = group
        advance = lambda items: sum(-g['y_advance'] if vertical else g['x_advance'] for _, g in items)
        base_width, ruby_width = advance(base_items), advance(ruby_items)
        if min(base_width, ruby_width) < 0:
            raise ValueError('unsupported advance')
        units.append(dict(base=base_items, ruby=ruby_items, width=max(base_width, ruby_width), bw=base_width, rw=ruby_width, offset=offset))
    components = [[]]
    for unit in units:
        if components[-1] and boundaries[unit['offset']]:
            components.append([])
        components[-1].append(unit)
    placements, logical = {}, {}
    stats = dict(groups=len(annotations), moved=0, wide=0, units=len(units), joins=len(units) - len(components), lines=0)
    row, inline = 0, prefix
    for component in components:
        width = sum(unit['width'] for unit in component)
        if width > limit:
            raise ValueError('unbreakable ruby span exceeds line')
        if inline + width > limit:
            row += 1
            inline = 0
        if row >= capacity:
            raise ValueError('block full')
        for unit in component:
            for kind, items, amount in (('base', unit['base'], unit['bw']), ('ruby', unit['ruby'], unit['rw'])):
                pen = inline + (unit['width'] - amount) // 2
                block = row * step - (cross if kind == 'ruby' else 0)
                for i, g in items:
                    logical[i] = (pen, block)
                    px, py = (-block, -pen) if vertical else (pen, -block)
                    ox, oy = (150, 8) if vertical else (8, 32 if text['id'] == 9 else 10)
                    placements[i] = (ox + (px + g['x_offset']) // 64 + g['left'], oy - (py + g['y_offset']) // 64 - g['top'])
                    pen += -g['y_advance'] if vertical else g['x_advance']
            if unit['ruby']:
                stats['moved'] += int(row > 0)
                stats['wide'] += int(unit['rw'] > unit['bw'])
            inline += unit['width']
    stats['lines'] = row + 1
    return placements, logical, stats


def main():
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    source_path = ROOT / 'probes/graphics/text_cases.json'
    annotation_path = ROOT / 'probes/graphics/ruby_cases.json'
    raster_path = ROOT / 'docs/measurements/2026-10-28-font-raster-host.json'
    cases = json.loads(source_path.read_text())
    annotations = json.loads(annotation_path.read_text())
    frames, inputs = [], {}
    for text in json.loads(raster_path.read_text())['texts']:
        if text['outcome']:
            continue
        vertical = text['id'] == 8
        case = cases[text['id'] - 5]
        limit = 96 if vertical or text['id'] != 9 else 80
        positions, logical, stats = plan(text, (case['body'], case['ruby']), annotations[text['id'] - 5], limit * 64, (40 if vertical else 32) * 64, 4 if vertical else 3, (32 if vertical else 48 if text['id'] != 9 else 0) * 64, 26 * 64)
        path = ROOT / f'build/graphics-raster-host/raster-{text["id"]}.bin'
        masks = path.read_bytes()
        assert KIN.PIXELS.fnv(masks) == text['pixel_hash'] and len(masks) == text['pixel_bytes']
        image, clipped = KIN.compose(text, masks, positions)
        control_positions = dict(positions)
        px, py = 0, 0
        for i, g in enumerate(text['glyphs']):
            if g['run'] != 1:
                continue
            ox, oy = (178, 8) if vertical else (8, 18)
            control_positions[i] = (ox + (px + g['x_offset']) // 64 + g['left'], oy - (py + g['y_offset']) // 64 - g['top'])
            px += g['x_advance']
            py += g['y_advance']
        control, _ = KIN.compose(text, masks, control_positions)
        for kind, content in (('ruby', image), ('fixed', control)):
            (directory / f'{kind}-{text["id"]}.rgb565').write_bytes(content)
            (directory / f'{kind}-{text["id"]}.png').write_bytes(KIN.PIXELS.png(content))
        frames.append(dict(id=text['id'], ruby_hash=KIN.PIXELS.fnv(image), control_hash=KIN.PIXELS.fnv(control), clipped=clipped, **stats,
                           logical=[dict(index=i, inline_offset=p[0], block_offset=p[1]) for i, p in sorted(logical.items())]))
        inputs[str(path.relative_to(ROOT))] = hashlib.sha256(masks).hexdigest()
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = dict(schema=1, status='pass', evidence='independent batch host reference; no native display', frames=frames,
                  source_sha256=sha(Path(__file__)), cases_sha256=sha(source_path), annotations_sha256=sha(annotation_path), raster_reference_sha256=sha(raster_path),
                  composition_source_sha256=sha(Path(KIN.__file__)), input_sha256=inputs,
                  limits=['centered reserved-width group ruby only; no overhang/distribution or full JLREQ/JIS claim'])
    (directory / 'reference.json').write_text(json.dumps(result, indent=2) + '\n')
    print([{k: v for k, v in f.items() if k != 'logical'} for f in frames])


if __name__ == '__main__':
    main()

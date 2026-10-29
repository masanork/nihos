#!/usr/bin/env python3
"""Replay pinned shaped A8 glyph captures; host compositing timing only."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import statistics
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('surface_reference', ROOT / 'probes/graphics/surface_reference.py')
REFERENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REFERENCE)


class Glyph(ctypes.Structure):
    _fields_ = [('offset', ctypes.c_uint32), ('width', ctypes.c_uint32), ('height', ctypes.c_uint32),
                ('x', ctypes.c_int32), ('y', ctypes.c_int32), ('color', ctypes.c_uint16)]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--host-dir', type=Path, required=True, help='directory with pinned result.json and raster-N.bin')
    args = parser.parse_args()
    if os.path.samefile(args.baseline, args.candidate):
        parser.error('baseline and candidate libraries must be distinct files')
    reference = json.loads((ROOT / 'docs/measurements/2026-10-28-runtime-text-reference.json').read_text())
    result_bytes = (args.host_dir / 'result.json').read_bytes()
    if sha(result_bytes) != reference['host_result_sha256']:
        parser.error('host shaping result differs from pinned reference')
    host = json.loads(result_bytes)
    libs = [ctypes.CDLL(str(path.resolve())) for path in (args.baseline, args.candidate)]
    funcs = [lib.render for lib in libs]
    for func in funcs:
        func.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(Glyph), ctypes.c_size_t, ctypes.c_uint32]
        func.restype = ctypes.c_bool
    results = {}
    for text in host['texts']:
        if text['outcome']:
            continue
        ident = text['id']
        pixels = (args.host_dir / f'raster-{ident}.bin').read_bytes()
        if sha(pixels) != reference['input_rasters_sha256'][f'build/runtime-text-host/raster-{ident}.bin']:
            parser.error(f'raster-{ident} differs from pinned reference')
        if len(pixels) != text['pixel_bytes'] or REFERENCE.fnv(pixels) != text['pixel_hash']:
            parser.error(f'raster-{ident} metadata mismatch')
        positions, pens = [], [[0, 0], [0, 0]]
        for g in text['glyphs']:
            run = g['run']
            if ident == 8:
                origin = (150 if run == 0 else 178, 8)
            else:
                origin = (-8 if ident == 9 else 8, 18 if run else 80 if ident == 9 else 48)
            x = origin[0] + (pens[run][0] + g['x_offset']) // 64 + g['left']
            y = origin[1] - (pens[run][1] + g['y_offset']) // 64 - g['top']
            pens[run][0] += g['x_advance']
            pens[run][1] += g['y_advance']
            positions.append(Glyph(g['pixel_offset'], g['width'], g['height'], x, y, 0x192b if run == 0 else 0xb9a7))
        glyphs = (Glyph * len(positions))(*positions)
        source = (ctypes.c_uint8 * len(pixels)).from_buffer_copy(pixels)
        expected, clipped = REFERENCE.compose(text, pixels)
        sample = [[], []]
        for trial in range(20):
            for index in ((0, 1) if trial % 2 == 0 else (1, 0)):
                frame = (ctypes.c_uint8 * len(expected))()
                start = time.perf_counter_ns()
                if not funcs[index](frame, source, len(pixels), glyphs, len(glyphs), 100):
                    raise RuntimeError('glyph rendering failed')
                sample[index].append((time.perf_counter_ns() - start) / 100_000_000)
                if bytes(frame) != expected:
                    raise RuntimeError(f'case {ident}: frame differs from independent reference')
        results[str(ident)] = {'glyphs': len(glyphs), 'clipped_glyphs': clipped, 'source_sha256': sha(pixels),
                               'frame_sha256': sha(expected), 'baseline_ms': sample[0], 'candidate_ms': sample[1],
                               'baseline_median_ms': statistics.median(sample[0]), 'candidate_median_ms': statistics.median(sample[1])}
    print(json.dumps({'scope': 'host-only captured shaped glyph composition; not shaping or device timing',
                      'platform': platform.platform(), 'pairs': 20, 'iterations_per_pair': 100,
                      'shaping_result_sha256': sha(result_bytes),
                      'libraries_sha256': [sha(path.read_bytes()) for path in (args.baseline, args.candidate)],
                      'results': results}, indent=2))


if __name__ == '__main__':
    main()

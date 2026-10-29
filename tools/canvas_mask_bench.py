#!/usr/bin/env python3
"""Paired host-only A8 mask measurement, not a Tab5 timing estimate."""
import ctypes
import hashlib
import json
import os
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: canvas_mask_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
if os.path.samefile(sys.argv[1], sys.argv[2]):
    raise SystemExit('baseline and candidate libraries must be distinct files')
libs = [ctypes.CDLL(path) for path in sys.argv[1:]]
funcs = [lib.render for lib in libs]
for func in funcs:
    func.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
    func.restype = ctypes.c_uint32
results = {}
for mode in ('transparent', 'opaque', 'mixed'):
    samples = [[], []]
    digests = []
    mask = (ctypes.c_uint8 * 256)(*(0 if mode == 'transparent' else 255 if mode == 'opaque'
                                    else (0, 0, 0, 32, 128, 192, 255, 255)[(i * 13 + i // 16) % 8]
                                    for i in range(256)))
    for trial in range(12):
        pair = [None, None]
        for index in ([0, 1] if trial % 2 == 0 else [1, 0]):
            out = (ctypes.c_uint8 * (320 * 200 * 2))()
            start = time.perf_counter()
            if funcs[index](out, mask, 5) != 1:
                raise RuntimeError('benchmark failed')
            samples[index].append((time.perf_counter() - start) * 1000 / 5)
            pair[index] = hashlib.sha256(out).hexdigest()
        if pair[0] != pair[1]:
            raise RuntimeError('output mismatch')
        digests.append(pair[0])
    if len(set(digests)) != 1:
        raise RuntimeError('nondeterministic output')
    results[mode] = {'sha256': digests[0], 'baseline_ms': samples[0], 'candidate_ms': samples[1],
                     'baseline_median_ms': statistics.median(samples[0]), 'candidate_median_ms': statistics.median(samples[1])}
print(json.dumps({'evidence': 'host-only', 'iterations_per_sample': 5, 'glyphs_per_iteration': 240,
                  'pairs': 12, 'results': results}, indent=2))

#!/usr/bin/env python3
"""Host-only indexed scale benchmark; not Tab5 or Quake performance."""
import ctypes
import hashlib
import json
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: canvas_indexed_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
size = 320 * 200 * 2
source = (ctypes.c_uint8 * (200 * 125))(*(i * 37 % 256 for i in range(200 * 125)))
palette = (ctypes.c_uint16 * 256)(*((i * 257) ^ 0x5a5a for i in range(256)))
libs = [ctypes.CDLL(path) for path in sys.argv[1:]]
funcs = [lib.render for lib in libs]
for f in funcs:
    f.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]
    f.restype = ctypes.c_uint32
results = {}
for mode, name in enumerate(('2x', '2x_clipped', 'non_2x')):
    samples = [[], []]
    digests = []
    for trial in range(8):
        pair = [None, None]
        for index in ([0, 1] if trial % 2 == 0 else [1, 0]):
            out = (ctypes.c_uint8 * size)()
            start = time.perf_counter()
            if funcs[index](out, source, palette, 20, mode) != 1:
                raise RuntimeError('benchmark failed')
            samples[index].append((time.perf_counter() - start) * 1000 / 20)
            pair[index] = hashlib.sha256(out).hexdigest()
        if pair[0] != pair[1]: raise RuntimeError('output mismatch')
        digests.append(pair[0])
    if len(set(digests)) != 1: raise RuntimeError('nondeterministic output')
    results[name] = {'sha256': digests[0], 'baseline_ms': samples[0], 'candidate_ms': samples[1],
                     'baseline_median_ms': statistics.median(samples[0]), 'candidate_median_ms': statistics.median(samples[1])}
print(json.dumps({'evidence': 'host-only', 'iterations_per_sample': 20, 'pairs': 8, 'results': results}, indent=2))

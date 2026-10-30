#!/usr/bin/env python3
"""Compare two host-only copyRect implementations, not Tab5 timing."""
import ctypes
import hashlib
import json
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: canvas_scroll_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
size = 720 * 480 * 2
initial = bytes(((i * 37) ^ (i >> 7)) & 255 for i in range(size))
libs = [ctypes.CDLL(path) for path in sys.argv[1:]]
funcs = [lib.render for lib in libs]
for f in funcs:
    f.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]
    f.restype = ctypes.c_uint32
result = {}
for mode, name in enumerate(('up', 'down', 'right')):
    samples = [[], []]
    hashes = []
    for trial in range(8):
        trial_hashes = [None, None]
        for index in ([0, 1] if trial % 2 == 0 else [1, 0]):
            buf = (ctypes.c_uint8 * size).from_buffer_copy(initial)
            start = time.perf_counter()
            if funcs[index](buf, 40, mode) != 1:
                raise RuntimeError('benchmark failed')
            samples[index].append((time.perf_counter() - start) * 1000 / 40)
            trial_hashes[index] = hashlib.sha256(buf).hexdigest()
        if trial_hashes[0] != trial_hashes[1]:
            raise RuntimeError('baseline/candidate output mismatch')
        hashes.append(trial_hashes[0])
    if len(set(hashes)) != 1:
        raise RuntimeError('inconsistent output')
    result[name] = {'sha256': hashes[0], 'baseline_ms': samples[0], 'candidate_ms': samples[1],
                    'baseline_median_ms': statistics.median(samples[0]), 'candidate_median_ms': statistics.median(samples[1])}
print(json.dumps({'evidence': 'host-only', 'width': 720, 'height': 480, 'iterations_per_sample': 40,
                  'pairs': 8, 'results': result}, indent=2))

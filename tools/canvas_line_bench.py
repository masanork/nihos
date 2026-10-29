#!/usr/bin/env python3
"""Compare complete frames and paired host timings, not Tab5 performance."""
import ctypes
import hashlib
import json
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: canvas_line_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
libs = [ctypes.CDLL(path) for path in sys.argv[1:]]
funcs = [lib.render for lib in libs]
for func in funcs:
    func.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]
    func.restype = ctypes.c_uint32
results = {}
for mode, name in enumerate(('horizontal', 'vertical', 'diagonal')):
    samples = [[], []]
    digests = []
    for trial in range(12):
        pair = [None, None]
        for index in ([0, 1] if trial % 2 == 0 else [1, 0]):
            out = (ctypes.c_uint8 * (320 * 200 * 2))()
            start = time.perf_counter()
            if funcs[index](out, 10, mode) != 1:
                raise RuntimeError('benchmark failed')
            samples[index].append((time.perf_counter() - start) * 1000 / 10)
            pair[index] = hashlib.sha256(out).hexdigest()
        if pair[0] != pair[1]:
            raise RuntimeError('output mismatch')
        digests.append(pair[0])
    if len(set(digests)) != 1:
        raise RuntimeError('nondeterministic output')
    results[name] = {'sha256': digests[0], 'baseline_ms': samples[0], 'candidate_ms': samples[1],
                     'baseline_median_ms': statistics.median(samples[0]), 'candidate_median_ms': statistics.median(samples[1])}
print(json.dumps({'evidence': 'host-only', 'iterations_per_sample': 10, 'lines_per_iteration': 100,
                  'pairs': 12, 'results': results}, indent=2))

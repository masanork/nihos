#!/usr/bin/env python3
"""Paired host console measurements; not physical Tab5 timing."""
import ctypes
import hashlib
import json
from pathlib import Path
import platform
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: console_render_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
paths = [Path(arg).resolve() for arg in sys.argv[1:]]
libraries = [ctypes.CDLL(str(path)) for path in paths]
for library in libraries:
    library.setup.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    library.setup.restype = ctypes.c_bool
    library.render.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
    library.render.restype = ctypes.c_bool
size = 720 * 1280 * 2
result = {}
for mode, name in enumerate(('full', 'incremental', 'scroll')):
    times = [[], []]
    hashes = []
    for trial in range(30):
        buffers = [ctypes.create_string_buffer(size) for _ in libraries]
        for lib, buf in zip(libraries, buffers):
            if not lib.setup(buf, size):
                raise RuntimeError('setup failed')
        for i in ((0, 1) if trial % 2 == 0 else (1, 0)):
            start = time.perf_counter_ns()
            if not libraries[i].render(buffers[i], size, mode):
                raise RuntimeError('render failed')
            times[i].append((time.perf_counter_ns() - start) / 1e6)
        if buffers[0].raw != buffers[1].raw:
            raise RuntimeError('frame mismatch')
        hashes.append(hashlib.sha256(buffers[0].raw).hexdigest())
    if len(set(hashes)) != 1:
        raise RuntimeError('frame differs between trials')
    result[name] = {'rgb565_sha256': hashes[0], 'baseline_ms': times[0], 'candidate_ms': times[1],
                    'baseline_median_ms': statistics.median(times[0]), 'candidate_median_ms': statistics.median(times[1])}
print(json.dumps({'scope': 'host only; not Tab5, PSRAM, DMA or panel timing', 'platform': platform.platform(),
                  'compiler': 'Zig 0.17.0 ReleaseSafe for all modules', 'alternating_pairs': 30,
                  'libraries_sha256': [hashlib.sha256(path.read_bytes()).hexdigest() for path in paths],
                  'results': result}, indent=2))

#!/usr/bin/env python3
"""Host-only paired splash benchmark; this is not a Tab5 timing probe."""
import ctypes
import hashlib
import json
import platform
from pathlib import Path
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: splash_fill_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
paths = [Path(p).resolve() for p in sys.argv[1:]]
libraries = [ctypes.CDLL(str(path)) for path in paths]
functions = [lib.nih_boot_preview for lib in libraries]
for func in functions:
    func.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ubyte, ctypes.c_ubyte, ctypes.c_bool]
    func.restype = ctypes.c_bool
size = 720 * 1280 * 2
samples = {}
for landscape in (False, True):
    name = 'landscape' if landscape else 'portrait'
    buffers = [ctypes.create_string_buffer(size) for _ in functions]
    times = [[], []]
    for trial in range(40):
        for index in ((0, 1) if trial % 2 == 0 else (1, 0)):
            start = time.perf_counter_ns()
            if not functions[index](buffers[index], size, 128, 5, landscape):
                raise RuntimeError('splash render failed')
            times[index].append((time.perf_counter_ns() - start) / 1e6)
        if buffers[0].raw != buffers[1].raw:
            raise RuntimeError('splash frame mismatch')
    samples[name] = {'rgb565_sha256': hashlib.sha256(buffers[0].raw).hexdigest(),
                     'baseline_ms': times[0], 'candidate_ms': times[1],
                     'baseline_median_ms': statistics.median(times[0]), 'candidate_median_ms': statistics.median(times[1])}
print(json.dumps({'scope': 'host only; not Tab5, PSRAM, DMA or panel timing',
                  'platform': platform.platform(), 'machine': platform.machine(), 'compiler': 'Zig 0.17.0 ReleaseSafe for all modules',
                  'iterations_per_sample': 1, 'alternating_pairs': 40,
                  'libraries_sha256': [hashlib.sha256(path.read_bytes()).hexdigest() for path in paths],
                  'results': samples}, indent=2))

#!/usr/bin/env python3
"""Compare two host-only canvas benchmark libraries; not a Tab5 benchmark."""
import ctypes
import hashlib
import statistics
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: canvas_blit_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY')
n = 720 * 480 * 2
source = (ctypes.c_uint8 * n)(*(i % 256 for i in range(n)))
libraries = [ctypes.CDLL(path) for path in sys.argv[1:]]
outputs = [(ctypes.c_uint8 * n)() for _ in libraries]
functions = [library.render for library in libraries]
for function, output in zip(functions, outputs):
    function.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_uint32
    assert function(output, source, 1) == 1
samples = [[], []]
for trial in range(10):
    for index in ([0, 1] if trial % 2 == 0 else [1, 0]):
        start = time.perf_counter()
        assert functions[index](outputs[index], source, 200) == 1
        samples[index].append((time.perf_counter() - start) * 1000 / 200)
hashes = [hashlib.sha256(bytes(output)).hexdigest() for output in outputs]
if hashes[0] != hashes[1]:
    raise SystemExit('output mismatch')
for name, sample, digest in zip(('baseline', 'candidate'), samples, hashes):
    print(f'{name}: median={statistics.median(sample):.4f} ms/frame '
          f'range={min(sample):.4f}..{max(sample):.4f} sha256={digest}')

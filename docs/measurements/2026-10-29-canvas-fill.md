# Canvas rectangle fill experiment

The candidate at `2acd03b` fills each clipped RGB565LE row as bytes for a repeated-byte color, as aligned 16-bit words on little-endian targets, or as explicit little-endian pixels for unaligned or big-endian rows. The caller's clip, row padding and buffer ownership are unchanged. The reference is `0d47033`. A seeded test compares 300 clipped rectangles with an independent pixel reference on an odd-stride surface with both pointer alignments and guard bytes. Big-endian PowerPC64 compilation exercises the fallback at compile time; it is not execution evidence.

On one macOS arm64 host, the full 720 × 1280 splash was rendered at animation value 128 with status ready, using Zig 0.17.0 ReleaseSafe for every module. Forty alternating baseline/candidate pairs compared complete output bytes after every pair. Median milliseconds per full frame were:

| Layout | Before | After |
| --- | ---: | ---: |
| Portrait | 0.6047 | 0.4033 |
| Landscape | 0.6018 | 0.3883 |

The raw [samples and library hashes](evidence/2026-10-29-canvas-fill/host.json) include ranges and platform. These results are host observations under one load, not Tab5 startup, PSRAM, DMA, cache or panel timing. An earlier exploratory comparison against the pre-Canvas painter suggested that the Canvas migration itself could regress full-frame time on this host; this experiment compares the two Canvas versions and does not establish that the entire migration is faster than the former renderer.

To reproduce, build the same `tools/boot-graphics/preview.zig` adapter against the baseline and candidate trees with `zig build-lib -dynamic`, specifying `-OReleaseSafe` separately for the root, boot graphics, Canvas and Surface modules; then run `python3 tools/splash_fill_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY`. The benchmark checks the rendered bytes before reporting.

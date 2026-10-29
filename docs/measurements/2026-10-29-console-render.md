# Canvas console host measurement

This paired host experiment compares the basic-light console before the glyph-row Canvas migration (`ce36f8b53110bb8f50baf0f08de74484d31df697`) with the Canvas implementation including row-fill optimization (`fb6fb9121f8569ba728df32cb85003620cd5406f`). Both use the same `tools/probes/console_render_bench.zig` adapter, a 720 × 1280 RGB565 framebuffer, the same grid content and Zig 0.17.0 ReleaseSafe for every module. Setup is outside the timed region. Each of 30 pairs alternates execution order and compares the entire resulting framebuffer.

| Operation | Before median | After median |
| --- | ---: | ---: |
| Full repaint | 1.460 ms | 1.346 ms |
| Incremental text update | 0.0073 ms | 0.0083 ms |
| One-line scroll | 0.249 ms | 0.256 ms |

The raw [samples, output hashes, platform and library hashes](evidence/2026-10-29-console-render/host.json) document the ranges. These are one host's cached-memory timings, not Tab5 timing. The small update is near the timer and call overhead and must not be treated as a device-performance conclusion. The test confirms identical frames only for this fixture; RV32 and physical results are separate.

To reproduce, build `tools/probes/console_render_bench.zig` as a dynamic library twice against the two source trees, specifying `-OReleaseSafe` separately for the root, `text_console`, `canvas` and `surface` modules. Then run `python3 tools/console_render_bench.py BASELINE_LIBRARY CANDIDATE_LIBRARY`. The adapter checks that a scroll actually occurred and the benchmark refuses mismatched frames.

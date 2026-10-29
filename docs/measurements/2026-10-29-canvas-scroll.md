# Canvas copyRect row-copy experiment

The candidate at source commit `29da2a41b78c3c171937cd492ba1a38385357bec` copies non-overlapping row spans in bulk, and uses directional copies for overlapping spans. Row order still follows vertical movement. A seeded test compares 250 clipped moves on 49 × 43 padded surfaces with an immutable per-pixel reference; existing randomized, overlap, clipping and extreme-coordinate tests also pass in Debug and ReleaseSafe.

On ESP-EMU 0.50.0, the 320 × 200 synthetic scroll and indexed-scale frames matched the independent per-pixel references and the previous RV32 workload frame hashes. [RV32 receipt](evidence/2026-10-29-canvas-scroll/rv32.json). This checks correctness on emulated RV32, not physical performance or live scanout.

A host-only benchmark used Darwin arm64, Zig 0.17.0 ReleaseFast for all three modules, 720 × 480 RGB565, 40 repeated moves per measurement and eight alternating pairs. Both implementations produced the same SHA-256 in each direction. Median milliseconds per move were:

| Direction | Original | Candidate |
|---|---:|---:|
| Up 16 pixels | 1.272 | 0.085 |
| Down 16 pixels | 1.151 | 0.088 |
| Right 16 pixels | 2.037 | 0.752 |

The host was heavily loaded and timings varied widely; raw [host samples](evidence/2026-10-29-canvas-scroll/host.json) show ranges. These are cached repeated memory copies, not Tab5 timings; no frame-rate or hardware speedup is claimed. The initial measurement with mixed module optimization modes was discarded. An earlier candidate using only directional byte copies regressed on downward scrolling and was replaced by the disjoint-row path.

To reproduce the host probe, export the old `src/graphics/canvas.zig` from commit `8a2b137` to a temporary file; compile `tools/probes/canvas_scroll_bench.zig` twice as dynamic libraries with the old/new `canvas` module and `surface` module, explicitly setting `-O ReleaseFast` on each module. Run `python3 tools/canvas_scroll_bench.py OLD_LIBRARY NEW_LIBRARY`. Run `sh tools/nihos-dev.sh canvas-workloads` for the independent RV32 pixel comparison. Physical PSRAM rendering and cache writeback remain unmeasured for this change.

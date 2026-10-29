# Aligned Canvas overlap copy experiment

The candidate `817265f` uses directional 32-bit copies for overlapping row spans when both addresses and the length are four-byte aligned. Other overlap uses the existing directional byte copies; disjoint spans still use `@memcpy`. The reference is `cb9aeae6170df98ef87db3a1802c9c33679d2e39`. Tests compare left and right moves for all four pointer alignments with an immutable snapshot, plus the existing seeded clipping, overlapping and padded-stride cases in Debug and ReleaseSafe.

On one macOS arm64 host with Zig 0.17.0 ReleaseSafe for all modules, 30 alternating pairs of the `console_render_bench.py` fixture compared each entire frame. The one-line scroll median changed from **0.2707 ms to 0.1445 ms**; full repaint medians were 1.3939 and 1.3679 ms, and incremental-update medians were 0.0094 and 0.0086 ms. [Raw samples and library hashes](evidence/2026-10-29-canvas-overlap/host.json) contain observed ranges. This is a cached host-memory observation, not Tab5 PSRAM, DMA, panel or physical timing.

Reproduce with `tools/probes/console_render_bench.zig` built against each source tree as described in [the console benchmark](2026-10-29-console-render.md), then run `tools/console_render_bench.py` with the two distinct libraries. Frame comparison and an actual scroll check are part of the command.

# RV32 offscreen Canvas workloads

The ESP-EMU 0.50.0 run at source commit `57f8c9e8426717f5cd0dd3c38afcf0fd70bb94ea` executed the synthetic 320 × 200 editor-like scroll and indexed-scale operations against the shared Canvas. GDB read 128,000 RGB565LE bytes after each workload; the full frames matched independent host per-pixel references. A deliberate bit change in each captured frame was rejected at byte 11111. The normal emulator CPU/PSRAM, owned heap and fixture checks also passed.

This tests correctness of two small synthetic workloads, not editor behavior, Quake execution, real panel pixels or P4 performance. No target timing is inferred from the emulator. The source and artifact hashes are in the [report](evidence/2026-10-29-canvas-workloads/workloads.json); visualizations are [scroll](evidence/2026-10-29-canvas-workloads/scroll.png) and [indexed](evidence/2026-10-29-canvas-workloads/indexed.png). Run `sh tools/nihos-dev.sh canvas-workloads` to reproduce.

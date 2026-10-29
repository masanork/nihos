# Canvas indexed 2× scaling experiment

Candidate source commit `1aaff57852395b1e86f69d63b8c19b97d01bf919` handles exact 2× indexed scaling using destination-relative half coordinates. It retains the existing image/palette alias checks and clipping and falls back to the existing general scaler for all other ratios and RGB images. The 2× test uses 500 seeded combinations of negative destination coordinates, clipping, padded source/destination strides and random palettes, checked against an independent destination-pixel reference. All Canvas tests passed in Debug and ReleaseSafe.

On ESP-EMU 0.50.0 the synthetic 160 × 100 indexed image expanded to 320 × 200 matched every byte of the independent reference and the previous workload hash; the scroll workload also remained identical. The [RV32 receipt](evidence/2026-10-29-canvas-indexed/rv32.json) identifies source and image bytes. The emulator is a correctness target, not a P4 timing model. For these two audited emulator fixture ELFs, `riscv32-esp-elf-size` showed text 85,506, data 1,360 and BSS 142,592 bytes for each; this does not establish the size impact for other builds.

A Darwin arm64 host benchmark used Zig 0.17.0 ReleaseFast for all modules, 20 frames per sample and eight alternating pairs; outputs matched byte-for-byte between versions. Median milliseconds per frame:

| Workload | Original | Candidate |
|---|---:|---:|
| 160 × 100 indexed, 2× | 0.0698 | 0.0404 |
| Same, clipped at negative origin | 0.0571 | 0.0328 |
| 200 × 125 indexed to 320 × 200, general path | 0.0853 | 0.0698 |

The host was shared and samples varied; see [all samples](evidence/2026-10-29-canvas-indexed/host.json). The non-2× result does not prove an improvement to the unchanged general algorithm. The fixed input and cached host buffers do not predict Tab5 PSRAM, cache writeback, display transfer or Quake frame rate. A previous experiment replacing general scaling divisions with incremental arithmetic was slower on host and is not adopted here.

To reproduce, export `src/graphics/canvas.zig` from baseline commit `0a86aad` and compile it and the candidate separately as dynamic libraries with `tools/probes/canvas_indexed_bench.zig` and `surface.zig`; set `-O ReleaseFast` on every module. Run `python3 tools/canvas_indexed_bench.py OLD_LIBRARY NEW_LIBRARY`. `sh tools/nihos-dev.sh canvas-workloads` validates the target-emulator pixels independently.

# Indexed 2× row reuse

The exact 2× indexed path now expands each source pixel once per horizontal pair and copies the preceding expanded row when it represents the same source row. Odd clip edges, one-pixel widths, unaligned targets and padded rows retain the original RGB565LE output. Other ratios keep the general path. The seeded independent-pixel test and a deterministic odd-edge and unaligned-row test check the output and untouched bytes.

On one Darwin arm64 host with Zig 0.17.0 ReleaseFast on all modules, eight alternating pairs of 20 frames compared the whole output. Median per frame: full 160 × 100 to 320 × 200, **0.02073 → 0.01122 ms**; clipped 2×, **0.01886 → 0.01002 ms**; unchanged non-2× path, **0.03615 → 0.03625 ms**. See [raw samples and hashes](evidence/2026-10-29-indexed-2x-row-reuse/host.json). Shared host timing varies; this is not a P4, PSRAM, scanout, or Quake frame-rate measurement.

The [RV32 emulator receipt](evidence/2026-10-29-indexed-2x-row-reuse/rv32.json) identifies candidate `a75477cc09ef52b4fa7777e22659009d458a7a40`: the scroll and indexed frames matched independent reference images, including the existing guard check. The emulator is a correctness target, not a device timing model.

To reproduce the host comparison, use the same adapter and surface for both libraries. The baseline is `ef0677c7669a65c275e7f5db6396db2fd99a4ef1` and the candidate is `a75477cc09ef52b4fa7777e22659009d458a7a40`. From a checkout containing those commits:

```sh
ZIG_BIN=$(sh tools/bootstrap-zig.sh)
mkdir -p /tmp/nihos-indexed-2x
git show ef0677c:src/graphics/canvas.zig > /tmp/nihos-indexed-2x/baseline.zig
git show a75477c:src/graphics/canvas.zig > /tmp/nihos-indexed-2x/candidate.zig
for version in baseline candidate; do
  "$ZIG_BIN" build-lib -dynamic -O ReleaseFast --dep canvas -Mroot=tools/probes/canvas_indexed_bench.zig -O ReleaseFast --dep surface -Mcanvas="/tmp/nihos-indexed-2x/$version.zig" -O ReleaseFast -Msurface=src/graphics/surface.zig -femit-bin="/tmp/nihos-indexed-2x/$version.dylib"
done
python3 tools/canvas_indexed_bench.py /tmp/nihos-indexed-2x/baseline.dylib /tmp/nihos-indexed-2x/candidate.dylib
```

Run `sh tools/nihos-dev.sh canvas-workloads` for the independent RV32 comparison. Confirm real Tab5 performance separately with a fixed workload and actual display/PSRAM conditions.

# Captured Japanese glyph composition workload

This host-only experiment replays the existing pinned HarfBuzz/FreeType host capture for the Japanese text cases in `probes/graphics/runtime_text_cases.json`. The capture supplies glyph metrics and A8 bitmaps; the benchmark positions and composites them using Canvas, then compares all 192 × 96 RGB565LE frame bytes including row padding against the independent per-source-pixel reference in `probes/graphics/surface_reference.py`. The tool checks the shaping-result and each raster SHA-256 against `2026-10-28-runtime-text-reference.json` before loading them. The captures are not copied into this change.

Using the same host capture and Zig 0.17.0 ReleaseSafe modules, 20 alternating pairs of 100 frame renders compared the pre-row-optimization Canvas/Surface (`867bce4`) with the optimized sources (`f43dfd2`). On one Darwin arm64 host, median milliseconds per frame were:

| Case | Content | Glyphs | Clipped | Before | After |
| --- | --- | ---: | ---: | ---: | ---: |
| 5 | Horizontal Japanese body and ruby, 24 px | 8 | 0 | 0.00334 | 0.00280 |
| 8 | Vertical Japanese body and ruby, 32 px | 11 | 4 | 0.00388 | 0.00315 |
| 9 | Horizontal Japanese and Latin, 16 px | 12 | 1 | 0.00279 | 0.00254 |

See [all samples, frame and library hashes](evidence/2026-10-29-shaped-glyph-workload/host.json). The inputs are small fixed captured runs; timings include frame initialization and mask composition but exclude font loading, shaping, layout, application state, I/O and presentation. These numbers are not Aozora-reader, XY-editor, RV32, Tab5 PSRAM or physical display timing.

To reproduce, generate the host capture via `sh tools/run-graphics-host-reference.sh` (see its prerequisites and pinned source downloads), or use an existing capture whose hashes match the committed reference. From a checkout containing both commits:

```sh
ZIG_BIN=$(sh tools/bootstrap-zig.sh)
mkdir -p /tmp/nihos-shaped-glyphs
for version in baseline candidate; do
  if [ "$version" = baseline ]; then ref=867bce4; else ref=f43dfd2; fi
  git show "$ref":src/graphics/canvas.zig > "/tmp/nihos-shaped-glyphs/$version-canvas.zig"
  git show "$ref":src/graphics/surface.zig > "/tmp/nihos-shaped-glyphs/$version-surface.zig"
  "$ZIG_BIN" build-lib -dynamic -O ReleaseSafe --dep canvas -Mroot=tools/probes/canvas_glyph_bench.zig -O ReleaseSafe --dep surface -Mcanvas="/tmp/nihos-shaped-glyphs/$version-canvas.zig" -O ReleaseSafe -Msurface="/tmp/nihos-shaped-glyphs/$version-surface.zig" -femit-bin="/tmp/nihos-shaped-glyphs/$version.dylib"
done
sh tools/nihos-dev.sh glyph-bench /tmp/nihos-shaped-glyphs/baseline.dylib /tmp/nihos-shaped-glyphs/candidate.dylib --host-dir build/runtime-text-host
```

A modified raster and the same library file supplied twice were both rejected in negative controls. Real editor/reader workloads and end-to-end target timing remain separate measurements.

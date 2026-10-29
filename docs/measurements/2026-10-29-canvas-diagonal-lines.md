# Canvas diagonal line experiment

For a clipped diagonal, the renderer computes the original wide rounded quotient once at the first visible major-axis position. It updates the quotient using a bounded remainder for later pixels. The major-axis length is at least the absolute minor-axis delta, so each update adjusts the quotient by at most one. Axis-aligned lines retain their existing paths.

The seeded test compares 3,000 cases against the original wide formula, including endpoint reversal, i32 extremes, clips, offscreen endpoints, unaligned pixels and padded rows. The [RV32 receipt](evidence/2026-10-29-canvas-diagonal-lines/rv32.json) identifies candidate `accaa30`: an extreme ascending diagonal and a reversed descending diagonal join the existing editor-like frame and match its independently calculated pixel reference, with the guard check passing.

On one Darwin arm64 host with Zig 0.17.0 ReleaseSafe for all modules, twelve alternating pairs compared complete frames. Median milliseconds per 100 lines:

| Workload | Baseline | Candidate |
| --- | ---: | ---: |
| Diagonal | 0.20207 | 0.04920 |
| Horizontal control | 0.00161 | 0.00151 |
| Vertical control | 0.02567 | 0.02562 |

See [raw samples and library hashes](evidence/2026-10-29-canvas-diagonal-lines/host.json). Shared host results do not establish Tab5, PSRAM or display performance; ESP-EMU supplies correctness evidence rather than P4 timing.

Reproduce from a checkout containing baseline `1041c04` and candidate `accaa30`:

```sh
ZIG_BIN=$(sh tools/bootstrap-zig.sh)
mkdir -p /tmp/nihos-diagonal-lines
git show 1041c04:src/graphics/canvas.zig > /tmp/nihos-diagonal-lines/baseline.zig
git show accaa30:src/graphics/canvas.zig > /tmp/nihos-diagonal-lines/candidate.zig
for version in baseline candidate; do
  "$ZIG_BIN" build-lib -dynamic -O ReleaseSafe --dep canvas -Mroot=tools/probes/canvas_line_bench.zig -O ReleaseSafe --dep surface -Mcanvas="/tmp/nihos-diagonal-lines/$version.zig" -O ReleaseSafe -Msurface=src/graphics/surface.zig -femit-bin="/tmp/nihos-diagonal-lines/$version.dylib"
done
python3 tools/canvas_line_bench.py /tmp/nihos-diagonal-lines/baseline.dylib /tmp/nihos-diagonal-lines/candidate.dylib
```

Run `sh tools/nihos-dev.sh canvas-workloads` for the independent RV32 frame comparison. Physical Tab5 performance and display behavior remain to be measured separately.

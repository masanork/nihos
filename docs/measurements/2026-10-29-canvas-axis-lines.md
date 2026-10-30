# Canvas axis-aligned line experiment

Horizontal and vertical lines clip their inclusive endpoints before filling the resulting span. Diagonal lines retain the original per-pixel calculation. An independent pixel test exercises both endpoint orders, i32 extremes, partial and empty clips, unaligned buffers and row padding.

On one Darwin arm64 host with Zig 0.17.0 ReleaseSafe on all modules, twelve alternating pairs compare complete 320 × 200 frames, with 100 lines per iteration. Median milliseconds per 100 lines:

| Workload | Baseline | Candidate |
| --- | ---: | ---: |
| Horizontal | 0.25249 | 0.00360 |
| Vertical | 0.08696 | 0.03589 |
| Diagonal control | 0.20197 | 0.20478 |

See [raw samples and library hashes](evidence/2026-10-29-canvas-axis-lines/host.json). Timing on a shared host is not P4, PSRAM or scanout timing. The diagonal difference does not establish a regression or improvement.

The [RV32 receipt](evidence/2026-10-29-canvas-axis-lines/rv32.json) identifies candidate `73290ca711f583b42f763a69bea48e87a1dc5dcc`; the editor-like frame includes an extreme horizontal line, a reversed extreme vertical line, a clipped crossing and a single point. Every frame byte matched the independent host reference and the emulator guard check passed. The emulator is a correctness target, not a device timing model.

To reproduce the host benchmark, export the two Canvas versions and build with the same adapter and surface. From a checkout containing baseline `ef0677c` and candidate `73290ca`:

```sh
ZIG_BIN=$(sh tools/bootstrap-zig.sh)
mkdir -p /tmp/nihos-axis-lines
git show ef0677c:src/graphics/canvas.zig > /tmp/nihos-axis-lines/baseline.zig
git show 73290ca:src/graphics/canvas.zig > /tmp/nihos-axis-lines/candidate.zig
for version in baseline candidate; do
  "$ZIG_BIN" build-lib -dynamic -O ReleaseSafe --dep canvas -Mroot=tools/probes/canvas_line_bench.zig -O ReleaseSafe --dep surface -Mcanvas="/tmp/nihos-axis-lines/$version.zig" -O ReleaseSafe -Msurface=src/graphics/surface.zig -femit-bin="/tmp/nihos-axis-lines/$version.dylib"
done
python3 tools/canvas_line_bench.py /tmp/nihos-axis-lines/baseline.dylib /tmp/nihos-axis-lines/candidate.dylib
```

Run `sh tools/nihos-dev.sh canvas-workloads` for the independent RV32 comparison. Physical Tab5 performance and display remain to be measured separately.

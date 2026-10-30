# A8 glyph-mask workload and host benchmark

The RV32 editor-like frame includes two synthetic 13 × 8 A8 masks with padded rows, clipped at opposite corners of a 280 × 170 view. Coverage includes 0, 1, 32, 64, 127, 128, 192, 254 and 255, over existing text-like fills and lines. The independent Python reference calculates encoded RGB565 channel blending and compares all frame bytes. The [receipt](evidence/2026-10-29-canvas-mask-workload/rv32.json) identifies source commit `27c8d4165a6bf1b75a740532f6a3365de4f2c83e`, image and emulator hashes. ESP-EMU is a correctness target, not a P4 timing model.

`tools/canvas_mask_bench.py` measures 240 non-overlapping 16 × 16 masks in a 320 × 200 buffer. Transparent, opaque and a fixed mixed-coverage pattern are separate workloads. It alternates library order over twelve pairs, checks the entire resulting frame, rejects the same file as both inputs, and retains per-sample times. It is a synthetic regression fixture, not a measurement of a specific font, reader, Tab5 PSRAM or display.

As a control, the same compiled library was copied to two separate files; on one Darwin arm64 host with Zig 0.17.0 ReleaseSafe the median per 240 glyphs for the two files was 0.02880/0.02881 ms transparent, 0.05410/0.05410 ms opaque and 0.06030/0.06005 ms mixed. These numbers do not represent an optimization. See the [raw samples and hash](evidence/2026-10-29-canvas-mask-workload/host.json).

To reproduce the control from this tree:

```sh
ZIG_BIN=$(sh tools/bootstrap-zig.sh)
mkdir -p /tmp/nihos-mask-workload
"$ZIG_BIN" build-lib -dynamic -O ReleaseSafe --dep canvas -Mroot=tools/probes/canvas_mask_bench.zig -O ReleaseSafe --dep surface -Mcanvas=src/graphics/canvas.zig -O ReleaseSafe -Msurface=src/graphics/surface.zig -femit-bin=/tmp/nihos-mask-workload/baseline.dylib
cp /tmp/nihos-mask-workload/baseline.dylib /tmp/nihos-mask-workload/control.dylib
python3 tools/canvas_mask_bench.py /tmp/nihos-mask-workload/baseline.dylib /tmp/nihos-mask-workload/control.dylib
sh tools/nihos-dev.sh canvas-workloads
```

For a candidate, compile the same adapter against both source versions instead of copying the library; report the actual source and library hashes. Validate relevant font workloads and physical behavior separately.

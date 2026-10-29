# A8 mask row composition experiment

Canvas validates the mask, target and non-aliasing once, then passes each clipped row to the same internal RGB565/A8 kernel used by `Surface.blit`. This avoids reconstructing and revalidating a one-row surface for each row. The legacy encoded-channel coverage rounding remains unchanged; the separate linear-light compositor is untouched. The source fingerprints in three card/keypad asset manifests are updated; their generated payloads are unchanged. The actual card boot painter produced byte-identical 720 × 1280 host frames before and after; the [comparison](evidence/2026-10-29-canvas-mask-row/card-preview.json) records the frame and library hashes.

A seeded independent test checks 1,000 cases with partial and empty clips, negative positions, padded source and destination rows, unaligned target bytes, random background/color values and alpha values including 0, 1, 127, 128, 254 and 255. The [RV32 receipt](evidence/2026-10-29-canvas-mask-row/rv32.json) identifies candidate `f43dfd2` and a full-frame match for the clipped mask workload and existing scroll, line and indexed fixtures. The emulator is a correctness target, not a P4 timing model. A card-photo device image build and its SRAM audit passed; this is not a physical-device run.

On one Darwin arm64 host, with Zig 0.17.0 ReleaseSafe for every module, twelve alternating pairs compared all output bytes for 240 synthetic 16 × 16 masks. Median milliseconds:

| Coverage | Baseline | Candidate |
| --- | ---: | ---: |
| Transparent | 0.03186 | 0.02485 |
| Opaque | 0.05778 | 0.02913 |
| Mixed | 0.06894 | 0.05434 |

The [samples and library hashes](evidence/2026-10-29-canvas-mask-row/host.json) capture shared-host variation. These synthetic timings do not establish font, Tab5 PSRAM, display or application performance.

To reproduce, build the same adapter against both source versions, including each version of the Surface module. From a checkout containing baseline `867bce4` and candidate `f43dfd2`:

```sh
ZIG_BIN=$(sh tools/bootstrap-zig.sh)
mkdir -p /tmp/nihos-mask-row
for version in baseline candidate; do
  if [ "$version" = baseline ]; then ref=867bce4; else ref=f43dfd2; fi
  git show "$ref":src/graphics/canvas.zig > "/tmp/nihos-mask-row/$version-canvas.zig"
  git show "$ref":src/graphics/surface.zig > "/tmp/nihos-mask-row/$version-surface.zig"
  "$ZIG_BIN" build-lib -dynamic -O ReleaseSafe --dep canvas -Mroot=tools/probes/canvas_mask_bench.zig -O ReleaseSafe --dep surface -Mcanvas="/tmp/nihos-mask-row/$version-canvas.zig" -O ReleaseSafe -Msurface="/tmp/nihos-mask-row/$version-surface.zig" -femit-bin="/tmp/nihos-mask-row/$version.dylib"
done
python3 tools/canvas_mask_bench.py /tmp/nihos-mask-row/baseline.dylib /tmp/nihos-mask-row/candidate.dylib
sh tools/nihos-dev.sh canvas-workloads
```

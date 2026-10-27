# Matrix green and single-pass scrolling — 2026-10-27

Base `ab3ab73`, isolated `codex/native-console`. The user requested vivid
Matrix-like green and a more immediate console response.
[Log](2026-10-27-native-console-matrix.log),
[image/source/artifact/result receipt](2026-10-27-native-console-matrix.json).
Retained locally as `build/physical/console-matrix-01`; image SHA256
`b39144c9feda9690e9ad18f7056c0761879dd13e68d4ea78702fee0d1d326401`.

Palette 4 is the new default: foreground RGB565 `07e8` (approximately
RGB 00FF42), heading `05a6`, background `1082`. Font3 remains the small original
8x8 bitmap with lighter edges, in 78x43 cells. Prior palettes remain available.

Each line advance now finishes in one pixel-copy/presentation pass. The
previous four-step interpolation repeated a large body copy and cache flush
and withheld newer queued updates until those steps completed. The fixed header,
cell differences, pending text grid and single framebuffer remain.

## Device comparison

The exclusive-lease install was byte-verified twice; no backup or SD access.
Full 32MiB PSRAM, SMP 300 rounds, heaps/resources/stacks/Flash/IPI, scanout IRQ,
and all six diagnostic serial controls pass. No captured DMA/DSI/bridge errors
or dropped serial output. The SRAM heap is 49,216 bytes, retaining the 48KiB
minimum. Runtime source/data hashes match the retained manifest.

| Captured measure | Forest/four-step | Matrix/one-pass |
| --- | ---: | ---: |
| Full view-entry paints before READY | 2 | 2 |
| Partial updates | 34 | 34 |
| Line advances | 32 | 32 |
| Pixel-copy/presentation passes | 124 | 32 |
| UI_START to READY, DMA frames | 1537 | 934 |
| Corresponding interval at 59.982Hz | 25.62s | 15.57s |

This is a single comparison of the same capture/control sequence, including
the deliberate checkpoint pause and concurrent scheduler workload. It is not
an isolated copy benchmark or a claim of a stable frame rate. The measured
one/two-line **complete** advance now peaks at 148,084us, versus 148,992us per
**interpolation step** in the preceding forest run. The largest bulk advance
is 237,760us, including 236,122us raster/copy and separately measured cache
maximum 21,730us. Maximum IRQ-off presentation chunk is 27us. Four repeated
passes are removed; a single pass still has substantial latency under load.

The panel remains at its calculated 59.982Hz profile, with PSRAM200 unchanged.
This change does not qualify 60fps text updates or tear-free presentation.
Current visual feedback is pending; colour and pass counts are read back.

## Next bottleneck: CPU initialization

The new `cpu_mhz` field estimates frequency from 32-bit `mcycle` delta divided
by elapsed microseconds from dedicated TG1.T0 (XTAL40/40). It reports 90MHz
during scroll. Both counters continue through worker preemption, so this
measures a core-frequency ratio, not active CPU time for the UI task.

This agrees with the pinned ESP-IDF v5.4.4 rev1/2 bootloader configuration:
`components/soc/esp32p4/include/soc/soc.h` sets
`CPU_CLK_FREQ_MHZ_BTLD` to 90; `bootloader_clock_init.c` selects that constant
for `CONFIG_ESP32P4_SELECTS_REV_LESS_V3`. The native application bypasses
ESP-IDF app startup; `CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ=360` is not evidence
that native code runs at 360MHz. No CPU clock or priority is changed here.

The next useful experiment is explicit normal CPU-clock initialization,
following the pinned SDK's voltage/cache/AHB transition ordering, then repeating
memory/SMP/graphics qualification at the exact resulting candidate. Pixel-copy
offload and presentation buffering are subsequent independent experiments.
Neither speedup nor hardware copy support is claimed by this receipt.

205 Zig tests pass in Debug, ReleaseSafe and ReleaseSmall, including exact
final-raster/guard equivalence with one-pass scrolling. 139 Python tests pass,
including single-pass count, Matrix style and CPU estimate rejection cases.
Formatting, ShellCheck and native image/core/display evidence checks pass.

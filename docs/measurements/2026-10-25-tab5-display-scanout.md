# Tab5 direct display scanout and VSYNC

- Date: 2026-10-25
- Evidence: physical M5Stack Tab5, ESP-IDF-hosted firmware
- SoC: ESP32-P4 revision 1.3
- ESP-IDF: v5.4.4
- Zig: 0.17.0, `-Osafe`, freestanding RISC-V static library
- BSP: `espressif/m5stack_tab5_noglib` 1.3.2

This checkpoint initializes the Tab5 MIPI-DSI display through the pinned
official Espressif NoGLIB BSP, obtains the driver's one full-size framebuffer,
and lends that fixed scanout region across platform ABI version 2. Zig writes
the RGB565 little-endian test pattern directly into scanout. Present performs
the cache ownership transition through the ESP-IDF panel driver and waits for
the next physical refresh callback. No LVGL code or second full-frame copy is
in the rendering path. The configuration fixes the panel driver at one
framebuffer and disables its unnecessary DMA2D draw-buffer copy path.

The BSP is a temporary bring-up oracle, not the intended native nihOS HAL. Its
component manifest currently resolves 20 registry dependencies in addition to
ESP-IDF, including camera, video, audio, USB, touch, and sensor components that
this checkpoint does not use. Exact transitive versions are committed in
`dependencies.lock`; generated `managed_components/` sources are ignored.

## Physical result

The final firmware was flashed through `/dev/cu.usbmodem101`. Three consecutive
boots of the same image reported:

| Measurement | Observed result |
| --- | ---: |
| Width x height | 720 x 1280 |
| Pixel format | RGB565 little-endian |
| Stride | 1,440 bytes |
| Direct scanout allocation | 1,843,200 bytes |
| First present | 5,020-5,021 us |
| 60-refresh sample | 916,497-916,500 us |
| Derived refresh rate | 65.466 Hz |

The first present time includes the whole-frame cache writeback and the wait
for the next refresh event. It fits within a 60 FPS frame interval, but it is
not a Quake rendering benchmark: game simulation, rasterization, input, audio,
and asset I/O are absent. The one-buffer path can also tear if pixels are
modified while scanout is reading them.

The serial completion markers were:

```text
display_width=720
display_height=1280
display_stride_bytes=1440
display_framebuffer_bytes=1843200
display_present_us=5021
display_vsync_samples=60
display_vsync_elapsed_us=916498
display_refresh_millihz=65466
display_scanout=ok
display_vsync=ok
nihos: bootstrap complete
```

These results prove successful panel initialization, scanout-buffer ownership,
and live refresh interrupts on the physical device. The log cannot prove that
the intended colours were visible; human visual confirmation remains a
separate qualification gate.

## Firmware cost

| Checkpoint | Application image |
| --- | ---: |
| AXI-GDMA checkpoint before BSP dependency | 194,912 bytes (`0x2f960`) |
| Pinned BSP dependency present but unused | 263,360 bytes (`0x404c0`) |
| Direct display scanout linked | 346,112 bytes (`0x54800`) |

At this display-only checkpoint the 1 MiB application partition had 702,464
bytes (67%) free. The ESP-IDF size tool attributed 187,518 bytes to Flash text,
83,564 bytes to Flash
read-only data, and 81,043 bytes to DIRAM. The broad dependency graph and
roughly 151 KiB image increase over the AXI-GDMA checkpoint are explicit
reasons to replace this BSP boundary incrementally after its hardware
sequences have been characterized.

## Next gates

- obtain human confirmation of the colour-bar and checker pattern;
- add a two-buffer experiment and measure swap latency, tearing, and PSRAM
  bandwidth before choosing it for the compositor or Quake;
- qualify active touch coordinates and orientation (the bounded ABI and idle
  polling path were added in the following checkpoint);
- extract only the licensed panel detection, power, timing, and init sequences
  required by the native Zig HAL, then compare size and startup time;
- measure a real renderer's CPU time and dirty-region cache cost instead of
  treating refresh availability as an application frame-rate claim.

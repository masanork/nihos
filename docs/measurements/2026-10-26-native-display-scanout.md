# Native display: visible internal-pattern checkpoint

Date: 2026-10-26. Base: `0fc5ecc`, isolated branch
`codex/native-boot-graphics`. This checkpoint closes native **internal colour
bars**, not the PSRAM-rendered Manyoshu boot screen.

The physical Tab5 is ESP32-P4 rev1.3, 16 MiB Flash, 32 MiB PSRAM. Touch
firmware 1 identified its panel as ST7121. The user confirmed colour bands
after attempt 12. In attempt 9 they confirmed backlight but a black white-test
framebuffer. Those observations take precedence over software success flags.

## Final state

Attempt 17 rebuilt and installed mode 4 after removing unsuccessful live
PSRAM clock changes. The image passed the unchanged native audit, was verified
twice against Flash, and its final reset was captured under one exclusive
serial lease. The port was released. No backup or SD write was performed.
There is no additional optical observation for this final reset.

The [final boot log](2026-10-26-native-display-scanout.log) records:

- Native SRAM startup, task/memory checks and `FP_PASS floating=0`.
- Preparation succeeded, panel 3 / ST7121, PHY status 3.
- Scanout startup succeeded, 34 DCS commands, two DMA block completions.
- Internal VPG DPI 80 MHz, lane PLL 960 Mbit/s, GPIO22 latch/enable/input high.
- Zero reported startup DSI, DMA and bridge faults.

The internal generator bypasses framebuffer pixels. Its startup report does
not qualify sustained DMA interrupts or visible lettering. Default native
builds continue to leave display disabled. The final pattern image and audit
are retained under `build/native-scanout-physical/attempt-17-checkpoint-pattern/installed/`.
The [JSON receipt](2026-10-26-native-display-scanout.json) includes their hashes,
source hashes, audit, raw-report fields and per-attempt evidence hashes.

## Failed attempts retained

| Attempts | Finding and disposition |
| --- | --- |
| 1 | Owner allocator rejected the valid display reservation. Accept only the exact default or 2 MiB-reserved complete capacity range. |
| 2 | Scheduler timer interrupt arrived while its counter was borrowed for display. Retire timer route before display startup. |
| 3–5 | DCS LP1 contention; raw `int_st0=0x00100000`. Enabling BTA did not help. Use write-only DCS with ACK/BTA off; reads remain unqualified. |
| 6–7 | DPI20 bridge underrun, including with FIFO priming. |
| 8 | DPI10 DMA completions, but dark screen; USB warm reset also retained DMA clock ownership. Reset retained DMA before native CRT. |
| 9 | GPIO22 high and two DMA blocks; user saw backlight but black framebuffer. |
| 10–11 | Internal VPG plus external bridge feed failed, with payload FIFO overflow `int_st1=0x80`. Disable bridge output for internal VPG. |
| 12 | Native internal colour bars visible to the user. |
| 13 | Invalid trial: a failed build was followed by flashing the older artifact. It provides no 80 MHz evidence. Later build/install sequences require `set -e`. |
| 14 | Actual live PSRAM80 configuration (`core=0x0005e05d`, `bus=0x80000000`), but full-capacity sweep did not finish within 45 seconds. |
| 15 | Not installed: the filesystem thread held the serial lease. |
| 16 | Live PSRAM40 configuration (`core=0x0000c05d`, `bus=0x80000000`), also no sweep completion within 45 seconds. |
| 17 | Removed both clock trials and restored the internal-pattern checkpoint. |

The normal PSRAM clock is retained. More bandwidth may be necessary, but the
cause of the black framebuffer has not been isolated. Neither failed clock
trial qualifies faster PSRAM.

## Validation and remaining gate

At the final source checkpoint: Zig Debug 175 tests passed; ReleaseSafe passed;
Python suites 110 tests passed. The packed panel tables matched C-compiler
output. Zig formatting, ShellCheck and whitespace checks passed. Both mode 4
and mode 2 integer images passed the full native image audit. A default
display-disabled native integer ELF also compiled. Mode 2 was built only in
this final pass; it was not installed over the restored pattern image.

Licensing and the two ST7123 payload-length corrections are documented in
[the vendored table README](../../third_party/tab5-panel-init/README.md).
ST7123 and ILI9881C were not physically tested. The parallel filesystem
worktree was not modified.

Next work is normal-timing PSRAM-to-panel pixel delivery, then visible glyphs
and the three vermilion 「丹穂」 pairs. Long-running refresh, animation/tearing
and simultaneous filesystem activity remain separate physical gates.

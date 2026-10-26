# Native Tab5 display bring-up

This opt-in backend runs under the independent SRAM application, with no
ESP-IDF application runtime or FreeRTOS. The physical ST7121 panel has shown
native internal vertical colour bars. **PSRAM-rendered lettering is still not
visibly working.** The default native application does not enable display.
See the [physical checkpoint](measurements/2026-10-26-native-display-scanout.md)
for the evidence and failed attempts; the earlier preparation-only report is
historical.

## Build modes

```sh
NIHOS_NATIVE_DISPLAY=1 sh tools/build-native.sh device integer # preparation only
NIHOS_NATIVE_DISPLAY=2 sh tools/build-native.sh device integer # experimental lettering
NIHOS_NATIVE_DISPLAY=3 sh tools/build-native.sh device integer # experimental white framebuffer
NIHOS_NATIVE_DISPLAY=4 sh tools/build-native.sh device integer # internal colour-bar diagnostic
```

Mode 4 is the known visible milestone. It initializes the same board and panel,
primes the bridge at 10 MHz, then uses the DSI host's internal pattern generator
at 80 MHz for ST7121/ST7123 (60 MHz for ILI9881C), with external bridge output
disabled. Internal pixels bypass framebuffer delivery. Its `frames` field
counts DMA completions during startup, not visible pattern frames or sustained
refresh interrupts. Neither a successful report nor GPIO22 high proves that
PSRAM pixels are displayed. Modes 2/3 are bring-up experiments: the physical
10 MHz white test had backlight but a black panel, despite DMA completions.
20 MHz exhausted the bridge FIFO. Timing/PSRAM bandwidth remains unresolved;
bandwidth alone has not been established as the cause of the black image.

The options are rejected for the emulator. Pinned ESP-IDF v5.4.4 headers are
needed for the C LL shim; no SDK allocator, display driver or RTOS is linked.
The unchanged native image audit enforces SRAM runtime, approved immutable
Flash tables, known ROM calls, and zero floating-point instructions in integer
mode. Default native ELF builds do not require the display headers.

## Board, command and scanout ownership

- Boot-only GPIO31/32 open-drain I2C verifies the expander identity, preserves
  unrelated pins, and modifies only LCD_EN/TOUCH_EN. There is no expander reset.
  Firmware 1 at touch address 0x55 selects ST7121; firmware 3 selects ST7123.
  Only an address NACK permits the GT911/ILI9881C fallback.
- VO3 provides the PHY reference setting. ST7121 uses an achievable 960 Mbit/s
  lane PLL setting; other supported tables use 1000 Mbit/s. Register/PLL lock
  evidence is distinct from a measured supply voltage or link qualification.
- Bounded DCS writes use licensed vendor tables and exact packet lengths.
  Write acknowledgements and BTA are disabled: the initial acknowledged
  attempts produced LP1 contention. DCS read responses remain unqualified.
- DW-GDMA channel 0 owns one SRAM descriptor and a private RGB565 framebuffer.
  Startup waits for FIFO priming and two complete DMA blocks before permitting
  GPIO22 high. Errors latch the output dark. Stop polls are bounded, retaining
  the private reservation if DMA cannot be stopped.
- After native task/memory/IPI checks, CPU0 retires timer input 16 before using
  its counter for display delays, then routes DW-GDMA to dedicated CLIC input
  18. The handler rearms the descriptor; long-running interrupt refresh has
  not yet been qualified. USB warm reset retires retained DMA before clearing
  SRAM or remapping PSRAM.

This fixture starts display after scheduler qualification has quiesced the
workload. It does not establish concurrent display/task/storage operation.

## Memory and filesystem boundary

The first three 64 KiB PSRAM pages remain nonidentity mapper tests. RGB565 pixels
begin at **0x48030000**, using 1,843,200 bytes inside a 1,900,544-byte aligned
scanout reservation. External owner heaps begin at **0x48200000** and split the
remaining capacity. Validation accepts only the complete existing default
range or this exact display-reserved range. The reservation remains private
on failure. Host tests check identity mappings and non-overlap on 4–64 MiB.

Framebuffer handoff writes back both L1 and L2 data caches. SRAM descriptor
handoff writes back L1. Immutable glyph masks and packed panel commands share
the existing second read-only Flash span; no executable Flash permission or
new mapped span is introduced. Live PSRAM clock changes that stalled the
qualification sweep were removed from this checkpoint.

Display modules make no SD/block/filesystem calls and do not change VO2/PSRAM,
VO4/SD or SD pins. No SD writes or backups were performed. Separate worktrees
preserve the parallel filesystem changes. A display + SDMMC compile/link is
not physical coexistence evidence.

## Reports and reproduction

`NIHOS_NATIVE_DISPLAY_PREP` reports panel identity, image/cache checksum, PHY
lock/stopped lanes, reservation and error stage. Preparation always reports
`scanout=0 backlight=0` because it shuts the PHY down afterwards.

`NIHOS_NATIVE_DISPLAY_SCANOUT` reports startup status/stage/error, panel,
completed command count, last opcode, DMA frames, requested backlight, selected
DPI/lane rates, FIFO priming, raw DSI/DMA/bridge errors, cleanup result, and GPIO22
latch/enable/input/mux diagnostics. The ST7121 successful diagnostic sends 34
commands. A failure after startup emits `NIHOS_NATIVE_DISPLAY_IRQ_FAIL` and
`NIHOS_NATIVE_FAIL`. Optical evidence must be recorded separately.

`tools/boot-graphics/capture-native-display.py` requires ESP-IDF Python,
`--image`, `--audit`, `--loader` and `--partitions`. Without `--install` it
resets/captures only; with it, the helper installs explicit Flash offsets
0x2000/0x8000/0x10000, retains artifacts and hashes, verifies twice, then captures
the final boot under one exclusive serial lease. It never backs up Flash or
accesses SD. Do not run it while another physical-device session owns the port.

Next gate: qualify normal-timing framebuffer delivery without destabilizing
native PSRAM, then show the Manyoshu inscription and its three vermilion
「丹穂」 pairs. Internal bars do not close that gate.

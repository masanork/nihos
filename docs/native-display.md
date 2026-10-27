# Native Tab5 display

The opt-in standalone SRAM application now displays the boot inscription from
native **200 MHz, x16 DDR PSRAM**, with DQS tuning, at a **59.982 Hz timing target**.
There is no ESP-IDF application runtime or FreeRTOS. The user confirmed the full
portrait image in attempt 36 and the keyboard-oriented landscape composition
in attempt 37. The landscape uses old-form `萬葉集 / 卷 / 穗 / 經 / 將` lettering,
with the title on the left and the vertically written poem on the right.
After extending the monochrome hold to about one second and the fade to about
two seconds in attempt 38, the user also confirmed the colour animation.
See [physical evidence](measurements/2026-10-27-native-landscape.md).

The optional [native diagnostic console](native-console.md) adds a bounded
SRAM boot journal and an ASCII snapshot in the same landscape framebuffer.
Japanese UD font loading remains a later microSD/filesystem service.

## Build and preview

```sh
NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 NIHOS_NATIVE_QUALIFICATION=1 \
  sh tools/build-native.sh device integer
python3 tools/boot-graphics/preview.py --out build/boot-graphics-landscape
```

The default native application leaves display and the fast PSRAM profile off.
`NIHOS_NATIVE_DISPLAY_HZ=60` is the standard target; `65` preserves vendor
porches at 80 MHz for a ~65.45 Hz comparison on ST7121. The comparison option is
implemented but has not received the full-frame physical qualification of the
60 Hz candidate. Neither value is a confirmed maximum module specification.
Options are rejected for the emulator. Pinned IDF v5.4.4 headers supply register
layouts and inline LL helpers; no SDK allocator, RTOS, display or PSRAM runtime
is linked. The unchanged image audit still enforces the approved ROM ABI,
immutable Flash spans, SRAM execution and integer-only instructions.

Additional bring-up modes: `1` prepares only; `3` scans a white PSRAM frame;
`4` enables internal colour bars; `5` repeats a single SRAM white pixel;
`6` displays a small SRAM title; `7` is the failed compact-scene experiment.
Modes 6/7 retain their portrait sampling coordinates. Internal colour bars
bypass framebuffer delivery. The compact scene is not a supported fallback.
The [older checkpoint](measurements/2026-10-26-native-display-scanout.md)
records earlier unsuccessful scanout attempts and should be read historically.

## Clock, ownership and memory

Boot first sets the existing VO2 PSRAM supply, then selects MPLL400, configures
x16 variable-latency PSRAM, and sweeps four DQS phases and 31 delay settings
before cache mappings or CPU1 startup. Each delay uses 100 repeated 128-byte
samples. No valid window, timeout or failed readback prevents memory exposure.
The physical candidate passed the full 32 MiB two-pattern sweep, mapper checks,
300-round SMP run and heap/IPI checks. MPLL was already running at 400 MHz on
all observed runs; fresh cold-power MPLL calibration remains unqualified.
This is a boot-only transition, not a live clock change under cached users.

The first three 64 KiB PSRAM pages remain nonidentity mapper tests. RGB565
pixels start at **0x48030000**, consuming 1,843,200 bytes inside a 1,900,544-byte
reservation. Owner heaps start at **0x48200000**. The same 720x1280 scanout buffer
holds the 1280x720 landscape scene: `(x,y)` becomes `(y,1279-x)`, matching MeOS.
No second framebuffer or framebuffer transpose pass is allocated.

Boot-only GPIO31/32 open-drain I2C verifies expander identity and changes only
LCD_EN/TOUCH_EN, preserving unrelated pins. LCD reset high uses input pull-up.
Before any transactions or CPU1 startup, an explicitly detected held SDA may
receive at most nine release clocks and a STOP. SCL-low and held-SDA failures
are bounded. Ordinary transfers never steal or clear a busy bus. Attempt 36
needed one release clock; attempt 37 needed none. There is no expander reset.

VO3 powers the DSI PHY. Actual touch firmware 1 at address 0x55 identifies
ST7121, with a 960 Mbit/s lane setting. Bounded DCS writes use the licensed BSP
tables; DCS reads remain unqualified. DW-GDMA channel 0 reads the private frame
through one SRAM descriptor, rearmed on CPU0 CLIC18. Startup primes its FIFO
and completes two DMA blocks before enabling GPIO22. Errors latch dark.
L1/L2 writeback makes CPU pixels visible to DMA. Warm reset retires retained
DMA before clearing SRAM or remapping PSRAM.

The display starts after scheduler qualification quiesces the workload. This
fixture does not establish concurrent display/task/filesystem service. Display
code never accesses SD, VO4 or storage APIs. No SD writes or Flash backups were
performed; parallel filesystem edits remain in their independent worktree.

## Evidence and reproduction

`DISPLAY_PREP` reports identity, reservation, checksum and PHY lock with video
off. `DISPLAY_SCANOUT` reports command/startup status, DMA frames, priming,
backlight GPIO and DSI/DMA/bridge errors. `DISPLAY_LAYOUT` records logical
geometry and rotation. `DISPLAY_TIMING` records clock, totals and **calculated**
refresh; it is not a photodiode measurement. `DISPLAY_IRQ_PASS` proves the
handler rearmed after startup, not indefinite endurance or optical correctness.

`tools/boot-graphics/capture-native-display.py` holds one exclusive serial lease,
retains explicit image hashes, installs at 0x2000/0x8000/0x10000, verifies Flash
twice, then resets/captures the final boot. It waits for an existing owner when
`--serial-wait` is supplied; it never kills the owner. Without `--install` it
only resets/captures. It does not back up Flash or access SD.

```sh
python3 tools/check-native-display-log.py BOOT.log IMAGE-AUDIT.json REPORT.json \
  --mode 2 --dpi 80
```

The checker validates native memory/core evidence, the exact display reservation,
PSRAM200 mode/PLL/tuning/readback, startup and later IRQ evidence, and timing.
It explicitly leaves user optical observations separate. Host Debug/ReleaseSafe
tests check rendering bounds, rotation, recolouring and memory/clock models;
negative log tests reject partial or misleading physical records.

## Why 60 Hz

Vendor ST7121 porches give 802 clocks by 1524 lines. An 80 MHz pixel clock thus
computes to 65.453 Hz (15.278 ms). The IDF 5.4.4 integer divider also turns a
70 MHz request from a 240 MHz source into 80 MHz. That is a software consequence,
not evidence of the module's maximum rating. Keeping 80 MHz and increasing
vertical front porch from 200 to 339 gives 59.982 Hz and 1663 total lines.

720x1280 RGB565 payload is about 110.56 MB/s at 59.982 Hz versus 120.64 MB/s
at 65.453 Hz. Longer blanking reduces average payload traffic; active-pixel
peak traffic stays the same. Power savings have not been measured.

The [official Tab5 specification](https://docs.m5stack.com/en/core/Tab5)
lists a 5-inch IPS 720x1280 MIPI-DSI display and panel revisions, but no module
refresh range or pixel response time. The accessible
[Sitronix ST7121P document](https://www.display-lcd.com/data/upload/admin/202509/68b935053144a.pdf)
lists 60 Hz typical in section 7.3.2, with no min/max entries. Exact equivalence
to this ST7121 module remains unverified. Touch report rates are not display
refresh. See also the pinned
[IDF divider implementation](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/mipi_dsi_hal.c).

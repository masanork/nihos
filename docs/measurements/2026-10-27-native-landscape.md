# Native PSRAM200 / landscape boot checkpoint — 2026-10-27

Base: `10a4cb6`, with the owned dirty continuation captured by source SHA256
manifests and exact image audits. Physical unit: ESP32-P4 rev1.3,
MAC `e8:f6:0a:e2:e8:9c`, 16 MiB Flash, 32 MiB PSRAM, ST7121 panel.
No backup or SD operation; only explicit bootloader/partition/application
Flash offsets were overwritten under an exclusive serial lease.

## Evidence boundaries

- Attempt 33 first passed native PSRAM200 tuning and full-memory qualification.
- Attempt 36 first passed full PSRAM scanout at 59.982 Hz; the user said
  `見えるね` and requested a keyboard-oriented landscape layout. Initial SDA
  was held low; one explicit boot-only clock released it before transactions.
- Attempt 37 passed the same native memory/core gates, 90 polled DMA frames,
  and subsequent interrupt frame 91 with zero DSI/DMA/bridge faults. The user
  confirmed `向きも配置もよい。色づきのアニメーションは確認できなかった`.
  The orientation and final composition are physically confirmed; the animation
  is not. The old-form typography is an artistic treatment of the supplied text,
  not a manuscript facsimile.
- Attempt 38 increases the monochrome hold from 24 to 60 frames and the
  sequential overlapping fades from 16 to 32 updates, four frames per update.
  At the chosen timing this means about one second monochrome and two seconds
  of fading. It passed 190 polled frames and subsequent IRQ frame 191 with
  zero errors. After replaying the same retained image, the user confirmed
  `色づく様子がよく見えたよ`. Its serial evidence and optical observation
  are recorded separately in the
  [fade log](2026-10-27-native-landscape-fade.log) and
  [fade audit/result record](2026-10-27-native-landscape-fade.json).

[Attempt 37 log](2026-10-27-native-landscape.log) and
[artifact/source/audit/observation record](2026-10-27-native-landscape.json)
are checked in with serial CRLF normalized to LF. Full Flash/verify/capture files and retained ELF/binaries remain
in `build/native-scanout-physical/attempt-37-landscape-old-glyphs/`.

## What resolved bring-up

Fixed-source SRAM DMA needed single beats: the earlier burst16 white candidate
produced fine black/white bands even with passing DMA counters. Single-beat
white was user-confirmed in attempt 20; the small SRAM title was confirmed in
attempt 26. Neither proved a full-frame PSRAM pipeline.

Conservative PSRAM ran at 20 MHz x8 DDR, with 40 MB/s raw bus capacity versus
about 110.6 MB/s of RGB565 pixels at 60 Hz. Compact chained scenes at that
memory rate still failed with FIFO underruns, including a lower pixel-clock trial. Those failed
experiments are retained as diagnostics, not adopted defaults. The opt-in
native path now configures 200 MHz x16 DDR (800 MB/s raw), following the pinned
SDK's mode and DQS window policy without linking its runtime. Raw bus capacity
is not a measured application throughput result.

Attempts 34/35 failed before video because SDA was held low. Releasing GPIOs
before mux changes did not alone resolve this. Explicit pre-transaction bus
clear in attempt 36 did; the next landscape boot needed no recovery. Ordinary
I2C transfer behavior remains unchanged.

## Remaining scope

The 60 Hz value is computed from timing, not an optical cadence measurement.
The 65.45 Hz comparison has not received this full-frame qualification. There
is no measured power benefit or confirmed module refresh maximum. All observed
MPLL runs reused an already-ready 400 MHz PLL; fresh cold-power calibration and
long-duration/coincident filesystem workloads remain open. Flash verification,
serial gates, host renderer tests and user optical observations are distinct.

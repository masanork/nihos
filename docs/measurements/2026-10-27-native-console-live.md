# Live native console — 2026-10-27

Isolated branch `codex/native-console`, based on `232e37b`, with dirty source
while candidates were built. Physical unit: ESP32-P4 rev1.3, 32 MiB PSRAM,
ST7121 panel, MAC `e8:f6:0a:e2:e8:9c`, `/dev/cu.usbmodem101`. No SD access or
Flash backup. Installation held an exclusive serial lease and verified Flash
bytes twice before the recorded reset.

## Normal candidate

[Final log](2026-10-27-native-console-live.log) and
[image/source/artifact/result receipt](2026-10-27-native-console-live.json).
Retained locally as `build/physical/live-04`; image SHA256:
`81d510b914c37df060a86d21381da016f672cf9652a3dbf449e985b2ecebe1cd`.

Video starts after full destructive PSRAM qualification and before CPU1/core
qualification. Input initializes as standard Tab5 keyboard firmware1/HID mode1
plus diagnostic Serial/JTAG (`sources=3`). The console is 80x22, JetBrains Mono
24 px, pale green palette1. The inscription advances only towards completed
memory/core/console milestones, without the legacy timed hold.

Full 32 MiB two-polarity memory sweep, 64-round PSRAM exchange, 300-round SMP,
owner heaps, resources, stacks, Flash records and 64 IPI exchanges pass.
Serial transmission reports zero dropped bytes. The unchanged SRAM heap floor
is retained: 50,368 bytes total. Runtime source/data hashes match the retained
build manifest. Default device/emulator images also pass their audits; emulator
build success is not emulator execution evidence.

The capture sends Esc, Ctrl+L, Ctrl+B, Ctrl+R, Ctrl+L, Esc. All six are accepted.
The pause request during cores is honored only after cores return, with DMA
continuing from frame1313 to frame1347 during the pause. Ready is frame1364;
the final colour target255 is reached at frame1414. The last accepted key is
frame1442. No DMA/DSI/bridge failure appears in the capture. Calculated panel
timing remains 59.982 Hz; no optical cadence measurement is claimed.

```sh
python3 tools/check-native-display-log.py \
  docs/measurements/2026-10-27-native-console-live.log \
  build/physical/live-04/installed/image-audit.json build/live-report.json \
  --mode 2 --dpi 80 --console --exercise-live
```

## Failure and correction evidence

1. [First failure log](2026-10-27-native-console-live-01-failed.log) /
   [image receipt](2026-10-27-native-console-live-01-failed.json): early video
   enabled interrupts, conflicting with the allocator's original IRQ-off boot
   entry. It stopped at `CPU0 external memory begin` and emitted a failure
   frame handoff. A separate display-only bootstrap entry now permits DMA IRQs
   during linear metadata initialization, preserving ordinary allocator checks.
2. [Second failure log](2026-10-27-native-console-live-02-failed.log) /
   [image receipt](2026-10-27-native-console-live-02-failed.json): live controls
   worked, then DMA reported `0x2000` at frame657 (invalid shadow/LLI), during
   core round140. A main-loop ROM cache operation could be interrupted by the
   descriptor cache operation. Framebuffer and post-video mapper operations
   now mask IRQs around 1 KiB chunks, leaving IRQ service between chunks.
   Two subsequent normal device runs pass. The source-level nesting defect is
   removed; this does not establish that every future DMA fault has that cause.
3. [Injected failure log](2026-10-27-native-console-live-fault.log) /
   [image/source receipt](2026-10-27-native-console-live-fault.json): deliberately
   fails at cores with the display/input ready. The failure renderer reports
   success, then manual DMA/input service continues. Esc is accepted; Ctrl+L,
   Ctrl+R and Ctrl+B are rejected, retaining details and failed state. Frames
   advance53 to109 across those controls. This is expected failure-path
   evidence, not normal core qualification. The final installed image is the
   normal candidate above, with injection disabled.

The checker also needed a correction: Python `findall` returns a string for a
single capture group. One-field records now use `match.groups()`, so complete
resume frame/drop-counter values are checked. A nonzero TX-drop negative
fixture catches the previous parsing error.

Host validation: 203 Zig tests pass in Debug, ReleaseSafe and ReleaseSmall;
133 Python tests pass, including incomplete/false live records, invalid input,
failure rejection and the single-field regression. ShellCheck and formatting
checks pass. Normal/fault image audits retain SRAM regions, integer-only code,
known ROM ABI and no RTOS linkage.

## Remaining observation gates

Physical keyboard detection is proven; **the control exercise uses diagnostic
serial**, not physical key presses. No physical-key event was observed in the
separate 75-second read-only capture. User confirmation of Ctrl+L/Esc and of
the new font/palette remains pending. `visible=1` means renderer/cache handoff,
not a camera or user observation. Cold-power PLL calibration, universal hang
recovery, USB-A HID and Bluetooth keyboard support are not qualified here.
Japanese UD fonts remain deferred until microSD/filesystem loading is ready.

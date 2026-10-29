# Native console and boot diagnostics

## Decision and current scope

Use one boot journal as the source of truth for two views: the quiet inscription
and a detailed diagnostic console. Completion of real operations advances the
colour target; a frame/timer may smooth movement only towards that target.
An operation that never returns keeps its current stage visible. Colour is
not elapsed time, a percentage, or evidence that input/storage is ready.

The live integer console now defaults to normal boot when
`NIHOS_NATIVE_QUALIFICATION=0`. It starts scanout after PSRAM initialization
and calibration, then checks one cross-core PSRAM exchange, both scheduler
timers and one IPI round trip before READY. It creates bootstrap contexts
without the busy/lifecycle fixture tasks. CPU0 continues to service the
inscription and keyboard after READY; colour completion never delays READY.
The 2 KiB byte journal, stage state and ASCII grid still share one landscape
RGB565 buffer. The earlier final snapshot remains available with
`NIHOS_NATIVE_CONSOLE_LIVE=0`.

Normal boot omits the destructive full-memory sweep, 300-round scheduler soak,
allocator misuse/worker probes, Flash table CRC passes, and the preparatory
framebuffer paint/checksum and PHY start/stop proof. It retains mapping and
address/data checks, full heap metadata initialization, stack guards, CPU
clock initialization, and real PHY/DMA startup. DQS still scans every phase
and delay and requires 100 successful samples for every accepted delay;
only the remaining samples of an already-failed delay are skipped. Panel
identification polls within the former 500 ms wait budget; electrical bus
faults fail rather than select an assumed panel. Normal panel commands keep
all upstream delays, but omit the additional 5 ms per command.

`NIHOS_NATIVE_QUALIFICATION=1` selects the full existing harness, including
the full-memory sweep and all 100 samples of rejected DQS delays. Set
`NIHOS_NATIVE_BOOT_FAST=0` explicitly for a harness comparison without the
optional full-memory sweep. `NIHOS_NATIVE_BOOT_FAST=1` is restricted to live
integer, non-qualification builds; floating/compiled/SQLite and emulator
profiles retain their previous qualification workflow.

`NIHOS_NATIVE_BOOT_TIME` records completion timestamps in microseconds from
TG1 diagnostic-clock initialization (after CPU clock setup, not power-on).
Stage IDs are from `boot_state.Stage`: memory=1, display_prepare=3,
display_scanout=5, input=7, cores=4, console=6. `BOOT_HEALTH` reports both
scheduler tick counts and IPI counts. Validate these with
`check-native-display-log.py --normal-boot --console --mode 2 --dpi 80`.
The full harness checker does not accept normal boot as qualification.
Validation for this change: 212 host Zig tests pass in Debug, ReleaseSafe and
ReleaseSmall; 157 Python checks pass, including negative normal/qualification
evidence cases. Normal and diagnostic device images pass the native image
audit. The 32 MiB emulator completes the unchanged 300-round integer harness,
lifecycle, allocator and IPI/idle checks. Normal-image internal SRAM heap is
76,672 bytes (qualification image: 49,472 bytes); the external display/heap
reservation and 56 KiB stack bank remain unchanged. Visible warm-reset results
are recorded below; complete cold power-on validation remains pending.

After the C6 hardware work was stopped, the same candidate was reinstalled
and its Flash bytes verified twice. [Three subsequent warm-reset captures](measurements/2026-10-27-native-normal-visible.json)
all pass. The user confirmed the visible display and Esc console transition;
the first capture independently records the physical Tab5 keyboard Esc
(source=2, usage=0x29, accepted=1). The final capture exercises serial
console -> splash -> console after READY and leaves the console visible.
No C6 firmware banner or unexpected reboot appears in these captures.

The host receives UI_READY 1.867-1.875 seconds after requesting a USB reset;
UI_START -> UI_READY is 21 DMA frames, approximately 0.350 seconds. The
1.751-1.757 second diagnostic-clock figure is **console-stage completion
before the final redraw**, not the exact UI_READY timestamp. This clarifies
the earlier capture's READY label and the historical checker field
`ready_us_from_diagnostic_clock`. Host times include reset and USB buffering;
none of these captures establish a cold power-on time. CPU remains 360 MHz,
PSRAM200 x16 DDR and 59.982 Hz scanout, with Matrix green font3. Complete
power-off/on validation remains outstanding.

The earlier [physical capture](measurements/2026-10-27-native-normal-physical.json)
remains a log-only result: C6 hardware work replaced its application before
the visual check, and Flash comparison confirmed the mismatch. Its 1.757-second
value records final-stage completion; the UI_START interval was 0.333 seconds.
Do not count that interrupted observation as optical confirmation. Holding
the serial port for each capture alone does not prevent a later writer from
replacing firmware; exclusive device use was coordinated for the visible runs.

Headless normal-boot regression is now reproducible without a device:

```sh
python3 tools/run-native-boot-smoke.py
```

This runs the same normal bootstrap/scheduler/memory/IPI path under ESP-EMU,
with LCD/input disabled and the emulator's command-mode PSRAM profile. It tests
PSRAM absent, 4/32/64 MiB, CPU1 readiness delayed by 100 ms, and missing readiness,
IPI reply or CPU1 timer. Successful cases must stay alive with continued ticks
and zero fixture-worker counters after READY; injected failures must time out
without READY. `NIHOS_NATIVE_BOOT_TEST=1..5` is restricted to a headless integer
emulator build and rejected for device builds. No device-profile exception is
provided. All eight captured cases pass; Python checks include retained
log replay and rejection of invented physical/qualification evidence.

The [receipt](measurements/2026-10-27-native-normal-emulator.json) binds emulator
version/hash, native source hash, image audits, UART logs and each result. The
previous device-build candidate's allocated ELF sections (including all code,
constants, initialized data and memory layout) match the device regression
build byte-for-byte. Test/fault marker strings are absent from that device
image. Embedded ELF/debug digests can still change the `.bin` hash. The replay
checks kernel execution and fault handling; LCD, keyboard, PSRAM200 and real
power-on/boot timing remain untested by it.

```sh
NIHOS_NATIVE_CONSOLE=1 NIHOS_NATIVE_CONSOLE_LIVE=1 \
  NIHOS_NATIVE_KEYBOARD_I2C=1 NIHOS_NATIVE_CONSOLE_PALETTE=4 \
  NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 \
  NIHOS_NATIVE_QUALIFICATION=0 sh tools/build-native.sh device integer
python3 tools/console/preview.py
python3 tools/console/preview.py --failed
# Palette: 0 = neutral, 1 = pale green, 2 = blue, 3 = stronger green, 4 = Matrix green (low-level default)
# NIHOS_NATIVE_CONSOLE_PALETTE=4 selects vivid green, RGB5650x07e8.
# NIHOS_NATIVE_CONSOLE_FONT=3 (low-level default): original small bitmap, lighter edges.
# 0: original solid bitmap; 1: JetBrains; 2: Source Code Pro.
python3 tools/console/preview.py --palette matrix
python3 tools/console/preview.py --palette blue
python3 tools/console/preview.py --palette green --font source-code
```

The low-level console default uses the small **8x8 VGA bitmap in 16x16 cells**:
78 columns and 43 rows, with 16-pixel margins. The normal device build instead
uses the JetBrains face and neutral palette for a more readable terminal. Option3 retains the exact bitmap
and cell advance, reducing coverage on exposed right/bottom stroke edges.
Option0 is the initial solid bitmap. Low-level palette4 is vivid
Matrix-style green, RGB565 foreground0x07e8 and heading0x05a6. Palette3 retains
the darker muted0x5dcf trial and palette1 the earlier pale0xa5f5 trial.
JetBrains Mono Medium 24 px and Source Code Pro Medium 25 px use 80x22
in 15x30 cells.

During a console view, boot output appends directly to a retained body grid.
The fixed header is refreshed separately without changing the output cursor.
The2 KiB byte journal remains independent; it seeds the first view and retains
serial evidence, but is not replayed to reconstruct every update. Its byte-ring
wrap can no longer move all existing glyph positions.

For the small bitmap, the raster updates changed cells, and scrolls by copying existing body pixels
upward in a single pass on the next observed frame. Only the incoming strip and
the former cursor row are rasterized. The header and margins stay fixed. Logs
arriving during motion collect in a separate target grid. A real stage change
finishes a pending update before publishing its header. Full painting is reserved
for entering the console from the inscription and fatal-frame recovery.
The optional large faces update changed cells. Four-step interpolation was
removed because it copied/flushed the body four times per line advance,
increasing queue latency under boot load. New logs coalesce in the pending
grid while an update is being processed.
Damage rectangles also bound cache writeback; the whole buffer is not cleared
on ordinary updates. This uses the existing front buffer, so scanout tearing
still needs direct observation; this is not a double-buffered presentation.

Renderer state and three grids fit in the unused 56 KiB tail of the existing
private display reservation, starting at 0x481f2000. Owner heaps and the 2 MiB
external reservation are unchanged. No general heap, SD or filesystem is used.
`CONSOLE_RENDER` records full/partial updates, scrolls/steps and the largest
observed scroll+cache interval in microseconds. `cpu_mhz` estimates CPU
frequency from cycle-counter delta against the dedicated XTAL timer during a
scroll interval; this includes preemption and does not measure active task CPU
time. It does not change clocks.

Only printable ASCII masks are generated on the host; the full font file and
font engine are not linked. The selected face alone occupies immutable Flash:
760 bytes for the bitmap, or10,761 bytes of JetBrains Mono coverage plus 380 bytes of glyph offsets, or
10,597 bytes of Source Code Pro coverage plus offsets. Native builds do not
require Pillow, font files or a filesystem. The source fonts, exact revisions,
SHA256 hashes and OFL notices are in
[the ASCII font provenance](../src/graphics/ascii/README.md). This does not
implement or embed the deferred Japanese UD faces.

The console option requires the full PSRAM display mode. The low-level ELF build
leaves it off by default; the normal device build enables it. Live mode requires the console; I2C keyboard and fault injection
require live mode. The build retains the 48 KiB SRAM heap minimum, existing
image regions, ROM allowlist and integer-only audit. Kernel, tasks and allocator
remain ReleaseSafe. Display service, bounded peripheral leaves and graphics use
ReleaseSmall to fit this budget. Explicit geometry/packet bounds remain, with
host tests in Debug, ReleaseSafe and ReleaseSmall. No SRAM aperture is widened.
The audited ROM putc address remains an absolute linker symbol even when live
mode replaces its calls with bounded Serial/JTAG transmission.

CPU0 is the sole journal/model writer. In live mode it does not mask interrupts
while copying logs or constructing the grid. The nonfatal DMA IRQ report is
deferred to the main loop; CPU1 does not append to this journal. The legacy
snapshot still masks local interrupts for journal access. Rasterization and framebuffer
cache writeback run outside IRQs; initialized boot/IRQ guards are checked after
presentation. The ring retains newest bytes and reports loss; separate stage
outcomes survive verbose output. A serial record proves cache handoff, with
optical legibility checked separately.

## Visible stages and interrupt ownership

Native device builds now initialize CPU 360 MHz explicitly before PSRAM startup;
the retained loader's 90 MHz setting is no longer the application's operating
clock. MEM/SYS run at 180 MHz and APB at 90 MHz. PSRAM uses its separate MPLL400/2
clock at 200 MHz x16 DDR; this is independent of the CPU clock and the panel's
calculated59.982 Hz timing. The measured handoff and remaining limits are in
[the CPU360 device record](measurements/2026-10-27-native-cpu360.md).

The target is 360 MHz for the physical rev1.3 unit. Its manufacturer's normal
profile is 360 MHz CPU /200 MHz PSRAM;400 MHz belongs to the newer silicon profile.
`NIHOS_NATIVE_CPU_MHZ=0` retains loader clocks for comparison; the emulator
defaults to 0 and does not touch these physical registers.400 MHz is rejected
for this rev1/2 build. Clock transition code runs only at boot, on CPU0 with
IRQs masked and before CPU1/cache-mapping users. It reuses the existing CPLL,
uses bounded divider handshakes, updates the fixed ROM timing calibration, and
emits independent divider/timer readbacks.

1. Start the SRAM journal/stage model after CRT. Keep the destructive full
   PSRAM sweep before live framebuffer use.
2. Initialize the panel and establish scanout, then initialize input. Optional
   storage work follows video; this change does not enable storage or touch SD.
3. Render the cores stage before starting CPU1, external heaps and the
   scheduler qualification. Preserve the DMA route (CLIC 18) when enabling CPU0
   timer/IPI routes. Defer IRQ_PASS output so records cannot interleave.
4. Memory completion permits colour target 85, core completion 170, and
   console/scanout completion 255. Each new observed frame approaches that
   target by at most three levels. There is no fixed splash hold or delay in
   boot to finish the animation. These values are dye levels, not percentages.
5. A failure latches the failed stage and details view. If display/cache/stack
   guards are usable, render the final journal and service diagnostics with
   manual DMA polling; the scheduler is stopped and failed boot cannot resume.

Live panel delays and key polling own **TG1.T0**, XTAL40 divided by40 to 1 MHz,
without an alarm/IRQ. Scheduler TG0 counters are not borrowed or stopped.
Before external heap metadata initialization, only the display IRQ may run on
CPU0. Its handler rearms DMA and never allocates. A separate boot-only allocator
entry permits that IRQ during the long linear metadata initialization, then
briefly masks interrupts for the original bootstrap checks. Ordinary allocator
entry contracts remain unchanged; CPU1 and worker clients are not released
until initialization completes.

Live Serial/JTAG transmission has a bounded wait and drop counter, so an absent
host reader cannot hold boot/failure display indefinitely. The journal receives
bytes before transmission. During IRQ-off fatal transmission, its bounded wait
polls DMA. `UI_IO` reports dropped bytes; complete serial qualification requires
zero. Framebuffer presentation uses bounded 16 KiB cache chunks (the initial full
view and post-video mapper keep 1 KiB chunks), masking local IRQs around each
ROM command. Tall dirty rectangles coalesce adjacent physical rows to reduce
ROM-command overhead; narrow updates keep individual physical row spans. This prevents the DMA ISR
from nesting its descriptor cache command inside a main-loop command. No USB
controller reset or host-controller ownership is introduced.

Display/PSRAM preparation failures still precede usable video. The journal is
volatile, and an arbitrary deadlock cannot guarantee keyboard service. A future
SRAM framebuffer or reset-retained crash checkpoint needs separate evidence.

## Diagnostic keys and recovery semantics

The standard **Tab5 Keyboard on Ext.Port1 (GPIO0 SDA / GPIO1 SCL, I2C0x6d)**
provides physical modifier/usage events. Initialization reads firmware/address,
selects HID mode1 only if necessary and verifies it. It never writes persistent
address/RGB settings or clears events queued during boot. Polling runs outside
IRQs, at most four events per 10 ms; unavailable input does not prevent boot.

| Key | Action |
| --- | --- |
| Esc | Show detailed logs; startup continues |
| Ctrl+L | Return to the inscription |
| Ctrl+B | Request pause at the next returned stage boundary |
| Ctrl+R | Resume a deliberately paused boot |

The existing USB Serial/JTAG diagnostic port accepts the same control bytes.
ANSI arrow sequences are discarded instead of being mistaken for Esc. A failed
boot accepts Esc but rejects splash/pause/resume. These controls do not execute
shell commands or provide text editing, Japanese input or a command prompt.

Input adapters emit shared diagnostic actions. Source IDs/capability bits
reserve independent identities for serial, standard Tab5 keyboard, USB keyboard
and Bluetooth keyboard. **USB-A HID and Bluetooth drivers are not implemented.**
Future USB input must share the host-controller owner with the separate CCID
work; Bluetooth transport requires its own hardware/service integration. Neither
transport is a prerequisite for the present standard-keyboard path.

Register protocol reference: [official M5Unit-KEYBOARD implementation](https://github.com/m5stack/M5Unit-KEYBOARD/blob/main/src/unit/unit_Tab5Keyboard.cpp).

A key request cannot unwind an operation that has not returned. A deliberately
paused safe checkpoint keeps painting and polling; an arbitrary IRQ-off CPU
lockup needs a separate watchdog/reset recovery path.

## Japanese fonts: deferred until microSD and filesystem are ready

The user confirmed that UD fonts will be installed on microSD, following the
MeOS `masanork` branch. **No Japanese font binaries, runtime OpenType parser,
FreeType integration, SD access, or new filesystem ABI is added here.** The
existing fixed Manyoshu masks remain separate boot artwork.

Read-only comparison: MeOS `refs/heads/masanork` at
`7c343f6c718365558fcd9565e631486d824d2c6a` has
`drivers/lcd/otfont.h` and `otfont.c`. Its default path is
`/assets/fonts/BIZUDGothic-Regular.ttf`; its FreeType adapter supports bounded
VFS reads, a PSRAM-backed stream/glyph cache, and an optional resident face.
This is design reference, not copied implementation or nihos qualification.

Keep these boundaries when the filesystem work lands:

- The font service owns a seekable read-only source: length plus bounded
  `readAt(offset, destination)`, with short-read/error handling and an owned
  lifetime. The VFS adapter opens/closes the file; the raster does not know SD
  sectors, mount points or paths. A memory-backed source supports host tests.
- A face/provider maps Unicode and shaped glyph IDs to metrics and coverage
  masks. The display composites those masks into RGB565. Face selection,
  pixel size, glyph-cache generation and text style are independent of the
  emergency ASCII grid.
- Try `/assets/fonts/BIZUDGothic-Regular.ttf` and
  `/assets/fonts/BIZUDMincho-Regular.ttf` as configurable defaults, not boot
  prerequisites. Missing, removed, unsupported or corrupt fonts leave ASCII
  diagnostics available. Replacing a face invalidates its cached glyphs.
- Bound file size, parser allocation, glyph size, I/O/cache capacity and read
  time. Start with streamed reads and an LRU coverage cache; optional resident
  loading can be measured later. Do not read SD or rasterize fonts in an IRQ.
- Handle TrueType `glyf` and CFF as distinct outline formats. OpenType can use
  `.ttf` as well as `.otf`; the extension alone does not select a parser.
  Do not write an OTF-only path that rejects the intended BIZ UD TrueType face.

BIZ UD Gothic and Mincho are plausible candidates from their official OFL
repositories. Selection, exact pinned files, redistribution metadata and
microSD packaging will be done with the font-loader work. Cache arithmetic is
only a starting point: 512 24x24 masks at 4 bits need 144 KiB **per face**, before
metrics, padding, source caching and shaping. Measure actual SRAM/PSRAM use,
load latency and cache misses on-device rather than assuming those are free.

## Future inline Japanese input

Keep three contracts distinct: physical key events, committed UTF-8 text, and
input-method composition. Preedit text, caret/selection, underline/highlight
and candidate selection are temporary overlay state at the insertion point.
They are not appended to a log or document until committed; cancellation
restores the original committed text.

The ASCII diagnostic byte grid is intentionally not the editor's text model.
The future editor keeps UTF-8 plus character/cluster boundaries, and the
shaper returns glyph positions and text-to-glyph clusters. UTF-8 byte counts
are neither display columns nor caret movement. Combining dakuten, variation
selectors, full-width characters, proportional UD variants and fallback faces
need explicit tests. Allocate glyph IDs/code points broadly enough for
non-BMP text, rather than limiting the public interface to 16-bit characters.
Kana conversion/candidate dictionaries are an input-method layer; loading an
OpenType font does not itself implement Japanese conversion.

## Primary references

- [BIZ UD Gothic](https://github.com/googlefonts/morisawa-biz-ud-gothic)
- [BIZ UD Mincho](https://github.com/googlefonts/morisawa-biz-ud-mincho)
- [OpenType file/outline formats](https://learn.microsoft.com/en-us/typography/opentype/spec/otff)
- [FreeType custom memory and input streams](https://freetype.org/freetype2/docs/design/design-4.html)
- [HarfBuzz shaping and output](https://harfbuzz.github.io/shaping-and-shape-plans.html)

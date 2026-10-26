# Native console and boot diagnostics

## Decision and current scope

Use one boot journal as the source of truth for two views: the quiet inscription
and a detailed diagnostic console. Completion of real operations advances the
colour target; a frame/timer may smooth movement only towards that target.
An operation that never returns keeps its current stage visible. Colour is
not elapsed time, a percentage, or evidence that input/storage is ready.

The first implementation is an **opt-in read-only ASCII boot snapshot**, after
native memory/SMP/display qualification. It adds a CPU0-owned 2 KiB SRAM byte
ring, independent stage state, an 80x22 ASCII grid (15x30-pixel cells), and a fixed anti-aliased raster.
It shares the existing 720x1280 RGB565 buffer in keyboard landscape orientation.
The snapshot shows last completed/active stages and explicitly unavailable
storage/input. It is not an interactive shell or a live boot monitor.
The existing timed inscription remains the default display experiment;
connecting the milestone colour policy to an earlier display is a next gate.

```sh
NIHOS_NATIVE_CONSOLE=1 NIHOS_NATIVE_CONSOLE_PALETTE=1 \
  NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 \
  NIHOS_NATIVE_QUALIFICATION=1 sh tools/build-native.sh device integer
python3 tools/console/preview.py
python3 tools/console/preview.py --failed
# Palette: 0 = neutral body + muted teal heading, 1 = green, 2 = blue
# NIHOS_NATIVE_CONSOLE_PALETTE=1 selects pale green.
# NIHOS_NATIVE_CONSOLE_FONT=1 selects JetBrains, 2 selects Source Code Pro.
python3 tools/console/preview.py --palette green
python3 tools/console/preview.py --palette blue
python3 tools/console/preview.py --palette green --font source-code
```

The user found the first square VGA raster readable but too wide, and asked
for a different face at a larger size rather than stretched pixels. The current
candidates are **JetBrains Mono Medium at 24 px** and **Source Code Pro Medium at
25 px**, rasterized directly into 15x30 cells. Both keep exactly 80 columns
within 1280 pixels, with 40-pixel side margins. A compact seven-row header leaves
15 rows for the log. The user selected a pale green trial; the first row is
muted teal. Text labels carry status independently of colour.

Only printable ASCII masks are generated on the host; the full font file and
font engine are not linked. The selected face alone occupies immutable Flash:
10,761 bytes of JetBrains Mono coverage plus 380 bytes of glyph offsets, or
10,597 bytes of Source Code Pro coverage plus offsets. Native builds do not
require Pillow, font files or a filesystem. The source fonts, exact revisions,
SHA256 hashes and OFL notices are in
[the ASCII font provenance](../src/graphics/ascii/README.md). This does not
implement or embed the deferred Japanese UD faces.

The console option requires the full PSRAM display mode and remains off by
default. Its build retains the 48 KiB minimum SRAM heap, the existing image
regions/ROM allowlist and integer-only audit. The text-console module uses
ReleaseSmall to fit that existing SRAM budget; all other native modules keep
ReleaseSafe. Geometry/overflow rejection is explicit before pixel writes, and
host guard/stride tests also run with ReleaseSmall. The fixed ASCII font and
raster are independent of OpenType or an SD filesystem. Source provenance is
in [the font notice](../src/graphics/ascii/README.md).

CPU0 appends its diagnostic output while briefly masking local interrupts;
serial transmission itself is outside that critical section. CPU1 output
continues directly to serial and does not race the CPU0 journal/model. The
ring preserves newest bytes and reports loss; stage outcomes are separate and
cannot be overwritten by a verbose log. Snapshot construction uses the same
short ownership rule. Rasterization and cache writeback happen outside IRQs.
The boot/IRQ/task guards are checked again after presentation. A successful
serial console record proves construction/cache handoff, not optical legibility.

## Next integration: visible stages while boot runs

The current native fixture does all PSRAM tuning/full-memory tests before
panel preparation, and does the SMP/heap/IPI run before video starts. Merely
painting the final log would not diagnose a stop inside those earlier calls.
Integration must change the actual initialization order, with separate evidence:

1. Start the bounded SRAM journal/checkpoint model immediately after CRT.
2. Initialize the minimum memory/panel path and establish working scanout.
   Render the last completed stage and the next operation **before** entering
   that operation. Move destructive full-PSRAM tests before framebuffer use,
   or exclude/reserve live framebuffer pages explicitly. Never sweep live DMA
   pixels as if they were free memory.
3. Keep the DMA interrupt routed when CPU0 timer/IPI routes are reconfigured.
   Do not borrow a timer already driving the scheduler for panel delays.
4. Drive three dye targets from actual memory, core and console milestones;
   interpolate between them without delaying startup to meet a splash duration.
   A final colour target means those named milestones, not that all future
   devices, filesystems, networking or Japanese input are initialized.
5. Mirror the same events to serial and the view. Failure requests details;
   update the screen only if the cache/display path is known usable, retaining
   direct serial output for failures inside that path.

Before display bring-up, an on-screen console is physically unavailable.
A future SRAM-only framebuffer/scanline fallback needs its own scanout proof;
font independence alone does not remove dependence on PSRAM, DMA and DSI.
The new journal is volatile and is not a reset-persistent crash record. A small
validated RTC/reset-reason checkpoint is a separate future recovery feature.

## Diagnostic keys and recovery semantics

`Esc` should latch detailed output without throwing away the journal or
necessarily stopping startup. An explicit break request can pause **between**
operations at a safe checkpoint. Unknown keys should not consume a diagnostic
hotkey or accidentally execute a command. Do not turn an arbitrary HID report
into a character before keyboard layout/modifier decoding.

The state model implements capability-gated view/break requests, sticky
failures, and the distinction between a pending pause and a safe checkpoint.
**No native HID/serial key adapter or shell is wired yet.** The fixture must
not advertise a functioning Esc key or command prompt until one is installed.
The other native USB worktree currently supplies a CCID transport experiment,
not a decoded keyboard path. Reuse enumeration ownership when adding HID;
do not create a competing host-controller owner.

A key request cannot unwind a driver that has not returned. Bounded command
waits, cancellation points, and a scheduler/interrupt path that still runs are
necessary. A CPU deadlock with interrupts masked cannot guarantee key response.
Timeout/failure should preserve stage/error/last logs; a watchdog/reset path
and post-reset retained checkpoint cover a different class of failures. An
emergency monitor should initially expose inspection/status/controlled reset,
with command execution introduced only after normal task/input ownership.

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

# Incremental small console — 2026-10-27

Base `7f23b90`, isolated `codex/native-console` worktree. The user found the
previous console readable but observed flashing during scroll, and requested
the initial small font with somewhat lighter strokes.

[Device log](2026-10-27-native-console-scroll.log) and
[image/source/artifact receipt](2026-10-27-native-console-scroll.json).
Final candidate: `build/physical/console-scroll-03`, image SHA256
`5f45673f1e0605d08d3a78eeafb3b657619bdf1313bea737d163e61955747e0c`.

The candidate was installed under an exclusive serial lease, with two Flash
byte verifications. No backup or SD operations. Same ESP32-P4 rev1.3/ST7121
unit, 32 MiB PSRAM; PSRAM200 and calculated 59.982 Hz timing are unchanged.
Full memory/core/heap/stack/Flash/IPI qualification and all six serial controls
pass, with no captured DMA/DSI/bridge error or serial TX loss.

## Behaviour

- Font3 uses the original 760-byte 8x8 bitmap in 16x16 cells: 78x43 with 16-pixel
  margins. Exposed right/bottom stroke edges have half coverage, their shared
  corner quarter coverage. Glyph shape/advance and pale green palette remain.
  Font0 provides the original solid bitmap; large faces remain optional.
- The body retains its own text/cursor/scroll count and accepts boot output
  directly. The 2KiB journal no longer reconstructs every displayed update.
  Refreshing the fixed header does not move the append cursor or visible body.
- Changed cells update in place. Small-font body scrolling copies existing
  pixels over at most four observed-frame updates, painting only incoming
  pixels and the former cursor row. Later logs queue in a separate grid.
  Stage boundaries finish pending motion before publishing the next header.
- Small cells write background and foreground in one pass, with contiguous
  physical row writes. There is no full-screen or cell-blank pass before ink.
  Large optional faces use incremental cells without pixel interpolation.
- The renderer/three grids use the previously unused private tail at 0x481f2000.
  The 2MiB reservation and owner-heap boundaries remain unchanged. The final
  audited SRAM heap is 49,216 bytes, above the unchanged 48 KiB floor.

At READY, counters report 2 full view-entry paints, 34 partial updates, 32 scrolls
and 124 scroll steps. Full painting is also used for fatal-frame recovery;
ordinary updates never clear the full framebuffer. Cache damage is bounded,
with tall rectangles coalesced across physical row gaps. Presentation uses
16 KiB IRQ-off cache chunks; the initial full paint and mapper keep 1 KiB chunks.
The maximum measured presentation chunk is 29 us. Cache commands cannot nest
inside descriptor cache operations in the DMA ISR.

## Timing and limits

The first implementation measured 303,527us maximum per scroll step; coalesced
writeback/word copies reduced the next candidate to267,372us. The final
single-pass glyph implementation measured 241,431us, comprising separately
observed maxima 239,796us raster/copy and 21,729us cache presentation (these
maxima need not occur on the same step). For one/two-line shifts the measured
maximum was149,065us. These wall intervals include concurrent native scheduler
qualification and its worker preemption, and do not isolate CPU execution cost.

Therefore **60fps scrolling is not qualified**. The full-clear flashing cause
is removed, but heavy-boot latency still needs work. The source remains a
single framebuffer being scanned out; no tear-free atomic presentation is
claimed. User feedback on the current font and perceived scrolling is pending.
The panel's calculated refresh rate is independent of these content-update
times. No CPU clock or scheduling priority was changed for this experiment.

[Profile01 log](2026-10-27-native-console-scroll-profile-01.log) includes a
retained physical Tab5 Keyboard Esc event (`source=2 usage=0x29`) accepted
before UI_START, opening details. It proves the physical-key adapter consumed
an event; it does not time a new user keypress or qualify visual smoothness.
[Profile02 log](2026-10-27-native-console-scroll-profile-02.log) retains the
intermediate timing measurements. Their image/ELF/raw-log hashes and results
are included in the final receipt.

## Validation

205 Zig tests pass in Debug, ReleaseSafe and ReleaseSmall. They compare final
incremental pixels with fresh rasters for all four faces, test bounded motion,
queued updates, invalid buffers/overflow, header/guard/padding preservation,
fatal invalidation and retained append cursors. 137 Python tests pass, including
style/geometry, malformed counters, bounded IRQ windows, and physical Esc before
UI_START. ShellCheck, formatting and image/core/display evidence checks pass.
Default device/emulator and the optional large native face compile/link; the
default emulator result is a build check, not execution evidence.

Runtime source/data hashes match the retained build manifest. Only the selected
760-byte bitmap is linked; no runtime OpenType or Japanese UD font is added.

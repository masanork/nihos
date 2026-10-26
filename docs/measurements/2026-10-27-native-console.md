# Native diagnostic console checkpoint — 2026-10-27

Base: `24bbc08`, isolated branch `codex/native-console`. Each retained candidate
has its image/ELF SHA256, initial source-file digest manifest and immutable
Flash artifacts. The working tree was dirty while those images were built;
this is not a claim that the base commit alone generates them.

Physical unit: ESP32-P4 rev1.3, 32 MiB PSRAM, ST7121, MAC
`e8:f6:0a:e2:e8:9c`, serial `/dev/cu.usbmodem101`.

## Initial console

[Log](2026-10-27-native-console-initial.log) and
[audit/source/artifact/observation record](2026-10-27-native-console-initial.json).

The 78x43, 16x16-cell, public-domain VGA raster displayed actual CPU0 log bytes
and separately tracked boot stages after native qualification. The user said
`読めるよ。このフォントちょっと横長過ぎる気もするけど。` and asked about
muted green/blue. A stretched-cell host candidate was prepared but not flashed;
the user requested a different face at a larger size while retaining ~80 columns.

## Outline-derived ASCII trial

[Log](2026-10-27-native-console.log) and
[audit/source/artifact/result record](2026-10-27-native-console.json).

JetBrains Mono Medium is rasterized directly at 24 px, with 4-bit coverage,
into 15x30 cells: 80 columns by 22 rows, 40-pixel side margins. The user chose
a pale green trial. Native style readback is `font=1 palette=1`, foreground
RGB565 `a5f5`, heading `85b5`, background `1082`. Source Code Pro Medium at
25 px is also generated, host-previewed and cross-compiled, but not physically
qualified. This is pre-baked ASCII; it is not a runtime OpenType or Japanese
UD-font implementation. Sources/hashes/licenses are in the font provenance.

The installed JetBrains candidate passed unchanged integer/SRAM/ROM image
audits, two Flash byte verifications before final reset, full 32 MiB PSRAM
qualification, 300-round SMP/heap/IPI checks, display startup, and subsequent
IRQ frame 191 with no DSI/DMA/bridge errors. After raster/cache handoff, the
console rechecked stack guards and reported 80x22 cells and 2,048 retained
journal bytes. The SRAM owners each retain capacity `0x6700` bytes, keeping the
existing 48 KiB total minimum. The byte journal reports `0x2532` older bytes
discarded; stage outcomes survive independently of that ring.

Host validation passed 198 Zig tests in Debug, ReleaseSafe and ReleaseSmall,
and 126 Python tests. Default device/emulator and alternate-face ELF builds
also passed. Binary inspection confirmed only the selected face masks are
embedded; runtime source/data hashes match the retained build manifest.
Both fixed serial records and native log checkers passed. Optical confirmation
of the newest font is recorded separately in the JSON; the earlier readability
observation does not by itself qualify the new face. The calculated display
refresh remains 59.982 Hz; it has not become an optical cadence measurement.

## Limits and ownership

The journal starts during CRT and is CPU0-owned, protected against local IRQ
reentry. CPU1 continues serial output directly. The current screen is a final
read-only snapshot, not early live video, an interactive monitor, or a working
Esc/HID path. `input=0` is deliberate. Stage and pause-request host models do
not qualify a physical keyboard or recovery from an interrupt-disabled hang.
The existing default boot graphic still has its timed fade.

No SD/FS/font-file API was called or changed. Japanese UD font loading is
explicitly deferred until microSD/filesystem integration. Console source stays
separate from the concurrent filesystem and USB worktrees. Device installs use
one exclusive serial lease; the second candidate waited for another owner to
release its lease. No owner was killed, no Flash backup was made, and no SD
writes were performed. Raw capture/verify/ELF/binary files remain in
`build/physical/console-01/` and `build/physical/console-02-jetbrains-green/`.
Checked-in serial logs normalize CRLF to LF.

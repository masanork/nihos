# Graphics and launcher main landing, 2026-10-28

The integration preserves the ordinary C6, device commands, touch/card UI,
read-only VFS and SDMMC services from main. Boot settles into the launcher;
Esc enters the bounded shell, and `launcher`/`exit` returns to the launcher.
Console/session objects and network state occupy distinct parts of the display's
existing PSRAM reservation.

The opt-in graphics image is a separate offscreen qualification profile. It
cannot combine its private stack/data banks with the display, networking,
USB, SDMMC, normal storage or broker/high-SRAM fixtures. Full pinned BIZ UD fonts,
FreeType and HarfBuzz are experimental Flash inputs, rather than a resident
service installed in ordinary boot.

## Verification

* Zig Debug and ReleaseSafe: 697 tests each after the storage-core main refresh.
* Python: 446 tests; static analysis and all six SDK-free native links/audits.
* Normal boot: eight headless emulator readiness, idle and failure cases.
* Fresh sanitized host shaping: text metadata, all four composition variants,
  vertical text, Japanese break policy and ruby match the independent references.
* Native emulator: reference pixels, task-only Flash preemption, queue ownership,
  complete heap recovery and two exclusive stack-bank loans.
* Tab5: three warm USB RTS resets of the exact graphics image, verified before
  each capture and after the series, with the same strict pixel/ownership checks.
* Tab5 ordinary boot: launcher, Esc, help, memory/tasks, launcher return, legacy
  `:devices` and `:storage`, with image verification before and after the run.

The physical reader has no recognized FAT/exFAT volume: initial admission and
retry return `NIH_VOLUME_NOT_FOUND` (-262). This confirms bounded rejection while
UI/input and C6 transport continue; it does not qualify successful mount/read,
Wi-Fi connectivity, physical touch, optical glyph appearance or cold power-on.
Library restart remains a host-driven RV32 ISA experiment with negative controls,
not a native restart implementation. SDL and SD/VFS-loaded fonts remain deferred.

Ordinary boot reserves 58,368 bytes of primary internal heap. The linker and image
auditor still enforce the 49,152-byte floor. Large network State/decoder reset
templates now reside in existing read-only mapped Flash rather than duplicate
SRAM constants; their default values and reset behavior are preserved. This is
a static allocation result, distinct from the per-owner free bytes printed by
`mem`. Font-task heaps/queues/canvases are demand-owned; the experiment's 32 KiB
stack and 32 KiB library-data banks are separate explicit reservations.

Both hardware write ownership and the serial descriptor were held across backup,
installation, verification, capture and restoration. The original full 16 MiB
Flash backup was restored and verified, followed by its original card-scene boot.
Failed and superseded attempts remain in the local landing build directory;
the retained public receipt identifies the successful exact candidates only.
The original dirty main worktree's HEAD, status and file contents were preserved.

[Exact candidate receipts and evidence](2026-10-28-graphics-main-landing.json).

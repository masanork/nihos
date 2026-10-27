# Demand-allocated graphics memory experiment

This independent host probe tests the user's requirement that Japanese text
support acquire memory when needed, return client memory on close, and allow
multiple applications to stay open. It does not reserve the previous 2/6/8 MiB
design budgets at boot and does not add a GUI to native firmware.

Run from the repository root on macOS or Linux with CMake, a C++17 compiler,
Python 3 and curl:

```sh
sh tools/run-graphics-memory-probe.sh
```

The script downloads checksum-pinned sources, fonts and license notices into
ignored `build/graphics-probe/sources`, builds static libraries with ASan/UBSan
enabled by default, and writes `build/graphics-probe/report.json` only after
every check succeeds. A failed run removes the previous receipt. The binary
never reads a serial port, writes firmware, or modifies an SD card.

Optional controller-size compilation with an installed RV32 compiler:

```sh
NIHOS_GRAPHICS_RV32_CXX=/path/to/riscv32-esp-elf-g++ \
  sh tools/run-graphics-memory-probe.sh
```

That compiles `metadata_size.cpp` and records `sizeof(LazyPool)` for ILP32.
It neither compiles the POSIX backing implementation for nihos nor runs on P4.

## What is exercised

- FreeType 2.14.3 and HarfBuzz 15.0.0 render real BIZ UD Gothic and Mincho
  glyphs with horizontal/vertical shaping and alternating 24 px body/12 px
  ruby-sized runs. This is glyph rendering, not ruby placement or paragraph
  composition. Script/language are fixed Japanese fixtures, not itemization.
- Two sessions remain open together. Closing one returns all its FreeType
  and source-cache backing while the other produces the same pixels and
  advances. Library calls run on one serialized worker; applications are
  not mutually exclusive. Parallel threads are outside this experiment.
- Every allocation attempt in a warm second-session open/draw/close workload
  is individually failed. Failure never publishes a candidate, the second
  client's backing returns to zero, and the surviving client still draws
  exactly the baseline result. The whole workload succeeds again afterward.
- An unrelated owner holds 1 MiB under the same 2 MiB global limit. Opening
  the second font session fails cleanly, the existing session and unrelated
  bytes survive, and releasing that allocation permits the session to reopen.
- Pool checks cover foreign/interior/invalid/double frees, 16-byte alignment,
  metadata exhaustion, quota refusal, positive realloc failure preserving
  all usable old bytes, and 3,000 interleaved allocate/resize/free operations.

## Allocation and lifetime rules

`LazyPool` requests backing in 64 KiB multiples only when no existing owned
span has a suitable gap. Empty spans are returned immediately. Requests are
16-byte aligned, and moved reallocs reserve the destination before releasing
the source. Fixed metadata authenticates an exact pointer before dereferencing
payload; the probe does not read a header through an arbitrary supplied pointer.
Pointers still cannot distinguish stale addresses after address reuse.

The 2 MiB global and 1 MiB per-client limits are refusal thresholds, not
reservations. The service owner has a 512 KiB cap. Two clients have independent
lifetimes and cannot free each other's allocations. Backing pages are not lent
between owners while live objects remain in them. These IDs are probe lifetime
tags, not native scheduler identities or memory isolation.

All HarfBuzz allocations use a long-lived service owner because some state
survives face/font destruction. FreeType callbacks and each 256 KiB stream
cache belong to their client. Closing a client destroys its library objects
before returning its spans. The service's remaining process-global allocations
are retained; forced service-task cleanup/restart remains unqualified.

The host backend uses `posix_memalign/free`. A native version still needs a
backing/ownership design compatible with the current two-parent task ledger;
requesting each page as a separate current task allocation would exceed it.
The bounded metadata scan is a host prototype, not an interrupt-latency proof.
This implementation does not replace `nih_task_malloc` or any libc symbol.

## Measurement scope

The recorded 2026-10-27 fixture has these **host backing requests**:

| State | Backing |
| --- | ---: |
| Before first library use | 0 |
| One session open after body/ruby rendering | 640 KiB |
| Two sessions, normal-workload peak | 1,280 KiB |
| Two sessions, allocation-failure workload peak | 1,664 KiB |
| After closing the second session | 640 KiB |
| After closing both sessions | 64 KiB service backing |

The last 64 KiB holds 1,415 requested live library bytes in this fixture;
it is not claimed to be entirely returned or bounded for arbitrary languages,
font collections, and features. Fixed controller storage, libc FILE buffers,
stack, code/rodata, OS file cache, and sanitizer overhead are outside this table.
The controller is separately reported for host and optionally RV32.

No application glyph bitmap cache, layout snapshots, document/undo data,
candidate RGB565 frame, SDL backend or display scanout is included. These
measurements cannot establish the complete reader/editor footprint, native
RAM use, SD latency, or physical-device qualification.

The receipt, including exact source hashes, is retained in
[`docs/measurements/2026-10-27-graphics-demand-memory.json`](../../docs/measurements/2026-10-27-graphics-demand-memory.json).

## Sources and attribution

All upstream revisions, downloads and SHA-256 pins are in `sources.json` and
the repository `provenance.toml`. No MeOS driver source is imported.

- FreeType is used under the FreeType License (FTL). Portions of this software
  are copyright © 2026 The FreeType Project (www.freetype.org).
  All rights reserved. The original license and source files remain in the
  download cache. The only upstream source configuration change selects the
  autofit, TrueType, sfnt and smooth modules in `ftmodule.h`.
- HarfBuzz is MIT licensed; its source and `COPYING` are retained. The custom
  configuration keeps Unicode, GSUB/GPOS and vertical support for static
  TrueType fonts. CFF, variable fonts, AAT, Graphite, color, SVG and math are
  outside the profile. `HB_NO_MT` requires the single-worker discipline.
- The unmodified BIZ UD Gothic and Mincho fonts are OFL-1.1 licensed. Both
  original OFL notices are downloaded and retained beside the font files.

The next native gate is backing ownership, RV32 allocation/stack behavior and
library lifetime under failure, followed by shared layout and presentation.

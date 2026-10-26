# 0032: Loader-mapped read-only diagnostic tables

Status: accepted for native emulation; physical qualification pending, 2026-10-26.

## Decision and source boundary

Use the existing second Flash mapping for normal diagnostic record tables.
The first mapping still contains the 256-byte application descriptor at
`0x40000020`. Replace the second mapping's unused four-byte marker with
self-contained tables at `0x40010020`, bounded by the end of that 64 KiB page.
All executable code, ordinary constants, mutable data, stacks, allocator
metadata and trap state remain in the existing revision-specific SRAM region.
This is read-only mapped data, not execution of instructions from Flash.

Pinned ESP-IDF v5.4.4
[memory definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/ld/esp32p4/memory.ld.in)
place normal Flash D/I mappings at `0x40000020`. The shared-address branch of
[the loader](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader_support/src/bootloader_utility.c)
requires exactly two external mapped segments, maps them through Flash MMU0,
enables the cache buses for both harts and enters the app. Retain that setup.
No native Flash-controller initialization, map replacement, cache resize or
new ROM ABI is introduced. PSRAM startup still changes only MSPI2/MMU1 and
retains the loader's shared-cache configuration.

## Self-contained tables

`PlacedWriter` accepts an optional compile-time linker section; the ordinary
`Writer` uses the target's default read-only placement, including Mach-O host
builds. Native normal logging selects `.flash.rodata.records`. Error/trap
logging keeps its direct SRAM console path and ordinary SRAM literals.

Markers and field names are compile-time text. Each table contains one text
array and six-byte descriptors: u16 name offset, u16 name length and u16
record-field offset. There are no embedded string pointers or mutable cursors.
Copies of names in distinct tables cost Flash space rather than SRAM. The
shared emitter borrows a typed snapshot and indexes those bounded tables;
the emitter and sink remain SRAM code. Existing explicit field ordering,
actual struct offsets, u32 type/alignment and no-allocation contracts remain.
An oversized combined marker/name extent fails compilation before truncation.

## Image and runtime gates

The linker emits `__flash_records_start/end` and bounds the section to
`[0x40010020, 0x40020000)`. The ELF audit allows only the two named Flash
sections outside SRAM, requires read-only PROGBITS and rejects duplicates,
writes, executable flags, wrong addresses and oversized extents. All function
symbols and executable sections still have to reside in SRAM or match the
six known ROM functions. The 48 KiB internal heap and stack gates remain.

Full image audits require exactly the two mapped image segments in order.
Both ELF and image descriptors must explicitly select 64 KiB MMU pages.
Their image data offsets must match their virtual offsets modulo 64 KiB.
The factory app offset remains `0x10000`, so the congruence also holds for
physical Flash addresses. The second segment's bytes must match its ELF
contents, allowing only image-format rounding to four bytes. Retain an
ELF SHA256 and a table FNV-1a checksum in the image audit.

Each hart reads every table byte through volatile loads at startup and again
after the 300-round preemption/lifecycle and IPI-only idle protocol. CPU0's
initial read precedes PSRAM setup; CPU1's follows its release. Each final read
precedes the existing final memory publication. A changed checksum fails
before success publication. Owner reports use release/acquire completion.

`NIHOS_NATIVE_FLASH` must contain both owners, the bounded start/end/length,
equal initial/final checksums, exactly twice-length checked bytes and a
confirmed final state. Both hart reports must agree. Normal smoke scripts
also supply the just-built image audit to the log validator: runtime length,
addresses and checksum must match that ELF. The smoke report retains that
ELF digest rather than inferring its binding from a later per-mode build.
Every smoke case, including `psram-0`, snapshots its ELF, app/merged image,
linker layout and audit before running the emulator from those snapshots.
CI retains them alongside the case's log/report. Same-source rebuilds can
change Zig's generated builtin cache path in `.debug_line`; all other ELF
sections were equal in the inspected pair. Do not assume one final per-mode
ELF digest applies to every earlier case. Generated option files are now
updated only when their contents change, but deterministic ELF output is
not a requirement or claim of this stage.
FNV-1a detects fixture data/mapping mistakes; it is not authentication or
a cryptographic attestation of the running executable.

## Budget and qualification

Record net resident changes, including added probe/report code and state.
Moving roughly 2 KiB of tables does not imply the same SRAM saving. The
Flash image grows because the previously padded second page now contains
useful data. Keep the same safe compilation, stacks, heap minimum, task quota,
cache size and clock policies. Re-run all nine existing emulator cases and
both revision profiles' three image modes.

Host tests check pointer-free relative table layout and empty schemas in
addition to the original formatting/layout checks. Compiler-negative tests
cover combined-text overflow along with the five existing schema classes.
Python tests reject invalid Flash section flags/kind/ranges, inconsistent
or incomplete owner records and mismatches against the image audit; known
FNV-1a vectors fix the host checksum algorithm.

## Remaining boundary

Normal diagnostics now require a live inherited Flash mapping and cache.
There is no Flash erase/program path or cache-off scheduler protocol yet.
Such a path must quiesce normal logging and other external-memory consumers,
preserve a fully resident critical path, and separately qualify both harts'
cache/interrupt behavior. This stage does not establish such a protocol.
No trap handler is permitted to call the placed record writer while that
dependency is unavailable. Existing direct trap/error diagnostics stay resident.

Full-range reads plus the existing workload demonstrate coexistence in the
emulator, not physical cache-miss latency, bus contention or exhaustive cache
eviction behavior. No hardware, Flash write, DMA or power-failure result is
claimed. General Flash code execution and large immutable assets remain
future placements requiring their own section/critical-path contracts.

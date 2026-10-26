# Native read-only Flash record tables

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source manifest, six image audits and nine bound smoke reports](2026-10-26-native-flash-records.json)
- [ADR 0032](../adr/0032-loader-mapped-read-only-record-tables.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result

Normal diagnostic schemas now occupy 1,986 bytes of read-only mapped Flash
at `0x40010020..0x400107e2`. Each schema contains inline marker/name text
and relative u16 descriptors, with no string pointers. Native code, ordinary
constants, mutable state, stacks and direct error/trap output remain in SRAM.
The Flash controller, cache sizing, clocks and six ROM ABI entries are unchanged.

Each hart read every table byte at startup and after the complete workload.
Initial and final FNV-1a values were `0x62976302` on both harts, matching
the bytes in the audited ELF, with 3,972 checked bytes per hart. CPU0's first
read precedes PSRAM setup; the final reads follow scheduling, allocation,
PSRAM churn and IPI-only idle. All nine cases required this evidence together
with the earlier native gates. This demonstrates mapped-data coexistence in
the emulator; it is not a physical cache-miss, bus-latency or FPS measurement.

## Net footprint

Both revision profiles have identical relative sizes. Baseline `dcf604b`
uses its preceding source-bound task-pool measurement; its six image audits
were not rebuilt or replaced for this comparison. The JSON records the
baseline evidence path/digest and all current image/loader/config digests.

| Mode | Previous static SRAM | Current static SRAM | Net reduction | Internal heap | Margin above 48 KiB gate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 109,184 B | 108,288 B | 896 B | 55,552 B | 6,400 B |
| Raw FP | 113,216 B | 112,448 B | 768 B | 51,392 B | 2,240 B |
| Compiled FP | 113,472 B | 112,832 B | 640 B | 51,008 B | 1,856 B |

The measured net saving includes new checksum/report code, state and
alignment. It is smaller than the Flash table size. Static SRAM includes
all stacks and alignment. The resident region remains 160 KiB, the internal
heap minimum 48 KiB, bootstrap/interrupt stacks four times 8 KiB and worker
stacks two times three times 4 KiB. Safe compilation and task quotas remain.
This modest saving does not remove the need to budget future code growth.

The app image grew from 65,616 to 67,600 bytes in all modes. Its second mapped
segment still starts at image offset 65,568 (`0x10020`), but now contains
1,986 useful table bytes plus format rounding. With the factory app offset
`0x10000`, that segment's Flash data starts at `0x20020`; virtual and physical
offsets agree within the explicit 64 KiB MMU pages. The image audits require
ELF and image descriptors to select that page size, exactly two mapped segments,
matching offsets and exact table contents from the ELF.

## Qualification

All 119 host tests passed in Debug and ReleaseSafe. The two new tests require
six-byte pointer-free descriptors with inline marker/name text and correct
empty-schema output. The prior ordering, full-value and mixed-layout tests
also pass. All 70 Python tests passed: 57 log, 11 image and two compiler tests.
The compiler tests reject six schema classes, including combined text beyond
the u16 bound. Image tests reject writable/executable/NOBITS or out-of-range
Flash sections and wrong descriptor MMU page sizes, and check known FNV-1a
vectors. Log tests reject missing/duplicate owners, changed contents, partial
reads and content differing from the image audit.

ZLint, ShellCheck, six architecture ELF/instruction audits and six full image
audits passed. Every runtime executable remains SRAM-resident; only the
bounded read-only tables and app descriptor are allowed outside SRAM. Full
audits still check actual loader allocation collisions and cache/revision
configuration. All nine emulator cases passed: integer with absent/4/8/16/
32/64 MiB PSRAM, raw FP without a die, and compiled FP with absent/32 MiB.
The same scheduling, FP, lifecycle/forced exit, IPI-only idle, SRAM, PSRAM
mapping/cache/command, heap recovery and task-pool gates remain required.

Smoke scripts now supply their just-built image audit to the log validator.
Each case snapshots and executes its own ELF/app/merged image, retaining its
audit/layout and log/report under `psram-SIZE/`, including `psram-0/`. This
matters because same-source rebuilds changed a generated builtin cache path
in `.debug_line`; other ELF sections in the inspected pair were identical.
The saved ELF digest, rather than the last per-mode digest, binds each run.
All nine saved ELF/app pairs passed image auditing again, and every allocated
ELF section's contents matched the final image of its mode. Runtime SRAM
owner spans also matched each saved image's heap partition.
Generated option files are updated only on content changes; deterministic
build output is not claimed. Each retained report checks the Flash table
content and is verified against its runtime SRAM heap spans. Table FNV-1a
is a mapping/data check, not executable authentication or a cryptographic
in-guest attestation.

## Evidence boundary

Baseline ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40257332079)
both succeeded. Current remote CI is separate from these local results.
No physical device was accessed. Normal placed logging requires the retained
Flash mapping and cache. No erase/program implementation, cache-off SMP
protocol, executable Flash placement, exhaustive eviction, DMA, power-failure
or silicon timing result is claimed. Those boundaries must be established
before expanding this mapped-data use to mutable Flash operations or code.

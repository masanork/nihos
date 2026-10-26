# Native resident SRAM budget and revision layout

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Before/after image audits, loader/config digests and nine smoke reports](2026-10-26-native-sram-budget.json)
- [ADR 0030](../adr/0030-revision-aware-native-sram-budget.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result and attribution

Both revision profiles produced the same relative resource sizes. Baseline
is `c32b863a679c35cea623ceab678882c72f00feea`; its six archived ELF/audit pairs
were checked against the preceding source-bound measurement JSON.

| Mode | Previous static SRAM | Current static SRAM | Resident reduction | Previous internal heap | Current internal heap |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 108,480 B | 106,944 B | 1,536 B | 22,592 B | 56,896 B |
| Raw FP | 112,704 B | 111,168 B | 1,536 B | 18,368 B | 52,672 B |
| Compiled FP | 112,832 B | 111,424 B | 1,408 B | 18,240 B | 52,416 B |

The region grew by 32,768 bytes. Heap growth is exactly that addition plus
the smaller resident footprint: 34,304 bytes in integer/raw FP and 34,176
in compiled FP. The large gain is not attributed to code compression alone.
Static SRAM includes all stacks and alignment, not just text. Shared report
descriptors consume read-only bytes; savings above are net of those tables.

Bootstrap and interrupt stacks remain four times 8 KiB; worker stacks remain
two times three times 4 KiB. Safety mode remains `safe`. After the existing
448-byte SRAM fixture allocations and guards, free space per owner was
27,840 bytes in integer, 25,728 in raw FP and 25,600 in compiled FP. An odd
trailing 64-byte granule remains unused when partitioning the heap equally.

The linker and ELF minimum is now 48 KiB, up from 16 KiB. The tightest mode
has 3,264 bytes of remaining static-growth margin above that stronger gate.
Further code growth still needs budget/layout work, such as separately
qualified Flash XIP or additional banks. All app images remain 65,616 bytes
because compatibility-segment padding is unchanged.

## Layout and actual loader evidence

| Profile | Current resident region | Nearest higher live loader section | Gap |
| --- | --- | --- | ---: |
| Device, rev1/2 | `0x4ff00000..0x4ff28000` | `0x4ff2abd0` | 11,216 B |
| Emulator, rev3 | `0x4ff20000..0x4ff48000` | `0x4ffac2c0` | 410,304 B |

The rev3 profile now respects the first 128 KiB cache-prefix exclusion from
the pinned application linker definition. Earlier rev3 emulation used the
early-silicon origin and did not establish physical cache-bank availability.
The early-silicon end also leaves 5,816 bytes before the ROM shared-buffer
start documented in the pinned loader script. No loader, ROM or cache bank
was reclaimed or resized.

Every full-image audit inspects all allocated sections in its actual stock
loader ELF, including NOBITS/BSS, for overlap with the entire native region.
It also requires generated loader configuration to select the correct
silicon group, 128 KiB L2 cache and 64-byte lines. The JSON records exact
loader and configuration digests. Native CI retains those artifacts and
the preprocessed per-profile linker scripts for review.

## Qualification

All nine final smoke cases passed: integer with absent/4/8/16/32/64 MiB,
raw FP without a die, and compiled FP without a die and with 32 MiB. Each
completed the earlier 300-round scheduler, task lifecycle/forced exit,
IPI-only idle, FP, owned SRAM, PSRAM mapping/cache/command, reusable heap
and deferred resource cleanup gates. SRAM reports used the revised rev3
region, and all runtime owner spans matched their audited ELF heap partition.
These are execution/resource results, not FPS or latency measurements.

All 110 host tests passed in Debug and ReleaseSafe. Two new tests require
exact record ordering/full u32 values and actual field offsets in a mixed
layout. All 61 Python tests passed: 52 log, eight image/layout/loader tests,
and one compiler test covering five invalid schema classes. Wrong value
types, packed/comptime fields, underaligned pointers and oversized offsets
must fail compilation. Loader tests inject either-edge/NOBITS overlaps,
missing allocations and cache/revision mismatches. ZLint, ShellCheck, six
architecture links/instruction audits and six full Flash image audits passed.

Normal diagnostics use one sink-specific loop and bounded compile-time
descriptors. No formatter allocation was introduced. Error/trap diagnostics
still use the direct console path. Startup-only PSRAM preparation is kept
out of line with a cold hint; no polling budget, cache/frequency policy or
safety check was relaxed. Scheduler and allocation ownership logic are
unchanged.

## Evidence boundary

The preceding main commit passed ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40251837082).
Those results qualify the baseline; current remote CI is separate from the
local results here. No physical device was accessed. Silicon cache topology,
cell coverage, DMA suitability, interrupt latency, retention and power timing
remain unqualified. The profile correction and source-derived boundaries
require physical verification before making a hardware RAM-availability claim.

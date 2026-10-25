# 0027: Full PSRAM mapping and owner-local external boot arenas

Status: accepted for native emulation, 2026-10-26.

## Address layout

Extend ADR 0026's exclusive boot-time mapping to the detected 4–64 MiB
capacity. The 64 KiB page size and MMU1 target/valid encoding still follow
the pinned ESP-IDF v5.4.4
[MMU LL](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/mmu_ll.h)
and [external memory definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/include/soc/ext_mem_defs.h).
Flash MMU0 and loader cache geometry remain unchanged. All 1,024 entries
are written/read back; only `capacity / 65536` entries are valid.

Preserve the first three nonidentity test windows. Complete their page
permutation rather than creating aliases:

| Virtual page | Physical page |
| --- | --- |
| 0 | 0 |
| 1 | Half the page count |
| 2 | Final page |
| Half the page count | 1 |
| Final page | 2 |
| All other pages | Same page number |

Every physical page appears exactly once. The first 192 KiB stays reserved
for CPU/command and cross-core checks. The contiguous virtual tail
`[0x48030000, 0x48000000 + capacity)` is divided equally between two owners.
Each partition excludes a 64-byte guard at each end; registered usable
bytes are therefore `capacity - 196608 - 256`. All pointers describe normal
cached CPU memory, with no physical contiguity or DMA guarantee.

## Ownership transfer

CPU0 maps before CPU1 release. Both bootstraps complete the existing
64-round payload protocol. CPU1 publishes the end of its external accesses
and waits on a new internal-SRAM release word. CPU0 completes cache
writeback/physical-command checks, initializes external arena guards and
internal owner descriptors, allocates its bootstrap buffer and releases
CPU1. CPU1 allocates its bootstrap buffer before starting its scheduler.
No global cache maintenance occurs while external workers run.

Both domains reuse the same native `Domain` implementation and existing
host-tested `CoreArena`. `alloc` selects SRAM, `allocExternal` selects PSRAM.
Both derive the owner from `mhartid`, mask local interrupts only around
the monotonic cursor update and restore the caller's MIE state. There is
no shared heap lock, cross-domain fallback, free or reset. Interrupt handlers
do not allocate. An absent die never registers external storage and must
reject an external allocation request.

Descriptors, task/interrupt stacks and lifecycle state stay internal.
This remains machine-mode ownership discipline, without task isolation.
The external API is an explicit boot-allocation step; reusable allocation,
cross-core frees, application lifetimes and C/SQLite allocator adapters
remain subsequent work.

## Qualification and footprint

Each owner allocates 64 bootstrap bytes plus two 65,728-byte worker buffers
in PSRAM: 131,520 bytes consumed per owner. Worker buffers cross 64 KiB page
boundaries and are filled while preemptible. The pattern includes page-offset
bits as well as hart/worker identity; it is not a repeated 256-byte pattern.
Workers sample their buffers continuously, and after retirement each owner
checks every byte, alignment and guards. Invalid length, alignment and
oversized requests must leave its cursor unchanged, with MIE preserved.

Final internal completion is published only after external verification.
An exploratory run exposed the earlier ordering error: CPU0 could observe
CPU1's internal completion before the longer external scan/report finished.
The validator rejected the zero external record. Checking and publishing
the external domain first makes internal completion cover both domains.

Host tests check the full page permutation for every supported density,
including uniqueness, displaced pages, capacity bounds and failure in a
late PTE. The cache model retains the earlier missing-writeback/invalidate,
identity-map and command-failure cases. Native validators require two
external owners with exact tail coverage, guard deductions and usage;
missing/duplicate reports, reserved-page overlap, incorrect capacity or
absent-die allocation cannot pass. All earlier scheduler, IPI, FP and SRAM
gates remain required.

Common allocation/verification and diagnostic output functions are kept
out of line to share code. The conservative 128 KiB SRAM window, four
8 KiB bootstrap/interrupt stacks and 16 KiB minimum internal heap gate are
preserved. No PSRAM access or allocation was added to the trap handler.

Emulation verifies the boot/ownership protocol and selected data accesses;
it is not an exhaustive memory-cell test or silicon qualification. The
conservative x8 controller policy, explicit cache ROM ABI and unbounded
internal ROM waits remain as in ADR 0026. Physical voltage/timing,
coherency, DMA, retention and high-speed tuning still require hardware.

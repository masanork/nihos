# Native separate internal-SRAM stack region

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source/layout manifests, image audits and exact case evidence](2026-10-26-native-stack-region.json)
- [ADR 0035](../adr/0035-separate-internal-sram-stack-region.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result and attribution

Four 8 KiB bootstrap/IRQ reservations and six 4 KiB worker reservations now
occupy one 56 KiB NOBITS internal-SRAM span at `0x4ff60000..0x4ff6e000`.
Reservation sizes are retained. Bootstrap stacks gain 16-byte bottom guards;
IRQ/task guards keep their prior size. The primary 160 KiB bounds and 48 KiB
heap minimum remain unchanged. No stack uses PSRAM and no new Flash function
is permitted.

Both profiles produced the following sizes. Baseline `32935d1` uses the
preceding source-bound slab measurement; the JSON identifies that evidence
and its digest. Those baseline images were not rebuilt in this stage.

| Mode | Previous total static | Current primary static | Separate stacks | Current total static | Internal heap | Heap gain |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Integer | 110,080 B | 54,528 B | 57,344 B | 111,872 B | 109,312 B | 55,552 B |
| Raw FP | 114,112 B | 58,688 B | 57,344 B | 116,032 B | 105,152 B | 55,424 B |
| Compiled FP | 114,496 B | 59,072 B | 57,344 B | 116,416 B | 104,768 B | 55,424 B |

Total controlled SRAM increased from 163,840 to 221,184 bytes (160 to 216 KiB).
Static use increased by 1,792 bytes in integer and 1,920 in the FP modes,
including observations, guards, startup checks and alignment. Heap gain is
exactly the added 57,344 bytes minus that increase. It is not a reduction in
total resident footprint. The tightest heap now has 55,616 bytes of headroom
above the existing minimum, compared with the baseline's 192 bytes.

After existing arena allocations and guards, internal free bytes per owner
were 54,080 in integer, 51,968 in raw FP and 51,776 in compiled FP. Primary
heap partitioning and its unused trailing granule follow the same rules as
before. Unused high SRAM, ROM and cache reservations are not registered as heap.

## Source and actual loader evidence

The clean pinned SDK checkout and tag both resolve to
`296b6eab9445fd720e71aecab961e2d3fbca9944`. The JSON records hashes of the
application memory definitions and both revision loader scripts, verified
against that tag. With the retained 128 KiB cache, the early-silicon source
high window is `0x4ff40000..0x4ffa0000`; rev3's source window is
`0x4ff20000..0x4ffaefc0`. The selected stack span is within both and outside
the complete primary/ROM gap. The cache size and 64-byte lines are unchanged.

| Profile | Primary region | Stack region | Nearest actual loader separation from stack span |
| --- | --- | --- | --- |
| Rev1/2 device | `0x4ff00000..0x4ff28000` | `0x4ff60000..0x4ff6e000` | 176,396 B below its start |
| Rev3 emulator | `0x4ff20000..0x4ff48000` | `0x4ff60000..0x4ff6e000` | 254,656 B above its end |

Every full audit checks all actual allocated loader sections, including
NOBITS, against both entire native spans. Loader allocations in the intervening
hole remain legal. Primary-region loader gaps remain 11,216 B for early
silicon and 410,304 B for rev3. ELF checks require all stack boundaries, the
24 KiB task-array symbol/size and writable, non-executable NOBITS permissions.
These are source/build facts rather than physical RAM qualification.

## Runtime evidence and tests

CPU0 assembly zeroes the full stack span before choosing its native SP and
releasing CPU1. Each hart then checks 20,480 IRQ/task bytes are zero before
initializing their guards. The already-live bootstrap stack is excluded from
that scan. The common dispatcher validates owned/aligned captured frames,
saved SP equals frame plus 128 bytes, and the current IRQ SP. Both harts must
observe bootstrap, IRQ and all three physical task-stack categories. At final
publication, bootstrap, IRQ and worker guards are checked again.

These minima are observed frame locations/dispatcher SPs; they are not
complete peak-stack or worst-case headroom measurements. Reports freeze under
the local mask and use release/acquire publication. Log validation binds the
reported stack extents and both runtime heap-owner spans to the exact audited
case image. Initial/final Flash table reads still match; the table is now
2,368 bytes with FNV-1a `0xd9415711`. App images are 67,984 B. The same two
Flash boot roles and their per-image instruction/PC gates remain required.

All 134 host tests passed in Debug and ReleaseSafe. Three new tests cover
the ten disjoint reservations, owned/aligned samples, minima, saved-SP
relationships, wrong cores, arithmetic overflow and unchanged state after
rejection. All 83 Python tests passed: 64 log, 17 image and two compiler tests.
New mutations cover missing/duplicate samples, wrong dimensions, lost zero
checks, cross-stack samples and audited heap/stack mismatches. Image tests
cover all linker symbols, task-array size, section permissions and collisions
with either edge of the new bank, including loader NOBITS allocations.

ZLint, ShellCheck, six architecture ELF/instruction audits, six full profile
image audits and all nine final emulator cases passed. Cases are integer with
absent/4/8/16/32/64 MiB, raw FP without a die, and compiled FP with absent/
32 MiB PSRAM. All earlier 300-round SMP/FP, lifecycle/forced exit, IPI-only idle,
SRAM, PSRAM/cache/command, heap recovery, monotonic-pool and slab gates remain.
Each case retains and executes its own ELF/app/merged image/layout/audit and
log/report. All saved pairs passed audit again; allocated ELF contents match
the final image of the same mode.

## Evidence boundary

Baseline ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40266807111)
both succeeded. Current remote CI is separate from these local results.
No physical device was accessed. Source-defined availability plus emulated
frame/zero/guard checks do not qualify physical bank/ECC behavior, every SRAM
cell, cache-off operation, DMA, power loss or retention. No latency or FPS
improvement is claimed. Physical Tab5 qualification remains a distinct gate.

# Native task-owned monotonic pools

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source manifest, six image audits and nine smoke reports](2026-10-26-native-task-pools.json)
- [ADR 0031](../adr/0031-task-owned-monotonic-pools.md)
- Reproduce: `sh tools/run-native-smoke.sh compiled 32M` and `sh tools/build-native.sh device compiled`.

## Result

Both harts allocated small objects through task-owned pools while preserving
the existing parent quota and deferred task cleanup. Each populated run
required 18 successful child allocations and six pool rejections per hart.
Copied handles shared the canonical SRAM cursor. Aligned child extents were
distinct and their stored contents passed volatile reads. Exhaustion and a
closed parent's old ticket were rejected with interrupts restored.

Each of two normal lifecycle tasks and one forcibly terminated blocked task
deliberately retained one pool and one ordinary parent. Existing cleanup
released those six parents plus the two busy workers' final allocations:
eight recovered handles per hart, zero outstanding handles or pending closes.
The heap subsequently exhausted and fully recovered its usable capacity.
No-PSRAM runs completed the same lifecycle protocol with zero pool work and
zero reclaimed parents. These are allocation/lifetime results, not latency
or game-performance measurements.

## SRAM budget

Both revision profiles produced the same relative sizes. Comparison uses the
six source-bound audits already recorded for baseline `7eb324e`; the JSON
identifies that preceding measurement and its digest. No baseline was
recompiled or inferred from a different source revision for this report.

| Mode | Previous static SRAM | Current static SRAM | Increase | Internal heap | Margin above 48 KiB gate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 106,944 B | 109,184 B | 2,240 B | 54,656 B | 5,504 B |
| Raw FP | 111,168 B | 113,216 B | 2,048 B | 50,624 B | 1,472 B |
| Compiled FP | 111,424 B | 113,472 B | 2,048 B | 50,368 B | 1,216 B |

Static size includes code, constant tables, ledger cursors, reports, stacks
and alignment. The resident region remains 160 KiB. Bootstrap/interrupt
stacks remain four times 8 KiB, worker stacks two times three times 4 KiB;
compilation remains safe. The existing 48 KiB linker/audit gate was retained.
After boot-fixture allocations and guards, internal free bytes per owner
were 26,752 in integer, 24,704 in raw FP and 24,576 in compiled FP.

Child allocation uses one fixed ledger lookup and checked cursor arithmetic.
It adds no per-object metadata, buddy header or buddy operation. The parent
still incurs buddy rounding and must be sized before allocation. Remaining
static growth margin is small; further additions need explicit footprint
accounting rather than a lower heap gate or smaller stacks.

## Qualification

All 117 host tests passed in Debug and ReleaseSafe. Seven new tests cover
many children under one parent, canonical cursors through copied handles,
alignment/exact-capacity exhaustion and cursor rollback, foreign/forged
handles, close/address reuse, task close/generation reuse, raw parent kind
checks and failed parent acquisition without quota consumption.

All 62 Python tests passed: 53 log tests, eight image tests and one compiler
test covering five rejected record-schema classes. The new mutation test
rejects missing or incorrect pool counts in populated and absent logs.
ZLint, ShellCheck and six architecture ELF/instruction audits passed.
Six full Flash image audits passed, including the actual stock loader ELF,
cache configuration, profile bounds, known ROM symbols and internal heap.

All nine final emulator cases passed: integer with absent/4/8/16/32/64 MiB,
raw FP with absent PSRAM, compiled FP with absent and 32 MiB PSRAM. Existing
300-round scheduling, FP, normal/forced task lifecycle, IPI-only idle, SRAM,
PSRAM mapping/cache/command and reusable heap gates remained required.
The JSON ties each smoke log/report to its final audited ELF and verifies
runtime SRAM spans against the image's heap partition.

## Evidence boundary

The preceding commit passed both ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40255569907).
Current remote CI is separate from the local results recorded here. No
physical device was accessed. Silicon timing, cache topology, DMA suitability
and power/retention behavior remain unqualified. Pool handles reject stale
allocator operations; returned raw child pointers still require correct
consumer lifetimes. Individual child free/realloc, shared service ownership,
SQLite's allocator adapter and Quake's large hunk remain separate work.

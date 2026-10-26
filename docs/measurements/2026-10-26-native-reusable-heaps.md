# Native reusable PSRAM heap qualification

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source hashes, six image audits and nine smoke reports](2026-10-26-native-reusable-heaps.json)
- [ADR 0028](../adr/0028-owner-local-reusable-psram-heap.md)
- Reproduce: `sh tools/run-native-smoke.sh integer 64M` and `sh tools/run-native-smoke.sh compiled 32M`.

## Results

All nine complete smoke cases passed: integer without PSRAM and with
4/8/16/32/64 MiB, raw FP without PSRAM, and compiled FP without PSRAM and
with 32 MiB. Every case retained the 300-round scheduler/lifecycle, SRAM,
IPI/idle and FP gates. Populated cases retained full mapping, CPU/command
cache checks and the 64-round cross-core payload protocol.

Each owner runs variable-size aligned allocation/free churn under timer
preemption, then frees remaining worker handles. Maximal-block allocations
exhaust the heap; reverse frees restore all reusable payload capacity.
Thirteen rejected operations cover invalid requests, stale/double/interior/
wrong-length/foreign-owner frees and exhaustion, with MIE checks for both
bootstrap and preemptible-worker success/error paths.

| PSRAM | Combined reusable payload | Combined tree bytes | Allocation/free pairs, CPU0 / CPU1 | Max node visits |
| --- | ---: | ---: | --- | ---: |
| Absent | 0 | 0 | 0 / 0 | 0 |
| 4 MiB | 3,603,072 B | 131,072 B | 14,235 / 14,236 | 47 |
| 8 MiB | 7,666,304 B | 262,144 B | 14,088 / 14,088 | 50 |
| 16 MiB | 15,792,768 B | 524,288 B | 13,939 / 13,939 | 53 |
| 32 MiB | 32,045,696 B | 1,048,576 B | 13,798 / 13,800 | 56 |
| 64 MiB | 64,551,552 B | 2,097,152 B | 13,661 / 13,661 | 59 |

The populated compiled-FP case completed 9,432 / 9,432
allocation/free pairs on CPU0 / CPU1, recovered the same 32,045,696 bytes
and retained 218 / 218 timer captures inside generated task code. Every final heap had zero live allocations,
equal allocation/free counts and `free == capacity`. Integer mode retained
zero FP trap copies. These are execution checks, not bandwidth/FPS results.

## What capacity means

The first 192 KiB remains reserved for mapping/cache tests. Each owner also
retains its 64-byte bootstrap buffer and two 65,728-byte boot-test buffers.
The rest becomes reusable backing, with two more 64-byte guards per heap
and its external tree metadata deducted. Thus `external_registered_bytes`
describes the original guarded arena capacity; `external_allocatable_bytes`
and the new `heaps` records describe reusable payload capacity.

Reusable capacity counts whole buddy blocks before per-allocation headers,
alignment padding and power-of-two rounding. Minimum blocks are 64 bytes,
headers are 16 bytes and requested alignment is bounded at 64 KiB. Total
free capacity is not the maximum single allocation: the 32 MiB layout has
an 8 MiB raw maximum block per owner, before header/padding. Larger Quake
hunks need a separate extent/arena plan. Small SQLite objects need a suitable
small-block layer/adapter; this is not a claim of efficient C allocation.

## Bounded operations and verification

Initialization is linear and occurs before either scheduler timer starts.
Both boot-release/owner-ready waits allow one billion cycles; normal payload
waits keep their 100-million-cycle budget. Early cases were rerun after the
final boot-budget adjustment so every retained report uses the final code.
The final rerun also includes atomic rejection-counter updates shared by
the two preemptible workers.

Runtime allocation visits at most `3 * levels + 2` metadata nodes, including
search, path validation and update. The maximum observed was 59. A fixed
128-byte guard scan and constant header/accounting work are additional.
Payload filling occurs with interrupts restored. This bound describes
node visits; it does not measure instructions, cache misses or worst-case
interrupt latency. Neither physical timing nor ROM cache waits are qualified.

All 100 host tests passed in Debug and ReleaseSafe. Thirteen new tests cover
alignment/exhaustion/fragmentation/coalescing, exact tree recovery, malformed
and stale handles, corruption, forged out-of-span allocated/free nodes and
serial exhaustion. Deterministic 4,000-operation churn checks live contents,
nonoverlap and capacity recovery. Detected metadata/guard faults poison the
heap; invalid caller requests preserve allocation state.

All 52 Python native tests passed, including missing/duplicate heap reports,
leaks, incomplete recovery, metadata/bounds mismatch, invalid node-visit
counts and absent-die heaps. ZLint, ShellCheck, six architecture ELF audits
and six full Flash image audits passed.

## Internal footprint and remaining boundaries

Both revision profiles produced the same sizes:

| Mode | Static SRAM including stacks | Internal heap span | Free per owner after SRAM fixture |
| --- | ---: | ---: | ---: |
| Integer | 104,576 B | 26,496 B | 12,672 B |
| Raw FP | 107,904 B | 23,168 B | 11,008 B |
| Compiled FP | 108,160 B | 22,912 B | 10,880 B |

The smallest internal span remains 6,528 bytes above the 16 KiB linker gate.
The 128 KiB SRAM window, bootstrap/interrupt/worker stack reservations and
exact six-symbol ROM boundary are unchanged. App images remain 65,616 bytes.
No heap allocation or PSRAM access was added to the trap path.

The source parent `f88b708dbbfed6d8a793f3ce8492a9a4bbe2f155` passed ordinary
CI and [Native boot](https://github.com/masanork/nihos/actions/runs/40244647574).
Those results qualify the parent; this JSON records local evidence for the
new source, with remote CI kept separate.

No physical device was accessed. Silicon coherency, voltage/timing,
retention, DMA and high-speed operation remain unqualified. Handles reject
stale frees within one heap lifetime, not stale payload accesses or arbitrary
machine-mode corruption. Free remains owner-local. Automatic task/service
resource cleanup, migration/remote frees, realloc and C/SQLite allocator
adapters are subsequent work.

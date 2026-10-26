# Native deferred task resource qualification

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source hashes, six image audits and nine smoke reports](2026-10-26-native-task-resources.json)
- [ADR 0029](../adr/0029-deferred-native-task-resource-cleanup.md)
- Reproduce: `sh tools/run-native-smoke.sh integer 4M` and `sh tools/run-native-smoke.sh compiled 32M`.

## Lifecycle result

All nine final smoke cases passed: integer with absent/4/8/16/32/64 MiB,
raw FP without a die, and compiled FP without a die and with 32 MiB. Each
completed the existing 300-round scheduler, FP, IPI/idle and memory gates.
The populated compiled case retained 203 / 215 captures in generated task
code. These are execution/resource checks, not performance measurements.

The native external allocation API now records allocations against the
selected task slot/generation and current hart. Its fixed SRAM ledger has
two outstanding-handle slots per task. Quota failure occurs before heap
allocation; explicit free verifies exact task and handle ownership.

Normal EXIT closes its ledger in the common native call bridge. A blocked
integer task is also forcibly terminated from the owner bootstrap with
code -99. Closure only changes SRAM state. Each bootstrap service pass
releases at most one retained handle, outside the interrupt stack, and
retirement/reaping waits for cleanup completion before slot reuse.

| Final evidence, per hart | PSRAM absent | PSRAM populated |
| --- | ---: | ---: |
| Opened generations, including bootstrap | 7 | 7 |
| Closed and cleaned tasks | 6 | 6 |
| Automatically reclaimed handles | 0 | 8 |
| Lifecycle slot reuses | 3 | 3 |
| Rejected stale generations | 3 | 3 |
| Quota rejections | 0 | 3 |
| Forced terminations | 1 | 1 |
| Remaining owned / pending handles | 0 / 0 | 0 / 0 |

Two normal lifecycle tasks and the blocked task each deliberately retain
two allocations; each busy worker retains one. The protocol task closes
an empty ledger. The final heap fixture requires worker handle slots already
empty and no live blocks before its exhaustion/recovery check. It no longer
silently frees leftover worker allocations at the end.

Pending cleanup prevents WFI, and completing a close yields so reaping
does not depend on another periodic interrupt. The existing IPI-only idle
phase still requires unchanged timer IRQ counts. Extra bootstrap yields
are integer-only; the forced task does not opt into FP, keeping five checked
FP-bank starts per hart. Generic cleanup does not read application payloads;
the fixture validates its known worker buffers outside the interrupt mask.

## Verification

All 108 host tests passed in Debug and ReleaseSafe. Eight new tests cover
close without immediate frees, bounded draining, reuse gates, quota/OOM
rollback, wrong-task/owner/malformed frees, unrelated live data, cleanup
failure, stale/exhausted generations and terminal scheduler states.
Running, blocked, sleeping and event-waiting policy termination cannot
resurrect a task through later ticks or notifications.

All 56 Python native validator tests passed. New cases reject missing or
duplicate resource owners, incomplete reclamation/completion/reuse, leftover
handles, missing forced termination and physical frees without PSRAM.
Two normal reaps cannot pass the new three-generation checkpoint.
ZLint, ShellCheck and six architecture ELF audits passed. Six full images
were built and audited with the same known six-symbol ROM boundary.

## Footprint

Both revision profiles produced these sizes. Four 8 KiB bootstrap/interrupt
stacks, worker stacks and the conservative 128 KiB SRAM window are unchanged.

| Mode | Static SRAM, stacks included | Internal heap span | Free per owner after SRAM fixture |
| --- | ---: | ---: | ---: |
| Integer | 108,480 B | 22,592 B | 10,688 B |
| Raw FP | 112,704 B | 18,368 B | 8,576 B |
| Compiled FP | 112,832 B | 18,240 B | 8,512 B |

The smallest span is 1,856 bytes above the 16 KiB linker gate. Odd trailing
64-byte granules are excluded from the equal owner partitions. App images
remain 65,616 bytes. Further native features need footprint/layout work;
the linker minimum was not weakened. PSRAM geometry and reusable payload
capacity are unchanged: the 32 MiB layout has 32,045,696 reusable bytes in
total, with an 8 MiB raw maximum buddy per owner before header/padding.

## Limits

The tested source extends the independent native runtime. Hosted ESP-IDF
tasks and a general service supervisor are outside this wiring. Service
tasks can use the same ownership path; scoped pools, independent service
domains, C/SQLite integration and cross-core destruction remain subsequent
work. Shared payload users must stop before owner cleanup; this ledger does
not provide reference counting or machine-mode memory isolation.

No physical device was accessed. The measurements do not qualify physical
interrupt latency, cache coherency, DMA lifetimes, retention or power timing.
The parent `ab7b5691f689be02075d0affe44bc97d9b8e0840` passed ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40248002046).
Those remote results qualify the parent; current remote CI is separate.

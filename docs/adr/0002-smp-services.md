# ADR 0002: SMP services own state behind bounded mailboxes

- Status: accepted
- Date: 2026-10-25

## Context

nihos targets both ESP32-P4 cores under its native scheduler. Games need
low-latency display, input, audio, clock, and file services. A future SQLite
facility needs strict connection ownership, durable storage semantics,
cancellation, and bounded memory. Putting these libraries in every application
would duplicate policy and make resource cleanup harder. Permanently assigning
SQLite to CPU1 would also encode a MeOS bring-up constraint into a new SMP OS.

The current firmware is still ESP-IDF-hosted. FreeRTOS owns both cores; native
nihos scheduling, interrupts, and inter-processor wakeups are not implemented
yet.

## Decision

Stateful facilities run as system-service tasks. Each service owns its mutable
library and device state and communicates through fixed-capacity request and
completion mailboxes. The scheduler may apply soft affinity for cache locality,
but a service is not identified with a physical core.

The common transport begins with a lock-free SPSC ring using monotonic counters
and release/acquire publication. One client endpoint has one producer and one
service consumer; fan-in is built from multiple endpoints rather than adding a
contended multi-producer lock to the fast path. Full queues fail closed and the
wakeup mechanism remains a scheduler concern.

Native trusted applications may exchange leased shared-memory buffers plus
handles and fences. Isolated or WASM applications use validated copies or
bounded shared slabs. No request may contain an unbounded result buffer or a
raw platform pointer.

## SQLite shape

The first `sqld` implementation will own one SQLite connection and call SQLite
from one task, even though the OS is SMP. Other cores continue running clients,
graphics, audio, and storage work concurrently. This permits a measured
`SQLITE_THREADSAFE=0` build without allowing concurrent entry into SQLite.

`sqld` uses asynchronous capability-checked requests with owned database,
statement, transaction, and row-batch handles. It does not expose filesystem
paths to untrusted clients. The SQLite VFS calls the nihOS storage service;
SQLite never owns an SD controller, littlefs instance, or Flash critical
section.

Core affinity is an optimization hint. The scheduler may keep `sqld` on one
core for cache locality, move it when that core is needed for a frame deadline,
or budget it below display and audio work. Flash operations still require a
cross-core quiescence protocol because native SMP does not remove external
Flash/cache restrictions.

Rollback-journal `PERSIST`, full synchronization, and memory-backed temporary
state are the initial durability baseline. WAL, multiple reader connections,
or `SQLITE_THREADSAFE=2` require separate measurements and VFS fault tests;
SMP alone does not make them faster or safer.

The detailed design baselines are
[`../planning/filesystem-vfs.md`](../planning/filesystem-vfs.md) and
[`../planning/sqlite-integration.md`](../planning/sqlite-integration.md).
They separate filesystem capabilities, mount policy, and qualified durability
profiles; define mount/handle lifetime and cancellation; and preserve an unknown
commit outcome after timeouts or lost replies. General FAT/exFAT write support
does not qualify a mount for writable SQLite. The initial development profile
permits one connection and one database; bounded read-only attachments require
a separately budgeted extension profile.
These are implementation and validation requirements, not completed features.

## Staged validation

1. Host-test bounded SPSC ordering, overflow, and wraparound.
2. Use the ESP-IDF backend as an oracle for physical cross-core ordering and
   RISC-V atomics, then bring up native CPU1 and inter-processor wakeup without
   SQLite.
3. Measure request/completion latency, cancellation, and queue saturation.
4. Add a single-owner storage service and cross-core Flash pause/resume.
5. Fault-test a custom SQLite VFS on the host before linking SQLite.
6. Add a shell-only `sqld`, then measure Flash, SRAM, PSRAM, stack, query
   latency, storage throughput, and interference with a frame workload.
7. Expose permissioned application APIs only after recovery and cancellation
   behavior is qualified on hardware.

The first half of stage 2 now has physical evidence: the same Zig ring used by
the host test completed 100,000 ordered CPU0-to-CPU1 request/completion pairs
on a Tab5. FreeRTOS supplied task creation and affinity, and both sides used
busy polling, so this result qualifies the shared-memory transport but not the
future native scheduler, IPI wakeup, cancellation, or service latency under
load. See
[`../measurements/2026-10-25-espidf-smp-mailbox.md`](../measurements/2026-10-25-espidf-smp-mailbox.md).

## Consequences

- Native SMP concurrency remains available without paying SQLite connection
  mutex costs on the initial path.
- Graphics, audio, and database work share one observable service model.
- A busy database cannot silently allocate an unbounded queue or block a game
  while holding caller-owned locks.
- The system needs explicit scheduler wakeups, cancellation, priority budgets,
  and storage durability contracts before SQLite integration begins.

## References

- [SQLite threading modes](https://sqlite.org/threadsafe.html)
- [SQLite VFS interface](https://sqlite.org/vfs.html)
- [SQLite isolation and journal modes](https://sqlite.org/isolation.html)

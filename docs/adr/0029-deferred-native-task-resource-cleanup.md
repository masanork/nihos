# 0029: Task-bound allocation and deferred native cleanup

Status: accepted for native qualification, 2026-10-26.

## Ownership and quota

Bind the public native `allocExternal`/`freeExternal` API to the scheduler's
current task key: slot plus nonzero generation. The trap publishes that key
when selecting a context. Allocation/free reads it while local interrupts
are masked, checks an active ledger and uses the current hart's buddy heap.
The caller does not supply an owner task ID. Both hart and task ownership
are required for a release. Privileged unscoped heap operations remain
private to the boot/qualification module.

The host-testable `Resources` table has fixed task and handle limits. The
native fixture uses four slots and two outstanding handles per slot.
Its descriptors remain in internal SRAM. A full ledger fails before any
heap allocation, and a failed heap allocation cannot register a phantom
handle. Successful explicit free removes the exact handle only after the
heap accepts it. Partial/interior, wrong-task and stale handles cannot remove
another entry. Generation numbers never wrap into an older owner.

The two-handle limit is a qualification quota, not a proposed SQLite object
limit. A service with many small allocations should own a scoped arena or
pool as a parent resource, or use a separately budgeted ledger. Increasing
the native SRAM table without accounting for its footprint is not implicit.

## Close, drain and reuse

Resource states are vacant, active, closing, cleaned and faulted. The native
EXIT bridge marks the exiting task closing after the policy has stopped it.
The bootstrap's forced-termination path stops and closes its target under
the same owner serialization. Repeated close is idempotent for that same
generation. A closing owner cannot allocate or explicitly release resources.

Closing only updates the fixed SRAM table; no PSRAM/free/cache work occurs
on the interrupt stack. Every bootstrap service pass copies one pending
key/handle under a local interrupt mask, then releases at most one handle.
The bounded heap operation and ledger update are serialized; interrupts
are restored between passes. The worker qualification's optional content
validation happens outside the mask. Generic cleanup imposes no payload
contents or initialization requirements on ordinary allocations.

After the last entry is removed, the ledger becomes cleaned. Only then may
native maintenance retire FP/stack ownership, reap the scheduler completion
and create the next generation in that slot. A failed heap release keeps
the entry, marks the slot faulted and prevents reuse. No partial cleanup
is published as success. Empty owners, including no-PSRAM boots, complete
through an SRAM-only path without touching an uninitialized heap.

Pending work prevents bootstrap WFI. Completing a close issues a scalar
yield so the scheduler can reap even after periodic alarms are disarmed.
This also avoids relying on an unrelated future interrupt to finish a
protocol task's cleanup. No remote mutable ledger or allocator is accessed.
Final resource reports are read only after the existing release/acquire
final-memory publication has made the owners quiescent.

## Termination policy

The allocation-free scheduler gains owner-only `terminate(handle, code)`.
It preserves a terminal completion and runtime accounting, clears waits,
deadlines and notifications, and removes the current selection if needed.
Stale/already-exited handles fail. Architecture code must ensure a task is
stopped before reclaiming memory or its retained stack/frame.

There is no new task-visible kill syscall. The native fixture terminates
an already-blocked integer task from the bootstrap and requires code -99.
The extra integer task does not opt into FP, preserving the existing five
checked FP-bank starts. Host tests also exercise termination of running,
sleeping and event-waiting policy states without resurrection.

## Qualification

Each hart runs two normal lifecycle generations and a blocked generation
that deliberately retain two allocations each. Both busy workers retain
one final task-owned allocation. Cleanup must reclaim those eight handles;
the protocol task closes an empty ledger. Including the retained bootstrap,
seven generations open, six close/complete, and the lifecycle slot is reused
three times. Old generation close/active checks fail after every reuse.
Each lifecycle also checks quota rejection and explicit free/reallocation.

Busy allocation/free churn uses the public task-bound path. Their remaining
payloads are verified by the bootstrap and released through deferred cleanup.
The final heap fixture now requires worker handle slots already empty; it
does not hide leaks by freeing them at the end. It still exhausts and fully
recovers the heap and retains the earlier invalid-free/MIE checks.

Without PSRAM, the same normal/forced completion and generation protocol
must run with zero reclaimed handles. All previous scheduler, SRAM, FP,
IPI/idle, mapping and cache/command gates remain required. Native logs now
require three preemption-phase reaps, not the earlier two normal exits.

Host tests cover close without frees, one-handle draining, quota/OOM rollback,
same-hart wrong-task frees, unrelated live data, stale/exhausted generations,
cleanup failure and forced terminal policy states. Log validators require
both resource owners and exact completion/reuse/reclamation counts.

## Remaining boundary

This wires the independent native runtime, not hosted ESP-IDF tasks or a
general service supervisor. Native service tasks can use the same ownership
path; independent service scopes, scoped pools, cross-core destruction,
reference/lease tracking for shared payloads, C/SQLite adapters and migration
remain future work. Machine-mode code still shares authority and raw pointer
access. Cleanup does not protect against another consumer retaining a pointer.
No hardware qualification, DMA lifetime or silicon latency claim follows
from host or emulator tests.

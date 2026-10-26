# 0036: Task-owned size-class pools and preemptible resize

Status: accepted for native qualification; physical qualification pending, 2026-10-26.

## One parent, ten classes

Add `openObjects(count)`, `allocObject`, `freeObject`, `objectCapacity`,
`reallocObject` and `closeObjects` under native `memory.reusable`. A pool
contains ten independent size classes: 8, 16, 32, 64, 128, 256, 512, 1024,
2048 and 4096 bytes. Each has the same explicitly chosen cell count, 1..65535.
Requests use the smallest fitting class; a full class fails even if a larger
class has space. Requests larger than 4096 bytes fail. There is no pool
growth, shared mutable allocator or silent fallback to the outer heap.

Each class reuses the slab layout from [ADR 0034](0034-task-owned-fixed-size-slabs.md).
The ten adjacent class spans occupy one task-owned buddy allocation and one
ledger entry. The existing four task slots and two parents per slot remain.
The SRAM storage tag retains the canonical count; the tracked outer pointer,
length and ticket determine geometry. Class metadata is in PSRAM. All payloads
are eight-byte aligned. Requested parent bytes are:

```text
sum over classes: 32 + count * align_up(16 + class_capacity, 8)
```

For count two this is 17,008 bytes; the outer buddy consumes 32 KiB. Uniform
quotas deliberately simplify the first implementation but reserve substantial
unused capacity for uneven workloads. Service-specific quotas, requests above
4 KiB and fallback policy require separate measured decisions.

## Exact length, capacity and stale handles

An object handle contains its class and the slab handle: exact borrowed
slice, cell index, non-wrapping u64 ticket and u64 outer parent epoch. The
allocated-cell marker now stores a high allocated bit and logical length;
free-list indexes remain below that bit. Existing fixed slabs still expose
their full fixed capacity. `objectCapacity` validates the handle before
returning its class capacity, which can exceed its slice length.

The native resize contract is:

- Null plus positive length allocates; null plus zero returns null.
- Non-null plus zero frees and returns null.
- A positive length within current capacity retains the address/class,
  authenticates the new exact length and issues a fresh ticket. Shrinking
  does not migrate to a smaller class. Even same-length resize renews the
  ticket. Older handles fail subsequent allocator operations.
- A larger length reserves the destination before changing the source.
  After a successful copy it releases the source and returns the destination.
  Allocation failure preserves the source handle and contents.

Only the old logical-length prefix is copied; newly exposed bytes are
uninitialized. No payload is cleared by allocation/free. Renewing a ticket
does not revoke existing raw pointers or stop access through a retained slice.
The bounds/consistency checks are not memory isolation. The inherited XOR
cookies are non-cryptographic and do not detect all corruption.

## Bounded metadata, preemptible payload work

`openObjects` requires MIE enabled. It reserves/registers the parent under
the local interrupt mask, initializes all class/cell headers outside that
mask and publishes after a fixed ten-header check under the mask. Rollback
uses the shared `closeObjects` path; failed outer release retains the tracked
parent. Pending parents cannot allocate children.

Object metadata operations check current hart/task, task generation, exact
live parent, storage kind, class, parent epoch and exact cell identity before
mutation. Geometry calculation walks at most ten classes. Selected slab
operations check bounded header/free-head state without a cell traversal.
Neither metadata work nor interrupt-disabled work scales with payload size
or the number of cells. This is an operation-count bound, not measured latency.

Native `reallocObject` also requires MIE enabled, including no-copy cases.
It obtains an internal resize plan while masked, restores MIE, copies the
payload, then masks briefly to commit. The dedicated copy helper checks MIE
before and after copying. If commit fails, cancellation attempts to release
only the reserved destination. An intact source remains usable; a detected
metadata fault can poison its class. Cancellation need not read a damaged
source class. If rollback itself fails the parent remains tracked for close.

The low-level `size_pool.View` and resize plan are trusted kernel borrows.
Callers must copy before commit or cancel the plan, serialize their own
operations, and never retain a view/plan past its parent lifetime. A plan
is not an authorization token against malicious plan fabrication. The native
wrapper keeps it private. One task owns a pool; this stage adds no cross-task
sharing, cross-core lock or task migration contract.

## Task termination and evidence

Task close only marks the SRAM ledger. Deferred cleanup frees one opaque
parent per service pass without examining child state. It can reclaim pending
initialization, a move with both cells live, and poisoned class metadata.
If a task is terminated while initializing/copying, scheduler retirement
prevents it resuming after parent reclamation. Slot/stack/FP reuse remains
gated on ledger completion; there are no per-cell destructors.

Both busy workers per hart now retain an object pool alongside their raw
allocation. They exercise in-place expansion, shrink with retained capacity,
multiple moving expansions (including a 2048-byte copy), stale-handle refusal,
interrupt-disabled resize, a full destination class and oversized requests.
After a failed resize they verify source bytes, free blockers, retry and
retain a filled 4096-byte object. Cleanup verifies all those bytes outside
the interrupt mask before releasing the parent. Generic recovery must leave
no retained worker/object state and return all outer heap capacity.

Per populated hart the report requires eight moves, four in-place changes,
eight rejections and 4208 copied bytes. Reclaimed parents increase from eight
to ten; existing monotonic/slab counters are unchanged. Absent-PSRAM runs
require zero for all these object/reclamation counts. Copy counters use atomic
increments because both workers can preempt each other on one hart.

Host tests cover class boundaries/quotas, exact length, ticket exhaustion,
failure/cancellation, poisoned-source rollback, ownership, task death during
initialization/move and stale plans after parent/task generation reuse.
[The measurement](../measurements/2026-10-26-native-size-pools.md) binds local
tests, six profile images and nine retained emulator cases to source hashes.
MIE observations do not prove an interrupt occurred inside a particular copy.
Physical PSRAM timing/cache behavior, maximum stack use and service workload
performance remain unqualified.

This is a typed Zig object API. A pointer-based C allocator/SQLite adapter,
contiguous lookaside storage and a service-owned database lifecycle remain
future work; this stage does not claim SQLite support.

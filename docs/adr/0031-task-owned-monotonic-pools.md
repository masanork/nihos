# 0031: Task-owned monotonic pools

Status: accepted for native qualification, 2026-10-26.

## Parent ownership and child allocation

Add `openPool`, `allocPool` and `closePool` to the native reusable memory
interface (`memory.reusable`). A pool acquires one buddy allocation through
the current task's existing resource ledger. Its capacity is the requested
parent byte length, not the larger rounded buddy block. It consumes one of
the fixture's two handle entries irrespective of its child count. There is
no separate per-child ledger, heap header or buddy operation.

The host-testable `Resources` table stores an optional cursor beside each
parent handle. A null cursor marks an ordinary allocation. Pool handles
contain the task slot/generation and exact parent allocation, including its
ticket. They do not contain a mutable cursor. Copies therefore refer to the
same allocation position instead of creating overlapping independent arenas.
Opening a pool and registering its zero cursor is one serialized operation;
failed parent acquisition does not consume a ledger entry.

Each child request checks the current hart, task generation, active ledger,
exact tracked parent and pool kind. It then validates a nonzero length and
power-of-two alignment, checks address arithmetic for overflow and bounds
the aligned extent against the requested parent length. Rejection leaves
the cursor unchanged. Successful allocation advances it once. Alignment may
exceed the parent's initial alignment when sufficient interior space exists.

All mutable allocator metadata remains in internal SRAM. Native wrappers
mask only local interrupts around the owner operation and restore their
previous state on success and failure. Child allocation scans at most the
fixed two-entry task ledger and never touches PSRAM, walks a buddy tree,
fills a payload or takes a cross-core lock. Consumers initialize and use
their returned spans with interrupts restored. This is a structural bound,
not a measured interrupt-latency guarantee.

## Close and lifetime

Explicit pool close validates ownership and kind, then frees the exact parent
through the existing ledger release. Subsequent requests through any copied
handle fail, including after the same address is acquired with a new ticket.
Freeing a pool parent through the raw task-bound release also invalidates its
pool handle. An ordinary raw allocation cannot masquerade as a pool.

Task exit or forced termination marks the ledger closing before cleanup.
Pool requests then fail even while the parent is still allocated. Existing
bootstrap cleanup releases at most one parent per service pass, discarding
its cursor with the entry. No child traversal is required. Stack/FP retirement
and task-slot generation reuse remain gated on successful parent cleanup.
The existing faulted-ledger behavior is unchanged if parent release fails.

Callers must stop using all child pointers before explicit close or task
termination. Returned slices are ordinary pointers; this API cannot revoke
them or prevent accesses through an already returned slice after its lifetime.
Pool validation protects allocator operations, not arbitrary machine-mode
memory accesses. Handles are not transferable to another task or hart.

## Qualification and budget

Both harts exercise two normal lifecycle generations and one blocked task
terminated by the bootstrap. Each generation opens a pool, allocates three
aligned children through original/copied handles, checks distinct extents
and volatile content reads, and rejects exhaustion. It fills its second
ledger entry with a raw allocation and requires the third parent to fail.
It explicitly closes/reopens the pool and rejects the old ticket before
allocating three more children. The replacement pool and raw allocation
remain live at exit/termination and must be reclaimed automatically.

Per populated hart, `NIHOS_NATIVE_RESOURCES` requires 18 successful child
allocations and six pool rejections. The previous eight-parent reclamation,
zero outstanding resources and generation/termination counts remain required.
No-PSRAM boots must report zero pool allocations and rejections. Host tests
also cover 40 children using one entry, exact-capacity exhaustion, failed
requests without cursor advancement, foreign/forged handles, ordinary-parent
kind checks, explicit close/address reuse, close-before-drain invalidation,
generation reuse and parent-acquisition rollback. Log mutation tests require
the new evidence fields in populated and absent runs.

Retain the 48 KiB internal heap gate, all stack sizes and safe compilation.
Record final footprint changes and six image audits in the accompanying
measurement; no SRAM bank or cache policy is changed for this stage.

## Remaining boundary

This is a task-owned monotonic allocator for bounded service/request lifetimes.
Children have no individual free, resize, reset or destructors. Unused parent
capacity and buddy rounding still cost memory; a child allocation does not
fall back to another parent. Independent service IDs, cross-task sharing,
remote frees, reference tracking and a service supervisor remain separate work.
SQLite's general-purpose allocator needs free/realloc behavior and an adapter;
this pool alone does not implement its allocation contract. Quake's large
contiguous hunk still needs the previously identified extent design. No new
physical-device, DMA, retention or performance qualification follows here.

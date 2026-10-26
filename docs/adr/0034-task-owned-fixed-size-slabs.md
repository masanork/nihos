# 0034: Task-owned fixed-size slabs

Status: accepted for native qualification; physical qualification pending, 2026-10-26.

## Ownership and layout

Add `openSlab(object_bytes, count)`, `allocSlab`, `freeSlab` and `closeSlab`
under native `memory.reusable`. One slab consumes one task-ledger parent
allocation, regardless of the number of cells it contains. The existing
four task slots and two parent handles per slot are unchanged. This supports
many reusable service objects without a per-object internal-SRAM ledger.

The fixed cell size is 1..65,536 bytes and count is 1..65,535. Each cell
payload is eight-byte aligned. Requested parent length is:

```text
32 + count * align_up(16 + object_bytes, 8)
```

The 32-byte parent header and 16-byte cell headers live inside PSRAM. Payloads
are not initialized, cleared or read by allocation/free. The underlying buddy
header and power-of-two rounding remain additional costs; rounding can erase
an apparent small-object saving. There is no capacity growth or fallback.
The per-task SRAM entry stores a tagged raw/arena/pending-slab/ready-slab
state and its cell-size parameter. Parent pointer, length and ticket remain
the canonical tracked allocation. Geometry is derived from those values,
not from mutable pointers, lengths or counts in the child metadata.

Cell handles contain a borrowed payload slice, cell index, non-wrapping u64
allocation ticket and u64 parent epoch. The epoch is the outer buddy ticket.
Closing/reopening a parent may reuse the same address and restart the child
ticket sequence, so both are required. An old child cannot release a new
cell even when address, index and local ticket all recur. Copied slab leases
share the parent header/free list; they do not contain independent cursors.

## Bounded operations and initialization

Cell allocation checks the parent header and free-list head/successor, pops
one cell and assigns a new ticket. Free validates the exact live cell and
pushes it onto the free list. Index checks precede cell-header access. Both
operations touch a fixed amount of metadata, independent of capacity, with
no cell/payload traversal or outer buddy operation. The ledger lookup is
bounded by the existing fixed parent quota. Native wrappers serialize only
the local owner hart and restore its previous interrupt state on every path.
This is an operation-count bound, not a measured latency guarantee.

Initialization is separate because it writes one header per cell. Native
`openSlab` requires interrupts already enabled; disabled entry returns
`InterruptsDisabled` without acquiring a parent. The constructor:

1. Masks local interrupts, reserves/registers a pending parent and obtains
   its geometry, then restores interrupts.
2. Initializes the free list and metadata outside the interrupt mask. The
   header's full parent epoch is committed after cell initialization.
3. Masks interrupts again, validates the fixed parent header, publishes the
   ready tag and restores interrupts before returning the lease.

Pending slabs cannot allocate/free cells. Invalid low-level publication keeps
the entry pending. The native constructor cancels its reservation on geometry
or publication failure; a failed parent release leaves its handle tracked.
Task close or explicit cancellation can release an unfinished
parent without interpreting its contents. If the task is stopped during
initialization, the existing scheduler/cleanup contract prevents it resuming
against a released parent. No cross-core mutable slab state or lock is added.

The standalone `View` is a trusted kernel borrow of the parent. It must be
initialized once per new epoch and must not outlive that span; retaining a
raw view does not gain the guarded lease API's lifetime validation.

## Invalid operations and close

Every guarded operation checks current hart/task ownership, generation,
active ledger, exact parent handle and allocator kind before reading child
metadata. Foreign, stale, interior and wrong-kind leases fail. Freed cells,
wrong lengths, wrong indexes, stale tickets and foreign parent epochs fail
without releasing another cell. Neither ticket sequence is allowed to wrap.

The parent has an explicit full epoch and head/live bounds. Cheap XOR
consistency words cover header/cell state; detected corruption poisons that
child allocator. These are non-cryptographic checks and do not detect all
possible corruption. Bounds are checked against canonical geometry even
when metadata is bad. They are not memory isolation or raw-pointer revocation.

Explicit close discards the slab as one parent, including live cells. Task
exit/forced termination does the same through existing deferred cleanup,
at most one parent per service pass. Cleanup never follows a child free list,
and can reclaim a pending or poisoned slab. Stack/FP retirement and task-slot
reuse remain gated on ledger completion. Callers must stop all users before
closing; there are no per-object destructors or cross-task shared references.

## Qualification and footprint

Both harts' two normal lifecycle generations and one forced blocked task
exercise a 16-cell, 32-byte slab. Each generation exhausts a slab, frees four
alternating cells, rejects double/stale frees, refills and checks distinct
payloads with volatile reads. It closes/reopens the parent, rejects the old
lease, repeats the cell exercise and rejects a prior-parent child against
the new lease. Constructor entry with interrupts disabled must also fail.

Per populated hart, resource records require 120 cell allocations, 24 explicit
cell frees and 27 slab rejections. One replacement slab retains 16 live cells
per generation at normal/forced exit. Together with the retained monotonic
pool and worker allocations, the previous eight-parent reclamation and zero
outstanding resources remain required. No-die cases report zero slab work.

Keep the 48 KiB internal heap minimum, all stack reservations, safe compilation,
cache/clock policies and Flash boot-function whitelist. Shared geometry,
ownership and metadata checks reduce code duplication. Qualification loops
derive their tested prefix from the retained parent rather than duplicating
an unrolled allocation sequence. Record final net SRAM growth, including
fixture/report code, in the accompanying measurement; remaining margin is
small and must be budgeted before further native additions.

## SQLite and remaining boundary

This is a fixed-size service-object allocator, not a complete C allocator.
Variable size classes, resize/realloc, C ABI adapters and shared service
ownership remain separate work. SQLite's
[memory-method contract](https://www.sqlite.org/c3ref/mem_methods.html)
also requires size/rounding and realloc behavior. It is not implemented by
these slab APIs alone.

SQLite's
[lookaside configuration](https://www.sqlite.org/c3ref/c_dbconfig_defensive.html#sqlitedbconfiglookaside)
expects one aligned contiguous buffer for its slots. Our interleaved cell
metadata is not that buffer format. A task-owned arena can instead supply a
contiguous borrowed region whose lifetime covers the connection, with its
own separately tested adapter. No SQLite build/VFS, general service supervisor,
remote frees, DMA or physical performance qualification is included here.

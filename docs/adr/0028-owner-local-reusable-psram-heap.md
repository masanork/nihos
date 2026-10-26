# 0028: Owner-local reusable PSRAM heaps

Status: accepted for native qualification, 2026-10-26.

## Purpose and scope

ADR 0027's external boot arenas cannot reclaim storage. Add a reusable
allocator for owner-pinned services and application lifetime experiments.
Keep the boot arenas for SRAM and the existing external test buffers.
The native API returns an `Allocation` handle containing a byte slice,
owner, tree node and 64-bit ticket. `allocExternal`/`freeExternal` use this
API; it is not yet a C `malloc`/`free` adapter or a Zig standard allocator.

Use a buddy tree with 64-byte minimum blocks. This first reusable layer
prioritizes bounded operation paths and inspectable ownership rules.
Power-of-two rounding, a 16-byte header and alignment padding can waste
substantial space for small objects. SQLite needs an additional small-block
layer or a different allocator adapter before claiming efficient support.
This decision does not select the final application allocation strategy.

## Backing storage and tree

Each owner keeps its 64-byte bootstrap and two 65,728-byte preemptible boot
buffers. Transfer the rest of its external arena to its reusable heap.
The boot arena then reports all capacity consumed: most of that storage
is backing transferred to the reusable heap, not live application data.
No backing remains available to the old bump API.

The heap backing has a 64-byte guard at each end. A complete binary tree
occupies its prefix after the first guard. Leaves are rounded up to a
power of two; only complete 64-byte payload units are initially free.
Padded leaves remain unavailable. Non-power-of-two capacity is represented
by a forest of maximal free blocks rather than discarding a large suffix.
The tree uses one byte per node and includes an unused node-zero slot.
All tree bytes and allocation headers live in PSRAM; descriptors and final
reports remain internal. Owner descriptors have separate 64-byte strides.

A free node records the largest free block order plus one. Zero means no
available block. An allocated node records an allocation marker and order;
its descendants are ignored until the block is released. Allocation searches
one path, validates ancestors, marks the selected block and updates parents.
Free validates the handle/header/path, releases the block and coalesces by
updating parents. Both operations preserve unavailable leaves.

Every selected allocated or wholly free block must fit the actual payload
span, even when a forged tree value claims a larger block. This explicit
check prevents a plausible metadata marker from authorizing an out-of-span
header access. Invalid handles never authorize dereferencing their supplied
pointer; headers are derived from checked node geometry and the supplied
pointer/length is compared against them.

## Bounds and synchronization

`mhartid` selects one heap. A local interrupt mask serializes allocation
and free among preemptible tasks, restoring the original MIE state on every
return path. Interrupt handlers do not allocate. There is no shared heap
lock or remote free queue. A foreign owner, double free, interior/wrong-size
slice or stale ticket is rejected before release. Tickets do not wrap;
exhausting the 64-bit serial fails explicitly. Tickets detect stale frees
within one heap lifetime, not stale payload accesses or arbitrary memory
corruption. Machine-mode tasks still share authority.

Heap initialization is linear in tree size and happens only at boot.
CPU1's release wait and the new two-owner initialization rendezvous each
allow one billion cycles. Request/reply waits retain their 100-million-cycle
budget. Neither scheduler timer starts until both reusable heaps are ready.
These are cycle budgets, not calibrated wall-clock deadlines.

Runtime allocation visits at most `3 * levels + 2` metadata nodes, including
search, path validation and ancestor updates. Free needs at most two paths.
Supported layouts have at most 19 levels, hence at most 59 node visits.
Each operation also performs a fixed 128-byte guard check and constant
header/accounting work. Payload filling and verification occur outside the
interrupt mask. `max_steps` measures node visits, not instructions, cache
misses or interrupt latency. Physical latency remains unmeasured.

Detected guard/path corruption poisons the heap. Range/alignment/OOM and
invalid-handle errors do not consume capacity. Path validation does not
constitute a full integrity scan or cryptographic metadata protection.

## Qualification

Host tests cover alignment, exhaustion, isolated-leaf fragmentation and
buddy coalescing, exact initial-tree recovery, invalid requests/owners,
interior/wrong-length/foreign-heap/double/stale handles, guard/tree faults,
forged allocated/free out-of-span nodes and serial exhaustion. Deterministic
4,000-operation churn checks live data, nonoverlap and recovered capacity.

Both native workers repeatedly replace variable-size aligned allocations
under timer preemption. Invalid allocation and double-free paths are also
checked with MIE enabled; bootstrap error checks cover MIE disabled. After
workers retire, their remaining handles are verified/freed. Greedy maximal
allocations exhaust the free forest in at most `levels + 1` operations,
then reverse frees must restore all payload capacity with zero live blocks.
Each owner requires 13 rejected operations and equal allocation/free counts.
The rejection counter uses atomic increments because both preemptible
workers contribute to it outside the allocator's interrupt mask.

`NIHOS_NATIVE_HEAP` reports both owners, exact backing/tree/payload bounds,
full capacity recovery and the node-visit bound. No die requires two zero
records and an explicit `NotReady` allocation failure. Existing scheduler,
FP, IPI, SRAM, PSRAM mapping and command/cache gates remain required.
Final internal completion is published after both external checks finish.

## Remaining application boundary

The largest allocatable block is the largest free buddy, not total free
capacity. In the 32 MiB layout its raw size is 8 MiB per owner, before header
and padding. A larger contiguous Quake hunk needs a separately planned
extent/arena or a revised partition policy. It must not overlap heap backing.
Cross-core payload sharing still needs publication/ownership discipline;
free stays on the allocating hart. Migrating tasks, automatic task/service
cleanup, realloc, cross-core frees and C/SQLite integration remain future work.
No physical device was accessed; silicon timing/coherency and DMA are not
inferred from host or emulator results.

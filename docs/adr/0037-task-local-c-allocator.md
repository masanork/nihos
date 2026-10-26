# 0037: Task-local C allocator and host SQLite memory qualification

Status: accepted for native C/emulator and host-only SQLite qualification;
physical C and native SQLite qualification pending, 2026-10-26.

## C boundary

`include/nihos_allocator.h` exports explicit `nih_task_allocator_open(count)`
and `close`, plus `nih_task_malloc`, `realloc`, `free`, `capacity` and `roundup`.
This bounded API supports eight-byte alignment and requests up to 4096 bytes.
It is not a general libc allocator for types with stricter alignment. It does
not replace any libc symbol. Count is a separate fixed quota for each of the
ten existing classes. One parent and one ledger entry cover the whole pool;
there is no growth, larger-class fallback or cross-owner free.

A native task binds one pool in internal SRAM at its scheduler slot and task
generation. The API takes no caller-supplied context pointer. Every memory
operation checks initialized hart, enabled MIE, active current task, live
parent, storage kind and parent ticket before reading PSRAM metadata. A class
range and stride establish the exact cell payload start before inspecting its
header. The allocator never dereferences the submitted pointer. A bounded
class search reconstructs the cell's live ticket and authenticated length.

Nonzero allocation/resize failure returns null; free/close/open return -1 on
rejection. Capacity returns zero for rejected pointers. Zero allocation and
`realloc(null,0)` return null. `free(null)` succeeds without a pool, and
`realloc(p,0)` frees a valid p. `roundup` is a pure class lookup, returning zero
for an unsupported request. Positive resize failure preserves the old buffer.
New bytes are uninitialized. Fresh and freed interior/foreign pointers fail.

Capacity reports all usable class bytes. The C layer therefore allocates a
full class, retains that full logical extent on in-place shrink, and copies
all old usable bytes on a move. This matters when a caller writes bytes above
its original request after querying capacity. Copying only the original
request would lose valid data. The typed Zig API retains its exact-length
contract; its handles must not be mixed with the private C pool in production.

Raw C addresses have no caller-carried generation/ticket. A stale address can
alias a later allocation at the same address, including after pool reuse, and
will then refer to the new live cell. This API cannot detect that misuse or
prevent stale payload access. The typed Zig API still rejects stale tickets.
Neither interface provides memory isolation or cryptographic integrity.

## Scheduling and close

One task serializes its calls; migration and shared pools are unsupported.
Local interrupt masking covers bounded metadata work only. Existing two-phase
pool initialization and moving resize keep linear initialization/copies outside
the mask. C operations reject MIE-disabled calls; the pure roundup and null
free cases need no heap access. Return paths preserve incoming MIE.

Task close clears its SRAM C binding while marking the ledger closed. Deferred
cleanup releases the opaque parent without reading its child state or calling
C destructors. A task stopped during initialization or a moving copy cannot
resume after reclamation; scheduler slot/stack reuse still waits for cleanup.
Explicit C close invalidates all outstanding pointers. Libraries needing
semantic shutdown must run that shutdown before task exit. No attempt is made
to continue a globally initialized library after its owner is killed.

Native integer, raw-FP and ILP32F compiled profiles all link the same C caller.
Both busy workers on each populated hart exercise it and retain eight C bytes
until deferred cleanup checks them. Host tests separately cover foreign-task
pointers, retired bindings, exact geometry, metadata faults, and parent recovery.
The previous typed move/termination interleaving tests remain applicable. This
stage does not claim a newly observed timer interrupt or forced termination
inside a particular C copy.

## SQLite boundary

A host-only probe uses unmodified, SHA3-256-pinned official SQLite 3.54.1 and
these same exported C functions as `sqlite3_mem_methods`. The xMalloc/xFree/
xRealloc/xSize/xRoundup signatures are exercised by actual SQLite. xInit opens
the owner pool and xShutdown closes it only after all live library allocations
have been released. The callbacks and their lifetime policy are probe code,
not an installed native database service.

SQLite is built with `THREADSAFE=0`, `OS_OTHER=1`, memory-only temporary state,
1024-byte pages, no automatic initialization, no lookaside, no WAL and no
loadable extensions. The probe explicitly initializes/shuts down from one
host context. Its test VFS denies file opens and paths and supplies deterministic
random/time stubs; it qualifies no persistent storage or production entropy.
All query state uses `:memory:`. This is a dependency/allocator experiment before
the native-link and persistent-VFS stages of ADR 0002.

The minimal workload selects 42, creates a table, commits two rows and checks
an aggregate. A separate run fails each baseline allocation call, accepts
SQLite success or NOMEM, verifies all live allocations/outer parents are
released at shutdown, and reruns the entire workload successfully. The probe
records request sizes, class peaks and reservation thresholds. None of these
64-bit-host sizes is a native RV32 SQLite footprint or timing measurement.

## Next dependencies

Uniform class quotas overreserve badly for the measured workload. Per-class
quotas should be evaluated against allocation traces and adversarial OOM tests
before choosing service memory budgets. Requests above 4 KiB, contiguous
lookaside/page-cache buffers and application/query limits need separate policy.

Native SQLite also needs a bounded C runtime port, executable placement and
final Flash/SRAM/stack measurements. The current Flash whitelist still permits
only two CPU0 boot functions, so SQLite has not been linked into native images.
A real sqld requires a single global SQLite owner, initialization/shutdown and
cancellation semantics, bounded RPC and a storage-owned VFS. Persistent use
also requires host VFS fault injection, Flash/cache pause coordination and
physical recovery tests. A successful memory query substitutes for none of
these dependencies. No hardware setting or Flash layout changed here.

## References

- [SQLite allocator callback contract](https://www.sqlite.org/c3ref/mem_methods.html)
- [SQLite allocation configuration](https://www.sqlite.org/malloc.html)
- [SQLite public-domain dedication](https://www.sqlite.org/copyright.html)
- [Measurements](../measurements/2026-10-26-native-c-allocator.md)

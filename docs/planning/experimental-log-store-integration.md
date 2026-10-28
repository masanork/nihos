# Experimental log-store integration boundary

The host-testable engine can enter main as an experimental library while the
native application continues using its existing boot and storage paths.
Importing `experimental_storage` does not mount a volume, register a VFS,
allocate a runtime workspace or enable a native fixture. This is the first
integration stage of the [unified log-store proposal](unified-log-store.md),
not acceptance of a new default filesystem or a stable persistent format.

## Included scope

The modules under `src/storage/experimental.zig` provide a finite publication
model, a fixed-size regular-file host backend, the paged checkpoint/COW engine,
and its serialized copy-owned service core. They include extent maps, sparse
resize, bounded batches/search, reader pins, maintenance admission, recovery
headroom, checked deadlines, and stop/drain bookkeeping.

The sources and their existing unit tests were transferred unchanged from
the qualification tree at `ef7eec4` (the full source commit and per-file
SHA-256 values are recorded in the integration receipt). Main adds a module
entry point and host test import; it does not enable a storage service task.
RV32 probes compile the core and service against main's timer/ring types as
part of static analysis. They do not execute device I/O or authenticate native
completion events.

Tests cover finite corrupt/torn publication, COW/GC, pin lifetime, cancellation,
and rollback/reserve scenarios. They are executable model evidence, not a
physical sync or power-loss guarantee. Real SQLite host VFS and exhaustive
SQL allocation-fault campaigns remain separate tooling in the qualification
branch and are not run by this change's CI.

## Native evidence is candidate-specific

The earlier isolated native qualification used 1 MiB of PSRAM media, a 2 MiB
workspace, 4 KiB SQLite pages, and an 8 KiB CPU0 bootstrap stack. After fixing
page-sized stack copies and inlining, one exact candidate passed four warm
boots; the observed lease stack use was 6,152 B. Those logs do not validate a
new main-based binary, a 4 KiB worker stack, storage-owner IPC, or combined UI
and network load. Cold OFF/ON was not qualified. Native write/sync, persistent
SQLite, WAL and physical power-loss recovery remain open.

## Following stages

1. Integrate the real SQLite host VFS/fault/OOM tools with bounded CI fixtures.
2. Rebase the opt-in native PSRAM fixture onto current main, reconcile timer,
   allocator and task ownership, and build a new identity-bound candidate.
   Measure stack/heap, repeated resets, and an operator-confirmed cold boot.
3. Bind the service to native tasks/IPC and trusted completion events, aligning
   it with the existing VFS lifetime work. Choose service stacks and admission
   budgets from measured combined workloads.
4. Add a writable SD backend with truthful persistent sync. Qualify a small
   update/commit/reboot/readback workflow, faults and physical power loss before
   promoting persistent SQLite. WAL remains a later contract.

The development memory budget and filesystem proposal remain candidates. No
storage claim here authorizes treating a CPU fence as media persistence or
releasing a reader merely because its deadline expired.

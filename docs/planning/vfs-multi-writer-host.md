# Multi-client VFS write prototype

This host-only prototype routes two bounded copied request queues through one
VFS instance, one mount, and a single synchronous backend owner. It opens
existing files with write rights; it does not create or rename files. Stable
backend identities let the shared VFS reject a conflicting reader or writer,
including aliases of the same file. Independent files can be opened and written
by different principals. A full reply queue does not block the other lane.

The trusted caller binds a principal and receives an epoch. Requests carry that
epoch and a per-binding sequence; replies echo both. The caller must stop the
producer and ensure the backend callback has returned before `stop`. Cleanup
closes that lane's files, drains its queues, and preserves the other lane. A
failed close quarantines the session. Backend write timeout is reported as
`outcome_unknown` and a faulted mount stops both lanes. This is not rollback or
proof that a timed-out write had no effect. Payloads are copied and cleared from
the owner's working frames after dispatch or cleanup.

Run `zig test -O ReleaseSafe src/vfs_multi_writer_host_test.zig`. Tests cover
independent writes, alias conflict, foreign handles, reply backpressure, exit,
rebind, sync, unknown write outcome, and failed cleanup. The fake backend and
serialized host tests do not establish durability or actual concurrent device
execution.

This is not connected to normal_fs, FatFs, sqld, a native scheduler or DMA.
Before native use, define admission and memory budgets, authenticate kernel
identities, implement IRQ-safe exit notification and in-flight I/O fencing,
coordinate raw sqld ownership, validate real backend write/sync and media-change
semantics, and add native and physical SD/power-failure qualification. File
creation, rename, durable replacement, and same-file concurrent writers are
outside this prototype.

# Multi-client VFS write prototype

This host-only prototype routes two bounded copied request queues through one
VFS instance, one mount, and a single synchronous backend owner. It opens
existing files with write rights; it does not create or rename files. Stable
backend identities let the shared VFS reject a conflicting reader or writer,
including aliases of the same file. Independent files can be opened and written
by different principals. A full reply queue does not block the other lane.

The trusted caller supplies a nonzero, never-reused service session ID, binds a
principal and receives an epoch. Requests carry the session, epoch and a
per-binding sequence; replies echo all three. File handles carry the session as
well, so unchanged stale copies are rejected after rebuilding the service even
if internal VFS slots and generations repeat. These values are correlation
tags, not unforgeable capabilities: callers are trusted and must not relabel old
handles. The prototype does not generate or persist unique session IDs. The caller must stop the
producer and ensure the backend callback has returned before `stop`. A trusted,
serialized `markRemoved` stops both lanes and marks the mount removed; it does
not synchronize an IRQ or establish a device/DMA fence. Cleanup
closes that lane's files, drains its queues, and preserves the other lane. A
failed close quarantines the session. Backend write timeout is reported as
`outcome_unknown` and a faulted mount stops both lanes. This is not rollback or
proof that a timed-out write had no effect. Payloads are copied and cleared from
the owner's working frames after dispatch or cleanup.

Run `zig test -O ReleaseSafe src/vfs_multi_writer_host_test.zig`. Tests cover
independent writes, alias conflict, foreign handles, reply backpressure, exit,
rebind, sync, unknown write outcome, and failed cleanup. A test-only adapter also
writes and syncs two real temporary host files and verifies their contents after
closing and reopening them. The adapter uses a fixed identity mapping, not a
general filesystem backend. These serialized host tests do not establish
physical durability or actual concurrent device execution.

This is not connected to normal_fs, FatFs, sqld, a native scheduler or DMA.
Before native use, define admission and memory budgets, authenticate kernel
identities, implement IRQ-safe exit notification and in-flight I/O fencing,
coordinate raw sqld ownership, validate real backend write/sync and media-change
semantics, and add native and physical SD/power-failure qualification. File
creation, rename, durable replacement, and same-file concurrent writers are
outside this prototype.

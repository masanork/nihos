# Multi-client VFS write prototype

This host-only prototype routes two bounded copied request queues through one
VFS instance, one mount, and a single synchronous backend owner. It opens
existing files with explicitly granted read and/or write rights; it does not create or rename files. Stable
backend identities let the shared VFS reject a conflicting reader or writer,
including aliases of the same file. Independent files can be opened and written
by different principals. A full reply queue does not block the other lane. The
trusted binder supplies each lane's maximum rights, and open requests cannot
amplify them. Each copied read or write carries at most 512 bytes. A caller must split larger
transfers into multiple requests; the service does not provide an atomic
multi-chunk operation or automatic retry. Read replies zero their unused tail
and discard all bytes and transferred counts when a read fails.

The trusted caller supplies a nonzero, never-reused service session ID and a
shared issuer retained across service rebuilds. Requests carry the session,
epoch and per-binding sequence; replies echo all three. The owner issues a
monotonically increasing token and stores its mapping to the internal VFS
handle in the bound lane. A stale token remains absent after a rebuild even if
its session field is relabelled. Exhaustion fails before backend lookup; an
unsuccessful open burns its reserved token.

The issuer has one serialized trusted owner. It must not be copied, reset,
reused concurrently or recreated while older tokens can return. IDs are
predictable and are not unforgeable capabilities; this model does not provide
untrusted-client authorization or persistent uniqueness across reboot. The caller must stop the
producer and ensure the backend callback has returned before `stop`. A trusted,
serialized `markRemoved` stops both lanes and marks the mount removed; it does
not synchronize an IRQ or establish a device/DMA fence. Cleanup
closes that lane's files, drains its queues, and preserves the other lane. A
failed close quarantines the session. Backend write timeout is reported as
`outcome_unknown` and a faulted mount stops both lanes. This is not rollback or
proof that a timed-out write had no effect. Payloads are copied and cleared from
the owner's working frames after dispatch or cleanup.

Run `zig test -O ReleaseSafe src/vfs_multi_writer_host_test.zig`. Tests cover
independent reads and writes, rights attenuation, alias conflict, foreign handles,
reply scrubbing on backend errors, two manually chunked 4 KiB transfers,
write-after-effect failure, reply backpressure, exit,
rebind, sync, unknown write outcome, and failed cleanup. A test-only adapter also
writes and syncs two real temporary host files and verifies their contents after
closing and reopening them. The adapter uses a fixed identity mapping, not a
general filesystem backend. These serialized host tests do not establish
physical durability or actual concurrent device execution.

After both producers have stopped and their lanes have been cleaned up, trusted
owner code can shut down a read-only mount and start a new session. Surprise
removal permits quiescent detach without further backend calls; the caller must
destroy mount-local backend tokens before workspace reuse. Failed cleanup
retains the mount even if media is subsequently marked removed. Writable
mounts created with `start` have no volume-sync capability, so shutdown returns
Unsupported. A trusted backend may instead explicitly promise volume sync via
`startWithVolumeSync`. After both lanes are stopped and all files close, shutdown
then calls the backend's volume sync; failure retains the faulted mount even if
media is later marked removed. The isolated host FatFs fixture performs
`CTRL_SYNC` only after all files close and tests failures before and after host
`fsync`. This is not a physical durability or raw-storage handoff guarantee.
The host interface does not stop a live producer or establish device quiescence.

This is not connected to normal_fs, production FatFs, sqld, a native scheduler or DMA.
Before native use, define admission and memory budgets, authenticate kernel
identities, budget the larger copied response queues, implement IRQ-safe exit
notification and in-flight I/O fencing,
coordinate raw sqld ownership, validate real backend write/sync and media-change
semantics, and add native and physical SD/power-failure qualification. File
creation, rename, durable replacement, and same-file concurrent writers are
outside this prototype.

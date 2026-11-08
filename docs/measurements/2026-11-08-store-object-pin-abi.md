# Serialized store ABI object pins

The store owner ABI now exposes object-specific pin and bounded copy-out read
operations. A pin captures one committed object version, refuses admission
while a transaction is staged, and shares the existing four reader slots and
monotonic token allocator with volume snapshots. An object token cannot be used
as a volume snapshot or restore target. Tokens are scoped to one mounted store
instance and are not authenticated client or cross-mount capabilities. The
owner must serialize operations and keep a pin until every reader and device
callback has drained. Reads use the owner's existing page scratch buffer.

A host C-ABI test pins an object, replaces and then removes it, performs
collection, and confirms the pin still reads the original bytes. It also tests
staged admission rejection, short/end reads, oversize requests, snapshot/object
token separation and release/stale token rejection. This test uses modeled
host media, not native SD.

This does not increase the existing native 4 MiB region or the 1 MiB object
write limit. The 5,129,285-byte dictionary still cannot be installed there.
The workspace queue is not yet connected to this ABI; native owner admission,
shared memory, I/O drain and a separately designed non-destructive capacity
migration remain necessary. No device or physical power-cut test was run.

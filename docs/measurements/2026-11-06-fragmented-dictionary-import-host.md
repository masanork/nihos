# Fragmented mapped-object import: host model

This experiment evaluates the existing experimental checkpoint/COW store as a
way to publish a dictionary without a single contiguous payload run. It does
not add a production importer or a new storage format. The store is still a
host model, and this work is not SQLite WAL integration, an allocator-wide
reservation, an SD qualification, or evidence about physical power loss.

The bounded fixture deliberately leaves ten free pages, each separated from
the next, with a largest run of one page. A contiguous stream needing several
pages is refused. The experiment creates a staged empty object, gives it a
mapped length, and fills it in ordered page-sized batches using scattered
allocation searches. Each search preserves one page of free headroom. Readers
see no new object until one commit publishes the completed map; a pinned old
root stays readable. The selected individual searches do not reserve all
future import allocations, checkpoint or GC work. A later search can still
fail, in which case the caller must roll the staging transaction back.

A separate test forces that mid-import admission failure and verifies rollback
and recovery. For an acknowledged import, the fixture tests all 138 modeled
write/sync events with a 31-byte torn-write prefix, under both no-background
and all-background persistence: 276 crash cases. Each recovered image had the
old state or the complete new object, and the pre-existing object was intact.
These are two specified writeback models, not an exhaustive real-card test.

An opt-in host-file test uses the same 5,129,285-byte NFST input identified in
[the paged-reader report](2026-11-06-paged-dictionary-host.md). With initially
free space it imports 79 batches of at most 16 data pages into a single staged
mapped object, publishes, closes/reopens, verifies the store checksums, and
compares SHA-256 over every input and recovered byte. It then uses the paged
reader to look up 漢字. The run recorded 80 bounded allocation-search steps
(budget: eight leaf visits and 128 bitmap pages each). This full-size run did
not create a fragmented 5 MiB allocation; that condition is covered only by
the small, deliberately fragmented fixture. Neither search-step counts nor
host timings predict Tab5 latency.

```sh
.tools/zig-0.17.0/zig test -O ReleaseSafe src/storage/fragmented_import_test.zig
NIHOS_NFST_PATH=/path/to/jisyo-l_nfst.bin \
  .tools/zig-0.17.0/zig test -lc -O ReleaseSafe \
  src/storage/fragmented_large_host_test.zig --test-filter 'large NFST staged'
```

The next implementation must define a copied, cancellable owner/IPC import
protocol and enforce a transaction-wide capacity plan against all writers,
including map/index/checkpoint/GC and WAL costs. Per-batch headroom is a
check, not a durable reservation; the current tests must not be used as one.

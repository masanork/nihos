# Unified log store for SQLite pages and blobs

Status: planning proposal, revised for Tab5 scope on 2026-10-27; not an accepted
ADR. The common engine is an experimental direction, not a prerequisite for
the first useful development/learning release. See the
[Tab5 feasibility and budget](tab5-storage-feasibility.md) for memory limits,
release scope and promotion gates.

## Motivation

nihos should be able to persist SQLite databases and ordinary binary objects
through **one small, readable Zig log-structured storage engine**. SQLite is a
system service, not the filesystem's metadata engine. Database pages, blob
chunks and filesystem metadata can share the same append-only segment format,
checkpointing, snapshots and garbage collector.

The default persistent SQLite volume is **microSD**, not the Tab5's internal
Flash. The internal Flash should eventually use the same *logical* store, with
a raw-NOR-specific media backend, for small settings and a self-contained
minimum system. Boot must not require microSD, SQLite, or a healthy writable
filesystem. The bootloader, firmware image and recovery path remain outside
any store-managed erase or GC region.

This is an exploration of a NILFS2/F2FS-style log and history model, with
copy-on-write/checkpoint ideas from other filesystems. It is **not** a claim to
implement those filesystems, nor a plan to clone WinFS. Existing littlefs and
FAT/exFAT ideas remain fallbacks and interoperability options pending tests.

## First delivery scope

Tab5 can support a bounded common-log experiment, but the complete feature
set below is a longer-term program. Qualify a single-writer SD implementation
with bounded map caches, recovery and GC before adding SQLite persistence.
Keep existing filesystem adapters behind VFS so development/learning workflows
do not depend on completion of a new filesystem. Existing adapters also need
writable durability tests; current read-only qualification is not sufficient.

The initial store has no user-retained snapshot history, multiwriter API,
WAL, batch-atomic optimization, cross-blob/SQL atomic transaction or NOR
backend. Read-version pins and crash-safe cleaning remain correctness
requirements. SQLite starts with ordinary rollback-journal semantics; blob
bytes become durable before their reference is committed in SQLite.

A flat RAM map is only a bounded host-model step. Large SD volumes require
an on-media map and bounded cached pages before promotion. Do not preallocate
an entry for every card sector or promise full-volume replay at normal boot.
Store geometry and space reserves remain candidates until fault, memory and
latency tests pass. Boot and recovery remain independent of SD and SQLite.

## Current baseline and compatibility

- [Architecture](../architecture.md) currently proposes littlefs for internal
  NOR and FAT/exFAT for SD. This planning note **does not supersede** that
  document or establish a new storage ADR.
- [ADR 0002](../adr/0002-smp-services.md) establishes the single-owner
  storage/SQLite service direction and rollback-journal `PERSIST`, full sync
  as the initial durability baseline. It explicitly defers WAL and concurrency.
- [ADR 0040](../adr/0040-bounded-single-owner-sqlite-session.md) qualifies
  only a bounded **in-memory**, single-owner SQLite host prototype with a
  no-I/O VFS. Its 1024-byte database pages and other limits are prototype
  parameters, not persistent-store decisions. A later, unmerged native
  qualification snapshot is described in the [Tab5 assessment](tab5-storage-feasibility.md).
  Neither that snapshot nor this planning note qualifies writable SQLite VFS
  or physical power-failure durability.

Design and measurements must distinguish a host model, emulator execution,
ESP-IDF-hosted hardware work, and genuine native/physical durability evidence.

## Proposed boundaries

```text
     applications / Scheme / file handles
                |                 |
          sqld service       blob/file service
        (single owner)       (bounded handles)
                |                 |
         SQLite VFS          blob/file adapter
                \                 /
            storage-owner service
      transactions / page map / object map
         append log / checkpoint / GC
                |                 |
         microSD backend      raw NOR backend
           (block/FTL)        (erase/program)
```

SQLite continues to own SQL, B-trees, query execution and its pager contract.
The Zig store owns durable record placement and recoverable object versions.
The SQLite VFS translates SQLite's **logical files and byte offsets** into
the store; an SQLite page is an important workload unit but the VFS must not
assume that every `xRead` or `xWrite` is a complete aligned page.

At minimum distinguish:

- `DbFileId + logical offset/page`: SQLite database image and any required
  rollback-journal or WAL-related file representation.
- `BlobObjectId + chunk index`: opaque blobs, optionally exposed through
  ordinary file names and directory metadata.
- `StoreTxId`, `Generation`, `SegmentId`: commit visibility, snapshots,
  physical placement and collection.

Logical file size, deletion, truncation, names and object metadata are also
transactional records. A database should remain exportable as an ordinary
SQLite database image; private on-media page maps must not alter SQLite's
logical file format.

The **same engine** can format independent internal-NOR and microSD volumes.
They need not use identical segment/erase geometry. A commit or snapshot is
atomic **within one volume only**; no cross-device transaction guarantee is
proposed.

## Record and commit model (sketch)

```text
[segment header: generation / geometry / checksum]
[DB_PAGE or FILE_RANGE: object / offset / payload / checksum]
[BLOB_CHUNK: object / chunk / payload / checksum]
[OBJECT_META: size / directory / version / tombstone]
[COMMIT: tx id / new root references / checksum]
[CHECKPOINT: generation / committed roots / checksum]
...
```

These are conceptual record types, not a frozen binary on-disk format.
Use checksummed records, generation numbers and references sufficient to
reject torn or incomplete updates. Commit processing must impose a provable
order between data persistence and publication of new roots. Recovery must
select the latest **valid, durable** checkpoint and replay only fully
committed, valid records; it must not treat an unchecked log tail as committed.

Start with a bounded in-memory index for the host model. Before a usable
large-volume SD gate, add persistent page/object maps, a bounded map cache and
checkpoint summaries that limit tail replay. Full media scanning is an explicit
repair path rather than the normal mount algorithm.
The format needs an explicit version, endianness, extent bounds and upgrade
policy. Never make SQLite responsible for mounting, recovering or GC'ing the
store itself; this avoids a boot/recovery dependency cycle.

## SQLite durability and optimization sequence

**First: correctness with the documented SQLite contract.**

- Implement the SQLite VFS functions actually needed by the chosen journal
  mode: open, close, read, write, file size, truncate, delete, sync, lock,
  file-control and error mapping, with truthful device characteristics.
- Keep one SQLite connection owner through `sqld` initially; define ownership,
  cancellation and partial-I/O behavior. A storage-owner service serializes
  durable operations without leaking a controller or cache-off section into
  application tasks.
- Begin with rollback journal `PERSIST` and `synchronous=FULL`, consistent
  with ADR 0002. The store must give `xSync` meaningful **persistent**
  semantics including the metadata needed to locate and replay file changes.
  SQLite's journal must be preserved as long as the VFS cannot prove a
  replacement atomic-write contract.
- Do not claim `SQLITE_IOCAP_ATOMIC*`, `SAFE_APPEND`,
  `POWERSAFE_OVERWRITE` or batch atomic capability on the basis of LFS/COW
  alone. Hardware ordering, fault tests, and SQLite's exact documented
  requirements determine these declarations.

**Then: optional direct atomic-batch writes.**

SQLite has a compile-time-gated batch-atomic-write path (for suitable rollback
journal configurations) using `SQLITE_IOCAP_BATCH_ATOMIC` and
`SQLITE_FCNTL_BEGIN_ATOMIC_WRITE`,
`SQLITE_FCNTL_COMMIT_ATOMIC_WRITE`, and
`SQLITE_FCNTL_ROLLBACK_ATOMIC_WRITE`. Investigate a VFS adapter that maps
those operations to store transactions, thereby avoiding *some* double
journaling. This is conditional optimization, **not** a property automatically
supplied by a custom VFS, and not a general WAL replacement. Confirm the
SQLite build, journal mode, error paths, and post-crash invariants before
enabling it.

WAL and simultaneous readers are separate work. They require correct
wal-index/shared-memory and locking semantics (or a deliberately constrained
exclusive single-owner configuration), and add WAL reset/reuse and checkpoint
write patterns. Do not promise an arbitrary SQLite file plus unrelated blob
are atomically committed merely because SQLite batch atomic writes are on.

## Blob API and later cross object transactions

Support blobs directly, without wrapping the whole SD card in a littlefs
image. Initial operations can be:

- create immutable blob / stream chunks / read range / delete or replace;
- optional names and a file-like offset interface over chunked COW objects;
- bounded handles and I/O buffers for the native system-service ABI;
- generation-pinned reads for consistent snapshots.

**Safe first-stage SQLite/blob integration:** write a new immutable blob,
ensure the blob is durable, then commit its object ID/reference in SQLite.
A failed SQLite transaction leaves an orphan for later GC; it does not leave
a committed SQLite row pointing to unwritten data. Never reclaim blobs solely
because no reference is found in the latest DB page map: older snapshots and
in-flight readers may retain them. Define a safe reachability/retention policy
before automatic reclamation.

**Deferred beyond the initial store:** expose a store-level coordinator that stages DB page changes and
blob versions under one `StoreTxId`, publishes exactly one commit root, and
can rollback both. SQLite's pager/VFS transaction boundaries must be
coordinated explicitly; cross-object atomicity does **not** emerge from merely
putting the data types in one log. First verify this in a single-volume,
single-writer model before exposing an application-wide transaction API.

The API might eventually support an operation conceptually like:

```text
begin()
  blob.put(document_bytes)   -> blob_id
  sql.execute("INSERT ...", blob_id)
commit()   # one recoverable logical generation, once implemented
```

This is an aspiration, **not a working SQLite API**.

## Snapshots, GC and media-specific constraints

- Retained generations allow old file and SQLite page versions to be read,
  but retention is finite/policy-controlled; long-lived readers pin versions.
- GC copies only live records to fresh segments, commits the new references,
  and **then** erases/reclaims old segments. It must preserve all active
  snapshot roots and in-flight transactions. A reserve of clean segments is
  mandatory; low-space states fail safely or become read-only, not corrupt.
- On internal raw NOR, respect erase-before-program, page-program geometry,
  cache/PSRAM restrictions on ESP32-P4, erase-count distribution, and the
  existing Flash boot whitelist. Keep GC outside firmware/boot partitions.
- On microSD, the internal FTL is opaque. Sequential logical writes may help
  but do not guarantee physical sequential writes or wear leveling. Flush/
  sync and power-loss behavior must be tested with actual cards; a completed
  SD transfer does not by itself prove nonvolatile commit. Surprise removal
  should fail closed and invalidate stale handles/generations.
- A large SD allocation can defer cleaning and retain history, but cannot
  remove GC, mount-index, recovery-time, or snapshot-retention complexity.
- Do **not** nest the durable store as a single mutable `disk.img` under
  littlefs for normal operation: it duplicates COW/allocation/GC. File-backed
  images remain valuable for host tests.

## Proposed delivery gates

Development/learning applications can ship through qualified filesystem
adapters while the store passes these gates. The concrete memory/recovery
criteria and promotion decision are in the [Tab5 assessment](tab5-storage-feasibility.md#delivery-and-acceptance).
No device should be reformatted to evaluate this proposal implicitly.

1. **Specify observable invariants.** Record geometry, publication order,
   `sync`, recovery, space reserve, error and removal semantics; build a
   deterministic memory/file-backed media model and fault injector.
2. **Standalone Zig host model.** Append and read blobs/files, truncate/delete,
   rebuild a bounded object map, and recover committed changes after interrupted
   writes. Test data limits are explicit fixture parameters, not SD capacity
   promises. No long-lived user snapshots.
3. **Bounded SD index, checkpoint and cleaning.** Add the on-media map and
   bounded cache, alternate/rotate checkpoint roots and limit tail replay.
   Qualify crash-safe cleaning with active reader pins and near-full workloads.
   User-retained history remains deferred. Measure write amplification,
   recovery time, GC pauses and peak memory before promoting the volume.
4. **SQLite persistent VFS on host/microSD.** Preserve ordinary SQLite
   journal correctness first. Test transactions, rollback, reopening,
   `PRAGMA integrity_check`, schema/data stress and interrupted operations.
5. **Optional atomic-batch VFS and coordinated blobs.** Compare journaled
   and batch-atomic modes with identical crash tests and write amplification.
   Implement cross-blob/SQL commits only after SQLite boundaries are proved.
6. **Later internal-NOR backend.** Integrate safe Flash guards, bounded native
   service resources and partition protection; prove boot and recovery with
   the SD card absent. Physical-device qualification is a release gate.

Test **every injected write/erase/flush failure boundary**, including failures
during checkpoint and GC. Verify old-or-new committed state, never partial
published objects, SQLite database integrity and no references to reclaimed
blocks. Separately test unexpected power removal on real hardware and
removable-card behavior; host emulation cannot certify device FTL durability.
Measure bytes programmed/erased, write amplification, p95/p99 query latency,
SRAM/PSRAM peaks, GC pauses, mount time and SD-removal recovery.

## Open decisions

1. Whether the first LFS on-media format is segment/inode-log oriented
   (NILFS2-like) or a simpler COW object map with append-only records.
2. Logical chunk and segment sizes: SQLite workload pages vs large blobs,
   16 MB NOR constraints vs many-GB microSD, and Flash erase geometry.
3. On-card layout: dedicated ni hos store partition, plus optional exFAT
   exchange partition; partition format and formatting/recovery tools.
4. Precise transaction coordinator semantics: store-owner serialization,
   SQLite callback integration, reader snapshot isolation, and recovery.
5. Snapshot retention, orphan-blob detection, read-only low-space behavior,
   crash-safe GC and secure deletion expectations.
6. Whether internal NOR initially ships with littlefs as a fallback while the
   common Zig store is qualified, and what boot-time recovery UI is available.
7. Compatibility, migration/versioning, backups, removable-media trust and
   corrupted-card repair strategy.

## References

- [SQLite VFS](https://sqlite.org/vfs.html)
- [SQLite atomic commit](https://sqlite.org/atomiccommit.html)
- [SQLite WAL](https://sqlite.org/wal.html)
- [SQLite file control constants](https://sqlite.org/c3ref/c_fcntl_begin_atomic_write.html)
- [Linux F2FS](https://docs.kernel.org/filesystems/f2fs.html)
- [Linux NILFS2](https://docs.kernel.org/filesystems/nilfs2.html)
- [littlefs design](https://github.com/littlefs-project/littlefs/blob/master/DESIGN.md)

# Tab5 storage feasibility and initial scope

Status: planning revision, 2026-10-27. The unified store is feasible as a
bounded, single-writer experiment on Tab5. Making snapshots, a new filesystem,
SQLite transactions, blob transactions and two media backends prerequisites
for the first useful OS would put too much durability work on the initial
release. Keep the common log as a research direction, and qualify it in stages
alongside working filesystem adapters.

The standard workload is an editor, one language runtime, sensor logging,
Wi-Fi/AI assistance and one SQLite service. Media playback, multiple language
VMs and retained history are optional workloads with their own admission
budgets. [The unified-store proposal](unified-log-store.md) defines the
longer-term boundary; this assessment narrows its first delivery scope.

## Memory map and retained baseline

All ranges below are half-open. The device snapshot is ESP32-P4 rev1.3 with
32 MiB PSRAM and 16 MiB Flash. The retained loader selects a 128 KiB L2 cache.
The map follows the pinned
[ESP-IDF v5.4.4 definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/ld/esp32p4/memory.ld.in).
Other silicon/cache configurations require separate bounds.

| Range | Present role | Planning treatment |
| --- | --- | --- |
| `0x4ff00000..0x4ff28000` | 160 KiB resident code/data and low heap | Preserve; 104,192 B static and 59,648 B heap in the qualified image |
| `0x4ff28000..0x4ff40000` | Excluded loader/ROM area and safety gaps | Do not reclaim; the nearest retained loader allocation begins at `0x4ff2abd0` |
| `0x4ff40000..0x4ff60000` | 128 KiB unregistered high SRAM | Candidate for data pools after layout and physical cell tests |
| `0x4ff60000..0x4ff6e000` | 56 KiB native stack bank | Preserve during bring-up; expanded task admission needs additional stack space |
| `0x4ff6e000..0x4ffa0000` | 200 KiB unregistered high SRAM | Candidate for data pools after the same tests |
| `0x48000000..0x48030000` | 192 KiB reserved PSRAM mapping/handoff/workspace windows | Centralize ownership; growing a workspace must not overlap IPC or test words |
| `0x48030000..0x4a000000` | Registered PSRAM tail | Current two owner heaps expose 32,045,696 B payload in total |

The baseline candidate high RW window is 384 KiB, of which 56 KiB is already the stack
bank. The other 328 KiB is source-supported space, not a qualified heap.
Together with the 160 KiB low region, this gives a 544 KiB planning envelope;
it does not turn the chip's cache or ROM reservations into normal RAM.

The PSRAM payload is currently split into two 16,022,848 B owner heaps.
One CPU cannot borrow the other's free space. There is 1 MiB of buddy-tree
metadata plus reserved windows, guards and retained test buffers. A direct
4 MiB allocation with the current in-band header/alignment rounds up to an
8 MiB block; an exact 8 MiB payload would need a 16 MiB block, larger than
one owner's usable heap. Large VM/buffer budgets need page/extent leases or
external allocation metadata before an 8 MiB payload ceiling is useful.

The [retained evidence summary](tab5-memory-evidence.json) binds these numbers
to native source `1182a74` and its exact image hashes. That image passed three
USB RTS boots with SD reads, file reads, cancellation, endpoint replacement
and in-memory SQLite. These are not writable-store or power-loss results.

### Follow-up qualification, 2026-10-27

Local source `8a66e2689714bc48bac3edcb2df5101094d3f7d1` subsequently passed
three physical USB RTS boots under one exclusive serial descriptor, with
loader/table/app verification before and after capture. All 328 KiB passed
full-word pattern/inverse tests and CPU0/CPU1 exchange. A 208 KiB page pool
passed full allocation, stale/foreign lease rejection, four-worker use and
complete recovery. Its four software guard pages consume 16 KiB; the other
32 KiB and 72 KiB are reserved for future DMA and stack expansion respectively.
These reservations are not DMA transfers or stack admission implementations.

The qualified image has 112,128 B primary static and 51,712 B low heap.
Together with the new 212,992 B pool, gross internal heap reservation is
258.5 KiB. This supports the 256 KiB heap / 128 KiB stack layout arithmetic,
but the old 16 KiB unassigned margin is now a guard reservation. There is
no additional 16 KiB free region to spend. Keep the 64 KiB post-startup
free-heap admission requirement and remeasure resident growth per feature.

The same page allocator also passed exact 4 MiB and 8 MiB PSRAM backing
charges and full-word reads/writes in a temporary pre-heap window. Normal
PSRAM buddy heaps and their CPU split remain unchanged; retain their
conservative VM charge below until production broker integration is qualified.
The option defaults off and rejects emulator profiles. Existing SD/FS/RPC
cleanup/rebind and SQLite fixtures passed all three boots and fresh SDK
reference comparisons. This does not qualify writes, power loss or a full
development workload. The image and evidence are retained in
`/Users/masanork/Documents/Codex/2026-10-27/nihos-tab5-high-sram-qualification`;
these commits remain local and are not merged into upstream main.

## Standard admission budgets

Retain the development profile's 16 total tasks, eight storage clients,
32 global open objects, eight logical FDs per app and 16 global data-file
handles. FD aliases, directory cursors, device handles, file objects and
snapshot pins must be accounted separately. Multiple FDs may reference one
open object; 16 open files is not a limit of 16 persistent objects.

Use eight mount slots, increased from the earlier four-slot candidate. This
leaves room for immutable boot assets, internal settings, the SD store,
an exchange filesystem and devices. The exact namespace and partition layout
remain design decisions. A 512-byte path buffer and 4 KiB public I/O quantum
are interface budgets, not an on-media format or a SQLite page-size contract.
Directory enumeration needs cursors/bounded batches rather than a fixed
128-entry volume limit. Quotas belong to an application instance; task exit
must not revoke sibling tasks' still-live application resources.

| SRAM planning envelope | KiB |
| --- | ---: |
| Resident code and basic state | 112 |
| Task and IRQ stacks | 128 |
| Fixed DMA and I/O buffers | 32 |
| Reusable internal heap | 256 |
| Software guard reservation | 16 |
| Total | 544 |

The stack budget covers two 8 KiB bootstrap tasks, two 8 KiB heavy services,
one 16 KiB VM task, one 24 KiB network/TLS task, ten ordinary 4 KiB tasks and
two 8 KiB IRQ stacks. This revises the earlier 96 KiB candidate: the VM and
network/TLS call paths should not be admitted on ordinary 4 KiB stacks by
default. Exact port measurements may change those reservations. Admission must reserve stacks
before creating tasks and retain at least 64 KiB internal free capacity after
standard services start. Peak usage, largest free block and allocation failures
must accompany total-free statistics. These are proposed budgets; the current
56 KiB stack layout still needs admission/expansion work. The follow-up's
208 KiB high page pool establishes capacity without implementing the complete
application-facing heap or stack policy.

Keep interrupt/ROM-facing state and DMA staging internal. VM heaps, editor
buffers, filesystem maps/caches and RPC payloads belong in PSRAM when their
access paths permit it. Cache-sensitive operations need an explicit internal
working set and cross-core guard. Pinned IDF documents
[PSRAM/cache and stack restrictions](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-guides/external-ram.html#restrictions);
a native implementation must establish its own exact cache/ROM contract.

| PSRAM peak envelope | MiB |
| --- | ---: |
| Mapping, allocator metadata and guards | 2 |
| Single framebuffer and display working set | 2 |
| Editor/project buffers | 1 |
| One 4 MiB VM payload, charged at current buddy cost | 8 |
| SQLite service | 2 |
| VFS/RPC/I/O ceiling | 0.5 |
| Experimental store ceiling | 2 |
| Network/TLS/AI working set | 2 |
| Sensor/log buffers | 0.5 |
| Unassigned headroom | 12 |
| Total | 32 |

These are peak admission envelopes, not eager startup reservations or a proof
that every feature already fits. The framebuffer alone is 1,843,200 B in
1280x720 RGB565. A second framebuffer consumes another such allocation.
The old fixed CPU split and allocator rounding can prevent admission even
when the global sum fits; solve those constraints before advertising the
unassigned space as a shared pool. Charge actual backing allocations, including
slab/guard overhead, rather than only requested payload sizes.

Start SQLite around a 512 KiB service budget and permit growth toward 2 MiB
through quota admission. Its current 1024-byte pages, 16-page database and
small C size-class quotas are fixture limits, not the persistent DB design.
A 4 MiB VM payload is the standard target; an 8 MiB ceiling depends on the
large-allocation work. Do not reserve a second VM by default.

## Store indexing and bounded recovery

Use a 2 MiB ceiling for the experimental store, separate from the VFS/RPC
window and SQLite's pager/query memory. A candidate subdivision is 512 KiB
persistent-map cache; 64 KiB each for a resident transaction window, append,
GC and checkpoint buffers; 128 KiB each for recovery, summary cache and
metadata/handles; and 896 KiB remaining headroom. Mount, checkpoint and GC
must obey the same ceiling at their maximum overlap.

A flat map of assumed 16-byte entries per 4 KiB logical chunk costs:

| Mapped logical data | Flat entries only |
| --- | ---: |
| 64 MiB | 256 KiB |
| 128 MiB | 512 KiB |
| 1 GiB | 4 MiB |
| 4 GiB | 16 MiB |
| 16 GiB | 64 MiB |

This excludes hash slack, multiple versions, object names and segment maps.
Track live ranges rather than preallocating per card sector. A flat in-memory
map is suitable for a bounded host model. A usable SD implementation needs
an on-media map with bounded cached pages from the first large-volume gate;
adding that only after RAM exhaustion would force a format redesign.

Checkpoint roots must permit bounded tail replay. A complete 16 GiB scan takes
4 h 33 min at an assumed 1 MiB/s, or 34 min at an assumed 8 MiB/s. These are
arithmetic examples, not measured speeds. Healthy mount should target five
seconds, using a candidate tail-replay budget of 4 MiB plus bounded root/map
reads. If that target fails, change checkpointing or I/O, not boot correctness.
Boot/UI recovery must remain available while SD is absent, damaged or still
mounting. Full scans belong to an explicit repair operation with progress.

A 4 KiB logical chunk and 1 MiB SD segment are evaluation candidates only.
Do not freeze them into the format until partial VFS I/O, crash recovery,
write amplification and GC measurements have passed. A bounded resident
transaction window must not silently become a 64 KiB maximum SQLite
transaction or blob: larger changes need streaming/staging, charged space,
or an explicit recoverable resource error.

## GC and retention scope

First qualify one writer per volume, one active logical generation and no
user-retained history. Reads that pin versions still need explicit ownership,
release and quota accounting; they cannot be reclaimed merely because the
latest DB lacks a reference. Reserve internal roots separately from the
application reader-pin budget. A paused reader may cause writes to run out
of space; fail safely rather than revoking a committed reader silently.

Require clean space sufficient for the maximum unpublished update, live-data
copy of a GC victim, checkpoint publication and segment-transition slack.
Eight 1 MiB clean segments is a candidate reserve, not a general proof. For
example, 1 MiB unpublished + 1 MiB live copy + 64 KiB checkpoint + 2 MiB slack
fits; a larger streamed update may not. Reserve/admit space before accepting
writes, and use read-only/space-pressure errors when progress cannot be proved.
NOR will require different geometry and reserve calculations.

For uniformly sized payloads, an idealized cleaner that chooses a victim
with live fraction `u` has data-write factor `1/(1-u)`: 2x at 50%, 5x at 80%,
10x at 90%. This is the victim's live fraction, not overall card fullness,
and excludes journal, metadata and FTL costs. History retention can make
victims expensive even when RAM fits. Evaluate GC in bounded byte steps
(candidate 16 KiB); a byte quantum cannot guarantee an SD card's command
latency. Measure pauses and foreground p95/p99 instead of promising a hard
millisecond deadline.

## Initial release and deferred features

The first useful OS should retain filesystem adapters behind an independent
VFS, with storage-owner lifecycle and resource accounting reusable by either
backend. The architecture's littlefs/NOR and FAT/exFAT/SD direction remains
available. Writable adapters still need sync, full-media, removal and physical
power-loss tests. Current read-only littlefs evidence does not qualify them.
SQLite's normal database image must remain exportable whichever backend wins.

Keep the new Zig store on a bounded host model first, then a dedicated
experimental SD volume after recovery and cleaning gates. Start with
immutable blob/file ranges, metadata, checksummed commits, checkpointing and
safe GC. Add SQLite's ordinary rollback-journal VFS only after those invariants
hold. Use `PERSIST` and `synchronous=FULL` with meaningful metadata-inclusive
sync; the [SQLite atomic-commit contract](https://sqlite.org/atomiccommit.html)
requires persistence ordering, not merely completed block transfers.

Defer user history/snapshot browsing, multiwriter operation, WAL, SQLite batch
atomic optimizations, cross-blob/SQL atomic transactions and the common-store
NOR backend. Store COW does not establish SQLite atomic-write device flags.
The [WAL contract](https://sqlite.org/wal.html) adds locking, shared-memory or
exclusive-mode assumptions and checkpoint/reset behavior; it is a later gate.
Boot, firmware and recovery erase regions remain outside all store GC.

The native qualification app currently occupies 769,168 B of a 1 MiB factory
partition, leaving 279,408 B. Its SQLite/shared-code Flash span has only
65,408 B remaining. A language runtime plus writable VFS/FatFs and a new store
must have linked size budgets before integration. Do not adopt a new Flash
partition table from RAM arithmetic; app/OTA/recovery/settings sizes and
migration protection need a separate reviewed map.

## Delivery and acceptance

1. High SRAM cell/SMP/page-pool qualification passed on the exact retained
   loader/cache configuration. Integrate reusable internal pools with the
   general memory broker and add stack admission. Fix large PSRAM allocation
   rounding and quota accounting before integrating bigger application heaps.
2. Bring up ordinary VFS/adapters and development workflows independently of
   the experimental store. Verify app-owned handles, bounded buffers, media
   removal and meaningful sync before claiming writable durability.
3. Build a deterministic memory/file-backed store model. Inject every write,
   erase and flush failure, including commit/checkpoint/GC transitions; prove
   old-or-new visibility and rejection of torn roots/reclaimed references.
4. Qualify the bounded on-media index, tail replay and cleaner on an experimental
   SD volume. Check RAM peaks and foreground latency near full capacity and
   with paused readers. Repeat independent physical power-loss/removal tests.
5. Add SQLite `PERSIST`/FULL VFS, reopen/rollback and `integrity_check` stress.
   Keep blob-durable-before-DB-reference ordering; failed SQL may leave an
   orphan, never a committed reference to missing blob bytes.
6. Promote the store only if correctness, recovery/latency and memory gates
   pass on the development workload. Otherwise ship the adapter-backed path
   and retain the store experiment without blocking the useful OS.

[The budget model](tab5-storage-budget.json) is reproducible with
`python3 tools/storage_budget.py --output docs/planning/tab5-storage-budget.json`.
It validates envelope sums and exposes its assumptions. It does not measure
execution speed, code size of future features or physical durability.

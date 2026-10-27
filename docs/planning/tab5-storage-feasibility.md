# Tab5 storage feasibility and initial scope

Status: planning revision, 2026-10-27. The unified store is feasible as a
bounded, single-writer experiment on Tab5. Making snapshots, a new filesystem,
SQLite transactions, blob transactions and two media backends prerequisites
for the first useful OS would put too much durability work on the initial
release. Keep the common log as a research direction, and qualify it in stages
alongside working filesystem adapters.

The standard workload is an editor with kana/kanji input, one language runtime,
sensor logging, Wi-Fi/AI assistance, up to two BLE links and one SQLite service. Media playback, multiple language
VMs and retained history are optional workloads with their own admission
budgets. [The unified-store proposal](unified-log-store.md) defines the
longer-term boundary; this assessment narrows its first delivery scope.

## Memory map and retained baseline

All ranges below are half-open. The device snapshot is ESP32-P4 rev1.3 with
32 MiB PSRAM and 16 MiB Flash. The retained loader selects a 128 KiB L2 cache.
The map follows the pinned
[ESP-IDF v5.4.4 definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/ld/esp32p4/memory.ld.in).
Other silicon/cache configurations require separate bounds.

| Range | Retained baseline role | Planning treatment |
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
| Task and IRQ stacks | 144 |
| Fixed DMA and I/O buffers | 48 |
| Reusable internal heap including a 64 KiB minimum free reserve | 224 |
| Software guard reservation | 16 |
| Total | 544 |

The stack budget covers two 8 KiB bootstrap tasks, two 8 KiB storage/SQLite
tasks, one 16 KiB VM task, one 24 KiB TLS/HTTP task, four 8 KiB communication
workers (C6 RX/TX, TCP/IP and BLE), six ordinary 4 KiB tasks and two 8 KiB IRQ
stacks. The ordinary tasks include input/IME, display, editor, sensors, audio
and supervision/spare work; IME does not create a seventeenth task. This
revises the previous 128 KiB stack / 32 KiB DMA / 256 KiB heap proposal.
Exact port measurements may change these reservations. Admission must reserve
stacks before creating tasks and retain at least 64 KiB internal free capacity
at the combined standard-workload peak. Peak usage, largest free block and allocation failures
must accompany total-free statistics. These are proposed budgets; the current
56 KiB stack layout still needs admission/expansion work. The follow-up's
208 KiB high page pool establishes capacity without implementing the complete
application-facing heap or stack policy. The development profile proposes
reducing that qualified pool's 208 KiB to 176 KiB, leaving
48 KiB low heap and reserves another 16 KiB each for DMA and stacks.

The 224 KiB internal heap envelope contains 24 KiB kernel/scheduler control,
24 KiB storage/VFS control, 64 KiB network control, 24 KiB BLE control, 8 KiB
IME control, 16 KiB allocation/fragmentation allowance and a 64 KiB free
reserve. IME control is transferred from the earlier kernel allowance.
The 48 KiB DMA envelope initially assigns 16 KiB each to C6 RX/TX, SD staging,
and display/audio/descriptors/alignment. These are charged backing limits;
static state, dynamic state, stacks and DMA are counted once. If measurements
require more, revise admission or reduce another envelope rather than borrowing
the mandatory free reserve. The candidate addresses and parent/child budgets
are in the [development profile](tab5-development-profile.json).

The [broker implementation](../adr/0049-memory-broker-page-parents.md) consumes
the 16 KiB allocator allowance as metadata backing outside registered payload.
Consequently its internal registration is 208 KiB (48 KiB low + 160 KiB high),
with 144 KiB service ceilings and the same 64 KiB free floor. The gross heap
envelope stays 224 KiB. `tools/generate_memory_profile.py` generates the target
policy and checks it against the JSON; platform heap handoff is a later gate.

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
| SQLite including page cache and wal-index | 2 |
| VFS/RPC/I/O ceiling | 0.5 |
| Experimental store ceiling | 2 |
| Wi-Fi/TCP/IP/TLS/HTTP/AI working set | 3 |
| BLE buffers and profiles | 0.5 |
| IME dictionary cache, conversion, display and learning | 2 |
| Sensor/audio/log buffers | 0.5 |
| Unassigned headroom | 8.5 |
| Total | 32 |

These are peak admission envelopes, not eager startup reservations or a proof
that every feature already fits. The framebuffer alone is 1,843,200 B in
1280x720 RGB565. A second framebuffer consumes another such allocation.
The old fixed CPU split and allocator rounding can prevent admission even
when the global sum fits; solve those constraints before advertising the
unassigned space as a shared pool. Charge actual backing allocations, including
slab/guard overhead, rather than only requested payload sizes.

Start SQLite with a suggested 512 KiB page cache inside its 2 MiB service
envelope. The page cache is not a total memory cap: statement/schema/sort
state, allocation headers and wal-index also consume that envelope. Its current 1024-byte pages, 16-page database and
small C size-class quotas are fixture limits, not the persistent DB design.
A 4 MiB VM payload is the standard target; an 8 MiB ceiling depends on the
large-allocation work. Do not reserve a second VM by default.

### Communication and input admission

The initial simultaneous limits are one SQLite connection/database, one Wi-Fi STA, one active TLS connection
and handshake, two BLE connections, one VM, one framebuffer, one storage
writer, and one shared IME with one active composition. C6 radio/controller
RAM is separate from P4 RAM. The conservative profile retains TCP/IP, TLS
and the BLE host on P4, following the [ESP-Hosted split](https://github.com/espressif/esp-hosted-mcu/blob/main/docs/architecture.md).
The [BLE host](https://github.com/espressif/esp-hosted-mcu/blob/main/docs/features/bluetooth.md)
and actual C6 firmware capabilities need their own integration checks.
Socket/ESP-AT offload is an alternative; no RAM or task saving is booked
until its firmware, transport, security and reconnection lifecycle are qualified.

The 3 MiB Wi-Fi/network envelope contains 512 KiB TCP/IP queues/sockets/DNS,
1 MiB TLS/crypto/certificates/handshake, 512 KiB HTTP/AI streaming buffers
and 1 MiB peak/backing-rounding reserve. BLE has its own 512 KiB PSRAM ceiling.
Queues and responses stay bounded. Normal protocol code should execute from
mapped Flash; IRQ/cache-off paths and required state remain internal. This
requires explicit linker/audit and cache-lifetime work rather than assuming
the current all-resident runtime contract already permits it.

The IME 2 MiB charged-backing envelope contains 1 MiB dictionary index/read
cache, 128 KiB conversion/candidates/preedit, 512 KiB composition display/glyph
cache, 64 KiB user learning and 320 KiB I/O/allocator/peak reserve. Full immutable
dictionary and font payloads reside on Flash/SD, with an internal small-dictionary
fallback. Application contexts share the service and dictionary cache. Learned
entries are batched into a bounded persistent object/database instead of
creating a small file or issuing a durable write for every key.

MeOS currently copies its large dictionary into PSRAM and searches a contiguous
pointer; a bounded read-at/index interface is required for the paged design.
The [source layout inspection](evidence/ime-budget-review.json) found 53,648 B
for its main IME workspace, a possible 491,520 B screen snapshot, and 2,567,765 B
of immutable 24-dot font tables. Font tables are storage assets; glyph cache is
inside the IME envelope. Prefer damaged-region redraw over retaining a large
screen snapshot. Do not infer dictionary size from those numbers: the full
dictionary artifact was not present in that inspection. A hypothetical 5 MiB
dictionary alone costs an 8 MiB block in the current native buddy allocator.
The 2 MiB IME allowance therefore depends on bounded caches and backing-charge
accounting, not a direct full-dictionary port or a 2 MiB parent request that
silently rounds to 4 MiB. A qualified 4 MiB VM lease would increase the present
8.5 MiB headroom to 12.5 MiB; that saving is not yet booked.

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

Separate workload units: SQLite pages and map nodes start at 4 KiB; large
immutable file extents target 256 KiB and coalesce toward 1 MiB or more;
SD log segments target 4 MiB. Small logical updates must not rewrite a whole
large extent. For a 16 GiB volume, a hypothetical flat 16-byte map costs
4 MiB at 64 KiB granularity, 1 MiB at 256 KiB and 256 KiB at 1 MiB; even those
tables belong on media with bounded caches. A retail 16 GB card has fewer
bytes than this 16 GiB example.

The 64 KiB PSRAM append buffer can batch 32 KiB of requested I/O, but initial
internal SD DMA transfers are at most 16 KiB to fit the staging allowance.
Larger single commands require proved DMA-buffer lifetime/support or a revised
DMA split. The batching unit does not force a 4 KiB lookup to read 32 KiB.
These geometries are evaluation candidates only.
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
Eight 4 MiB clean segments is a candidate minimum reserve, not a general proof.
The normal clean-space target is 10% of logical volume capacity, independent
of this emergency reserve and not a claim about free space inside the SD FTL.
For example, 4 MiB unpublished + 4 MiB live copy + 64 KiB checkpoint + 8 MiB slack
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

## WAL candidate after durable VFS qualification

The initial persistent baseline remains `PERSIST`/FULL under ADR 0002. Reserve
WAL memory now so that a later WAL profile does not require an unbounded heap.
Candidate DB pages are 4 KiB, suggested page cache 512 KiB, checkpoint trigger
1,024 frames (4,218,912 logical WAL bytes), and a broker/VFS frame quota of
4,096 frames (16,875,552 B). The wal-index starts at 32 KiB and budgets 64 KiB
within SQLite's 2 MiB ceiling; the WAL payload stays on storage. The initial
WAL profile has one connection with EXCLUSIVE locking set before WAL access,
and `synchronous=FULL`. These follow the [WAL layout](https://sqlite.org/walformat.html)
and [single-owner contract](https://sqlite.org/wal.html#use_of_wal_without_shared_memory).

An 8 MiB `journal_size_limit` is a retained-file hint after reset, not the
active growth quota. Admission must account for a whole transaction, quota
failure and recovery; it must not silently split application transactions.
Close or explicitly manage long-lived reader cursors so they cannot pin
unbounded WAL. `PASSIVE` checkpoint avoids waiting for some locks but is not
a byte/time work limit. Measure its foreground p95/p99 and scheduler/transport
interference before enabling it on device.

Preserve the WAL's byte offsets: a 4 KiB frame has a 24-byte header, so do not
charge each frame as a separately padded 8 KiB allocation or journal the entire
WAL again in another payload log. Data, locating metadata and root publication
still need correct durable ordering. Optional future DB/WAL immutable-range
sharing must retain DB-referenced payload across WAL reset and may postpone
copying to GC rather than remove it.

The [12-case host comparison](evidence/sqlite-host-results.json) used SQLite
3.54.1 and Unix VFS, 8,192 rows, 512 updates and a fixed 512 KiB cache suggestion.
For adjacent updates in explicit 32-row transactions, WAL bytes were 201,912 /
262,944 / 393,824 for 4 / 8 / 16 KiB pages. Random updates produced 2,051,792 /
3,902,632 / 7,432,856 B. This supports 4 KiB for that update workload, not an
SD throughput or durability conclusion. The [probe source](../../tools/probes/sqlite-geometry.c)
and [input provenance](evidence/sqlite-host-provenance.json) permit replay.

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

The high-SRAM qualification app occupies 775,744 B of a 1 MiB factory
partition, leaving 272,832 B. A language runtime, communication libraries,
Japanese fonts/dictionary, writable VFS/FatFs and a new store
must have linked size budgets before integration. Do not adopt a new Flash
partition table from RAM arithmetic; app/OTA/recovery/settings sizes and
migration protection need a separate reviewed map.

## Delivery and acceptance

1. High SRAM cell/SMP/page-pool qualification passed on the exact retained
   loader/cache configuration. Integrate reusable internal pools with the
   general memory broker and add stack admission. Fix large PSRAM allocation
   rounding and quota accounting before integrating bigger application heaps.
   Implement the 144 KiB stack / 48 KiB DMA / 224 KiB heap profile only after
   broker integration; keep the existing qualified firmware as a separate receipt.
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
7. Gate the combined development workload on native measurements of Wi-Fi
   reconnect/TLS handshake, BLE traffic, IME dictionary cache misses and SQLite
   checkpoint/GC overlap. Require 64 KiB internal free reserve, sufficient largest
   free block, measured stack headroom, bounded queues/cache miss latency and
   allocator recovery after cancellation or disconnect. Add WAL only after its
   locking, sync, quota, reset/reuse and power-loss gates pass.

[The budget model](tab5-storage-budget.json) is reproducible with
`python3 tools/storage_budget.py --output docs/planning/tab5-storage-budget.json`.
It validates envelope sums and exposes its assumptions. It does not measure
execution speed, code size of future features or physical durability.

The [paged-checkpoint host experiment](../measurements/2026-10-27-store-checkpoint.md)
now exercises a sparse 16 GiB file with u64 media offsets. Its store descriptor is
8,272 B on RV32 at compile time, and metadata-only mount reads at most 1,056,768 B
for two roots and 128 leaves per root. These exclude call-stack/backend memory
and do not establish target latency. Every commit checkpoints; tail replay is
zero. The append-only index pool still exhausts without cleaning, and whole-object
CRC on every read needs range-based replacement before SQLite partial I/O.
This advances the host model gate without qualifying an experimental SD volume,
changing the 2 MiB store envelope or providing a persistent SQLite VFS.

The [range-checksum follow-up](../measurements/2026-10-27-store-range-checksum.md)
replaces that whole-object scan with checksums per 4 KiB payload page in the
experimental version 2 format. A cold one-byte read requires 12 KiB including
its leaf and checksum table, even for a 4,157,441 B object. The RV32 descriptor
remains 8,272 B, excluding stack/backend memory. Explicit full-object verification
is available; cold corruption outside a requested range is deferred until read
or scrubbed. Cleaner, reader pins, streaming/partial writes and target durability
remain separate gates; the append-only index still exhausts without GC.

The [index-recycling host follow-up](../measurements/2026-10-27-store-index-gc.md)
now reuses leaves unreachable from either valid disk root, the staged transaction
and two reader snapshots. A root-only checkpoint can retire the older disk root
with zero free leaf pages; reader pins can still impose NoSpace until released.
The default 4,096-page pool exceeds the 640-page maximum protected set, removing
its former lifetime limit of 4,096 mutations. The RV32 descriptor is 14,536 B,
excluding stack/backend memory. Payload remains append-only, so this qualifies
index recycling rather than a complete cleaner; payload reserve, reclamation,
streaming/partial writes and physical SD qualification remain open.

The [payload-recycling host follow-up](../measurements/2026-10-27-store-payload-gc.md)
adds a fixed 4 KiB occupancy window to find unreferenced contiguous payload and
sidecar ranges. Version 3 records an excluded tail reserve; it does not relocate
live data. The RV32 descriptor is 18,640 B, excluding stack/backend memory, and
two reader snapshots remain protected. A 64 KiB repeated-update probe passed
within a 60-page ordinary region plus four reserved pages at the end of a sparse
16 GiB file. This is a correctness experiment, not target foreground readiness:
the probe issued 214,335,488 B of backend reads during its payload churn, and a
full search can scan metadata for every bitmap window. Budgeted/resumable search
and metadata caching are required before native integration. Relocating-cleaner
reserve use, streaming/partial writes and physical durability remain open.

The [bounded-search/cache host follow-up](../measurements/2026-10-27-store-search-cache.md)
now exposes resumable steps with independent leaf-visit and bitmap-page budgets.
Prepared allocation results are invalidated by writer/reader state changes.
The 128-leaf current-view cache uses 512 KiB data plus 2 KiB tags; the RV32 store
state including it is 545,128 B, compared with 18,792 B uncached. In the identical
host churn scenario, backend read requests fell from 214,335,488 B to 962,560 B,
while all four saved generations were byte-identical. This supports the planned
512 KiB map-cache envelope for that stress workload, not a measured target speedup.
Blocking compatibility wrappers still exist; a native service must yield between
steps and place the cache in its PSRAM budget. Streaming/partial writes, full I/O
latency, target placement and physical durability remain separate gates.

The [fixed-buffer streaming follow-up](../measurements/2026-10-27-store-streaming.md)
adds declared-length streams, staged finish, cancellation and incremental fixed-
length range replacement. A 33 MiB + 17 B object passed separate-process checks
using a 4 KiB input buffer; private writer buffers add 8 KiB plus scalar state.
The RV32 state is 27,104 B uncached or 553,440 B with the 512 KiB metadata cache.
This addresses whole-object input RAM, not random-write amplification: replacing
20 B still wrote 34,652,160 B including sidecars and root/leaf metadata. A paged
extent map with immutable range sharing is a prerequisite for practical large-DB
partial writes. Native cancellation/ownership, placement, target durability and
SQLite integration remain open.

The [shared-page-map follow-up](../measurements/2026-10-27-store-extents.md)
adds version 4 COW maps with per-page CRCs, shared immutable subtrees and
data/node range summaries for resumable GC. The 33 MiB host object's two-page,
20-byte replacement wrote 36,864 B versus 34,652,160 B for the prior full copy.
The RV32 state is 31,512 B uncached or 557,848 B with the 512 KiB metadata cache.
Initial conversion still constructs the whole map; growth/truncate, batching,
native placement, target durability and SQLite integration remain open.

The [sparse-resize host follow-up](../measurements/2026-10-27-store-resize.md)
adds version 5 implicit zero pages/subtrees, COW tail clearing and shared-map
growth/truncation. A wholly unwritten logical 16 GiB object needs one map root;
this is not a dense-capacity or full-transfer qualification. A 33 MiB host file
shrink/regrow wrote 20 KiB per operation while preserving the pinned old tail.
The RV32 store state remains 31,512 B uncached or 557,848 B cached; a caller-owned
16 KiB resize workspace must also fit the 2 MiB store envelope. Four publication
campaigns passed 7,776 cuts per build mode. Batching, native ownership/cancellation,
PSRAM placement and stack peak, target durability and persistent SQLite VFS/WAL
remain open; the frozen physical candidate is unchanged.

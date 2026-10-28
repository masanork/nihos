# Fenced read-only FatFs disk bridge qualification

Run `python3 tools/check-fatfs-disk.py`. It creates private regular image files
under a fresh `build/fatfs-disk/run-*` directory. It never opens a serial port or
attaches an image as a device. The sparse exFAT fixture has a 6 GiB logical size;
hashing reads the full image before and after the probe.

The runtime source is `src/storage/fatfs_disk.c`, with the trusted owner API in
`include/nihos_fatfs_disk.h`. `src/platform/native/fatfs_disk.c` forwards its sector
callback to the existing native `nih_storage_read` export. The host probe replaces
that export with synchronous regular-file I/O or fault injection; it does not
execute the real DMA controller. The two adapter files are also compiled for
RV32, but are not linked into a firmware image or enabled on hardware.

The disk contract admits one owner, one drive, fixed 512-byte sectors and one
validated region within a device of at most 2^32 sectors. Each `disk_read` is at
most 4 KiB, splits into existing sector callbacks and publishes output only when
all callbacks succeed. Read failure, budget exhaustion and owner invalidation
remain sticky until detach and a fresh epoch. Initialization does not clear them.
There is no write, trim, hardware reset or automatic remount path.

Each callback must return only after its DMA fence is proved, including on error.
The workspace and callback context must remain owned/pinned until detach, and
reentrant reads, rearming, detach and bind are rejected while a callback runs.
This is an owner API, not an interrupt mailbox or an allocator pin implementation.
The native storage owner must first prepare its controller and clock and begin
the existing storage controller session. A quarantine in that implementation is
fatal and must not return into FatFs cleanup. This adapter cannot independently
prove a callback's fence or resurrect a quarantined native controller.

The tests exercise all eight sector failure and invalidation positions in a
4 KiB request, invalidation between requests, stale epochs, epoch exhaustion,
reentry, range/partition limits, the last sector of a 2 TiB device, budgets and
output preservation. A writable FatFs configuration is rejected at compile time;
the reader has no FatFs write APIs. Actual FatFs reads FAT12/16/32, partitioned
FAT32 and exFAT, including Unicode names, fragmented files and >4 GiB offsets.
Every source image has matching whole-image hashes afterward.

The host fixture files `ffconf.h`, `host_disk.[ch]` and `make_fixture.c` were copied
unchanged from nihos commit `542b3a3` (host VFS PR #3). The bootstrap starts from the
same commit and adds an optional isolated cache directory so this runner does not
rewrite another session's upstream source tree. It verifies the upstream archive,
both official patches and patched `ff.c`; see `provenance.toml`. Upstream FatFs
sources and license notices remain in ignored build directories and are not
copied into the repository. The writer is a separate executable, uses `O_EXCL`,
and is solely for generating private test inputs.

The disk-only command above tests valid volumes. Its disk epoch alone does not
reject a stale FatFs `FIL` object. It does not enable a native filesystem mount.

## Owner-side volume admission

`src/storage/fatfs_volume.c` and `include/nihos_fatfs_volume.h` discover a bounded
512-byte-sector view before disk binding. AUTO accepts a valid superfloppy or
exactly one supported MBR primary volume. The caller can select physical MBR
slot 1..4 explicitly. All populated intervals, including unselected types, are
checked for bounds and overlap before any partition read. GPT protective and
extended partitions are rejected; no EBR/GPT traversal occurs. FAT12/16/32 and
the pinned single-FAT exFAT geometry are admitted without trusting type labels
as proof of valid filesystem contents. The view ends at the VBR-declared length.
BPB hidden-sector/exFAT PartitionOffset values cannot redirect physical reads.

The probe uses caller-owned 512-byte scratch, at most five synchronous sector
callbacks and no global state. Returning errors leave output unchanged and clear
scratch. The owner must hold one unchanged controller/card session across probe,
bind and mount; the result does not authenticate media or detect a hot swap.
FatFs mount, bounded chain checks and per-operation budgets remain necessary.

The disk runner includes synthetic layout/error contracts and five compiled
source mutants (range, overlap, ambiguity, declared length and exFAT shift).
All five actual images now pass admission before the real FatFs reader runs.
The Backend runner adds `selected-vfs` cases through the probe, disk bridge,
guarded FatFs and actual Zig VFS. Existing malformed-volume tests still exercise
the Backend's own independent checks. The probe is compiled for RV32 but is not
yet linked or invoked by the native SD owner. See
[the admission contract](../../docs/planning/volume-admission.md).

## Guarded Backend and actual Zig VFS integration

`python3 tools/check-fatfs-backend.py` runs the disk tests first, then compiles
`safety.c` instead of raw upstream `ff.c`, plus `src/storage/fatfs_backend.c` and
the real Zig VFS/adapter. The safety shim is an unchanged copy from `542b3a3`.
`src/fs/vfs.zig` and its tests start from that same commit; this branch additionally
faults a mount after lookup/open I/O or contract failure. The earlier fake-backend
open-retry test now requires quiescent detach and a new mount after such a fault.

The C Backend has one opaque, caller-owned workspace and 16 open-file slots plus
one staged lookup. Lookup keeps the guarded `FIL` at a stable address. Open only
consumes that staged slot by identity and performs no new path resolution or I/O.
An unconsumed lookup uses one slot until the next lookup/destroy. Every operation
checks the disk epoch and sticky session/disk fault before touching cached file
state. The backend retains its disk binding until teardown; raw detach cannot
replace the media under cached objects. Read output is staged for a whole public
4 KiB quantum, even if multiple FatFs disk reads precede an error. This is not a
durability or write-transaction guarantee.

The Backend checks the selected VBR signature, sector size and declared volume
length against its region before mounting. Selection/discovery of that region
remains the trusted caller's responsibility; there is no GPT or MBR scanner here.
The root capability represents the volume root only. Public path, rights,
principal, file-table and handle-generation checks run in the actual Zig VFS.

The companion tests cover cyclic/truncated file chains, cyclic parent/root
directories and directory ancestor aliases on all supported formats. Identity
tests include separate empty files, long/short/case aliases, containing directories
and distinct Unicode normalization forms. VFS tests exercise a real read failure,
quiescent detach, C teardown and a fresh disk epoch, reject old roots/files/backend
epochs, then reject cached reads after removal without issuing another sector I/O.
The C/FF/shim code uses ASan/UBSan; the Zig library uses ReleaseSafe. Per-test
subprocess deadlines and disk/chain budgets bound the host experiment.

RV32 compilation includes the C Backend, shim/upstream FatFs, Unicode module and
an actual VFS/adapter instantiation. Workspace sizes are extracted from target
ELF layout symbols. They do not include LFN/call stacks, all globals, final code
placement or RPC buffers. The current native 8 KiB littlefs workspace cannot be
reused unchanged for this larger backend. Firmware linkage and admission remain
disabled pending those measurements and a runtime integration.

All code here still requires a single serialized owner, immutable mounted media
and a caller that pins the destination/workspaces through synchronous completion.
The backend must not return from an unproved DMA fence. Native kernel/wakeup and
controller-abort integration, hardware card-detect notification, simultaneous filesystem routing,
subtree capabilities, persistent SQLite, writable media, power-loss recovery and
clean physical power-on are separate gates. No serial/device operations occur in
either runner.

## Copy-only RPC v2 and broker-owned parent

The companion runner now also connects `src/fs/vfs_rpc.zig` to the real guarded
Backend and unchanged development memory broker. RPC v2 has 64-bit offsets and
generation tokens, 511-byte paths and 4 KiB replies; legacy 32-bit/512-byte storage
RPC remains separate. A channel is bound to a kernel-supplied identity, never a
principal in message bytes. One producer and one owner exchange copied messages
through two-slot request/reply rings. Reply credit is reserved before dispatch.
Pointer-form ring copies keep full-size messages out of return-value temporaries.

The workspace layout aligns disk, C Backend, RPC owner (including VFS) and queues
to 128 bytes inside one 64 KiB external `.vfs` broker parent. Its pin spans FS
initialization, dispatch, endpoint shutdown and private-FS destruction. The parent
is scrubbed and unpinned only after both shutdown calls succeed; a closing owner's
reaper waits while teardown is busy. Notifications and parent-coordinator metadata
live outside this bulk parent. Client request/reply frames belong to a separate
client lease and are copied before use; they may be reclaimed once that client is
stopped. The test closes a one-actor client account, not an app with live siblings.

The resident notification contract uses 32-bit atomics: stopped-client epochs
and exact active-read tickets reject stale events. Cancellation waits for the
synchronous backend to return quiescent, then scrubs the reply and returns -125.
It does not abort DMA or promise that the mount remains healthy. A stopped client
causes queued work and unread replies to be discarded before owner-side FD cleanup.
Rebind requires a drained endpoint and a new epoch; counters never wrap into old
identities. Actual scheduler stop/wakeup and IRQ residency/linkage remain unconnected.

In all five media fixtures, a sector callback injects cancel/exit while the RPC
dispatch is active. The real broker rejects early service-parent free/retire,
reclaims the stopped client's separate pages, retains the service pin, and recovers
all pages after endpoint/FS teardown. A new client rejects old handles and reads
again. exFAT also reads a marker above 4 GiB through RPC. These are host callback
events, not native task-kill or hardware DMA timing evidence. RV32 compilation
instantiates the actual RPC, notification and parent reserve/retire paths.

The candidate layout uses 38,656 bytes within the charged 65,536-byte parent.
Client frames are 4,696 bytes (8,192 bytes charged separately); notification state
is 28 bytes and parent-coordinator metadata is 72 bytes on RV32. These counts do
not admit the final native code/rodata, globals, task stacks or complete workload.
The existing native littlefs fixture stays on its original protocol and layout.

## Opt-in native fixture link

`NIHOS_NATIVE_FATFS_RPC=1` now links the guarded reader and actual VFS/RPC into
an optional native FSD/client phase after the existing broker qualification.
This phase uses an immutable sparse/RLE FAT12 Flash fixture, not the physical SD
adapter described above. The C decoder's complete logical image is checked on
host by `tools/check-fatfs-native-input.py`. Native C objects disable inlining to
avoid overlapping LFN stack buffers; the copied safety shim remains unchanged.
The final ELF audit checks resident notifications/hooks, immutable fixture hash,
reserved control/parent layout and individual static frame ceilings. The current
worker stack is 4 KiB. Whole-call-stack and physical scheduler/SD qualification
remain separate gates. See
[the native link record](../../docs/measurements/2026-10-28-fatfs-native-link.md).
The subsequent [three-run Tab5 record](../../docs/measurements/2026-10-28-fatfs-native-physical.md)
confirms this embedded fixture's actual scheduler stop/rebind/cleanup paths.
It does not qualify the physical SD FatFs adapter or the new volume probe.

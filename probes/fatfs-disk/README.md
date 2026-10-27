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

The chain/ancestry/identity safety shim in PR #3 is not part of this disk layer.
These are valid-volume tests; no native mount of untrusted FAT metadata is
enabled. Before firmware linkage, the backend still needs that shim, partition
validation, outer VFS mount invalidation (FatFs can serve cached bytes without a
disk callback), authenticated file/root handles and RPC integration. A monotonic
disk epoch does not by itself reject a stale FatFs `FIL` object. The owner must
retire every old filesystem object before rebinding. Whole-`f_read` atomicity,
SQLite persistence, power-loss recovery and a clean physical power-on are not
established here. RV32 workspace size excludes `FATFS`, open-file state, LFN
stacks, the upstream library and final firmware placement.

# Read-only FatFs host conformance package

Run `python3 tools/run-fatfs-host.py` from the repository root. It needs Python 3,
a C11 compiler with ASan/UBSan, `patch`, `nm`, and network access for the first
checksum-verified bootstrap. Generated images, binaries and JSON evidence stay
under a new `build/fatfs-host/run-*` directory. The exFAT image is sparse: 6 GiB
logical size, with only its metadata and test markers backed by host blocks.
Hashing reads the complete logical image before and after the tests.

For Linux CI, install `dosfstools` and `exfatprogs`, then add
`--require-oracles`. Their read-only filesystem checkers independently check
the generated FAT12/16/32 and exFAT volumes. On macOS, `fsck_msdos -n` checks
the three FAT superfloppy images; macOS `fsck_exfat` cannot check a regular
image with this setup and is not used. No image is attached as a block device.

## Boundaries

- FatFs R0.16 and official patches 1 and 2 are fetched by
  `tools/bootstrap-fatfs.py`. Archive, patches and the resulting `ff.c` are
  SHA-256 pinned. No upstream source is copied into the repository.
- `make_fixture.c` uses a separate read-write build solely to create private
  fixtures. `O_EXCL` prevents overwriting existing paths. This is not a writable
  filesystem adapter or a durability experiment.
- `read_image.c` and `host_disk.c` are a host policy probe, not an OS driver.
  The reader is compiled with `FF_FS_READONLY=1`, opens regular images
  `O_RDONLY`, and omits filesystem write APIs. Its `disk_write` stub rejects
  writes. Explicit write probes and whole-image hashes check those boundaries.
- The policy probe accepts a 512-byte-sector superfloppy or a single basic MBR
  partition, requires boot signatures, validates declared volume/partition
  bounds and rebases the disk view to the selected volume. GPT/multiple-partition
  support is deliberately outside this package.
- Read requests are at most 4 KiB. The disk backend has a read-call budget,
  directory enumeration has a batch bound, and subprocesses have wall-clock
  deadlines. These contain host tests; they do not establish native cancellation
  or a strict worst-case CPU/I/O time.
- The raw write-mode and missing-signature probes are negative controls:
  upstream FatFs alone does not enforce these outer VFS policies. A FAT chain
  self-loop is also observed to repeat data rather than fail. That observation
  is retained as a remaining corrupted-volume qualification gate.

This package does not connect FatFs to `src/fs/vfs.zig`, native storage RPC,
SQLite, DMA, an SD card or power-loss recovery. In particular, a production
adapter still needs stable file identity for empty files and aliases, backend
lifetime/admission accounting, corrupt-chain policy and native measurements.
The host package and the separate common-log crash model can progress
independently; neither changes the other's on-media format or owner model.

## License and provenance

FatFs is copyright (C) 2025 ChaN. Its source license permits redistribution
and modification while retaining the copyright notice, condition and disclaimer.
The bootstrap retains those headers, applies only the two pinned official
patches to `ff.c`, and normalizes that file's line endings for patch application.
The configured Unicode module uses code page 437 for short names and UTF-8
for the public name API, with 255 UTF-16 code units and a 765-byte UTF-8 name
buffer. LFN workspace is on the host stack and must be budgeted again for native.
See `provenance.toml` for exact inputs and source identity.

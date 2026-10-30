# ADR 0043: Fixed-memory read-only file backend

Follow-up: [ADR 0044](0044-native-storage-owner-and-copied-rpc.md) adds opt-in
native task/RPC qualification; the general application service remains open.

- Status: accepted for the trusted backend; service/task/IPC integration remains open
- Date: 2026-10-26

## Context

The native SD qualification could read an existing littlefs volume, but its
filesystem state was global and its operations were embedded in the fixture.
The combined image had 49,856 bytes of internal heap, only 704 bytes above
the linker minimum. A runtime storage owner needs a reusable, bounded backend
and explicit handle cleanup before connecting application requests.

## Decision

`include/nihos_storage.h` defines a synchronous trusted C backend implemented
in `src/services/storage_littlefs.c`. Upstream littlefs remains unmodified,
compiled with `LFS_READONLY` and `LFS_NO_MALLOC`. There is no write/format API.

The caller supplies an aligned, fixed workspace and a sector-read callback.
All mutable littlefs state, cache/configuration lifetimes, path storage, and
the one active file live in that workspace. The native boot client uses
8 KiB at `0x48001000`, inside the already reserved first PSRAM test window.
The range excludes mapping samples, peer handoff words, and the general heap.
Only CPU copies reach PSRAM: SD DMA retains its fixed internal SRAM staging
buffer and descriptor. Destruction closes/unmounts and clears the supplied
workspace; its pointers and handles then expire.

Supported volumes occupy the full device with 512- or 4096-byte FS blocks.
Mount tries those two geometries and requires upstream metadata validation.
Public operations are stat, open, read-at-offset, close, release-owner,
unmount, and destroy. Paths are canonical absolute byte strings of at most
255 bytes, with no embedded NUL, dot/dot-dot components, repeated slash,
trailing slash except root, or control characters. Reads accept at most
512 bytes and offsets up to EOF. The caller supplies valid readable/writable
buffers; this interface does not validate arbitrary address spaces.

One file may be open at a time. A nonzero owner ID and a non-repeating token
identify it. Close or owner release invalidates the token; exhausting the
32-bit token sequence rejects further opens until a new workspace lifetime.
The runtime must quiesce old clients before reinitializing a workspace.
An operation is limited to 8,192 sector reads. IO/metadata errors poison the
mounted session while leaving cleanup available. Missing files and invalid
arguments do not poison it. A closed session may be explicitly remounted.

Owner IDs come from the trusted caller. They are not automatically tied to
the native task identity or resource table. The backend is not thread safe;
the caller must serialize entry and device ownership. A release-owner call
is cleanup support, not yet a scheduler task-exit hook or cancellation of an
in-flight operation. This is not an untrusted syscall or RPC ABI.

## Native staging

The boot fixture is an API client. It mounts twice, compares directory/file
results, checks owner mismatch, oversized reads, cancellation and stale tokens,
and verifies workspace clearing. A separate IDF application shares the API and
upstream FS while using independent SDK block IO. This compares block adapters,
not independent filesystem parsers.

PSRAM discovery/reporting, SD qualification/reporting, and SQLite/reporting use
separate non-inlined call scopes. Their temporary stack reservations return
before later stages. Stack paint observations and ELF heap measurements must
be recorded for the final device image; static C frames alone do not bound
the whole call graph.

## Remaining service boundary

ADR 0002 still governs application requests: one storage task owns controller,
filesystem, and handles; request/completion messages carry bounded copies or
leases, not raw platform pointers. That task/IPC transport, task-exit wiring,
an independent runtime timebase, hot removal/recovery policy, and SDMMC
arbitration with C6 Wi-Fi remain unimplemented. The boot-only controller still
resets the shared host and borrows the stopped scheduler timer before CPU1
release. Calling it from a running application is not supported.

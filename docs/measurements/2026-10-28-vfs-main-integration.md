# Read-only VFS and native lifetime integration

2026-10-28. This candidate combines main `bcee220`, the native storage branch
`3fe8d32`, and the guarded host VFS foundation from draft PR #3 (`542b3a3`).
The original implementation/evidence commits remain in the merge ancestry.
[The receipt](2026-10-28-vfs-main-integration.json) records the tested source,
exact artifacts and their hashes. No hardware was accessed for this integration.

The public device build retains the normal display, live console, networking
and connected-device profile. All eleven storage qualification flags are false
in that configuration. VFS/FatFs, copied RPC, page broker, SD cancellation and
high-SRAM qualification remain explicitly selected, headless profiles. Builds
that combine these storage owners with display, networking or USB are rejected
before producing outputs. Existing more specific device-ownership checks remain.

The merge preserves main's timer/interrupt setup, boot stages, normal-ready
path, device/network module graph and existing task/phase numeric tags.
Image/log checkers retain both sets of qualification checks. The filesystem
card fields are named separately from USB/My Number Card fields. The standalone
FatFs runner reconstructs verified upstream sources inside its own run directory
so concurrent host/native builds cannot mutate its source cache.

The SD RPC profile initially exceeded the cold-code resident limit after
integration. Only its ordinary-owner SQL/report orchestration functions were
moved to the existing approved Flash storage section, with exact function
allowlisting and a source fingerprint. Normal boot does not select that
placement. The unchanged 106,496-byte resident limit passes at 106,176 bytes;
the 8 KiB recovery floor, heap/stack gates and resident IRQ hooks remain intact.

Local verification passed: Zig Debug and ReleaseSafe (489 tests in the latter),
359 Python tests, fmt/ZLint/ShellCheck, broker checks, six RV32 architecture
links, C/Zig/Rust ABI, C runtime, SQLite memory/OOM/owner probes, littlefs,
and both RV32 SQLite ABIs. Guarded VFS/RPC passed 109 host scenarios; standalone
FatFs passed 200 sanitizer cases across FAT12/16/32, MBR FAT32 and exFAT.
Independent fsck tools are required separately by the Linux CI workflow.
Eight normal-boot emulator cases (including expected failures) and the
32 MiB integer SMP qualification passed. The default connected OS, SD VFS/RPC
image and embedded FatFs fixture passed their respective ELF/image/frame audits.

Earlier [embedded native](2026-10-28-fatfs-native-physical.md) and
[physical exFAT RPC](2026-10-28-fatfs-card-rpc-physical.md) observations remain
scoped to their original exact binaries. They do not qualify this merge image.
The current native workload still cancels/stops clients after the sector fence;
its controller-abort qualification remains false. The host CMD17 cancellation
model is not silicon DMA evidence.

Card-detect IRQ registration and a native post-CMD17 abort qualification fixture
are still unimplemented. In-flight hardware abort, mounted card removal, whole
call-stack bounds, clean POR and native FAT12/16/32 execution remain open.
Writes, persistent SQLite/WAL and power-loss recovery are separate milestones.
The completed read-only opt-in scope can therefore be reviewed independently
of those remaining implementations and physical gates.

The original dirty checkout remains at `196b354`; its status and all recorded
file hashes match the pre-integration snapshot. It has not been switched,
reset, stashed or updated. This receipt records local validation before PR CI;
GitHub results must be checked against the actual PR head before any merge.

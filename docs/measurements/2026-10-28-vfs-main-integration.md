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

## Concurrent card UI update

Main advanced to `542e6ac` (PR #17) during CI. The new card boot/simulator and
base DMA SRAM pool were merged as `9347514`. That pool is omitted from the
headless high-SRAM/broker profile: its linker symbols and allocator object
must not compete with the page broker over the same memory. Normal builds
retain the pool; their image audit reports two free regions. Both SD and
embedded VFS audits report no base pool and retain the high-SRAM broker layout.
The image checker retains the new card function/asset checks and SD resident
hook checks together.

Revalidation passed 492 Zig tests in each optimization mode, 380 Python tests,
109 VFS/RPC host scenarios, eleven card UI host scenarios, static/six-link
checks, all eight normal-boot emulator cases and the 32 MiB integer SMP smoke.
Default connected, SD VFS/RPC and embedded fixture audits passed again. The
receipt's `concurrent_main_update` records these new exact artifacts separately.

The first Linux host CI exposed a non-PIC Zig archive linked by the C driver's
default PIE configuration. The host library modules now explicitly use PIC;
native flags and sanitizer checks are unchanged. The independent FAT/exFAT
CI passed 201 cases with its source hashes and artifact SHA-256 verified.
Final CI must still be evaluated for the updated PR head.

The next Linux link exposed the archive's missing `__zig_probe_stack` helper.
The host archive now explicitly includes Zig compiler-rt, retaining stack
checks. A cross-compiled Linux x86-64 archive contains the weak helper definition,
and all 109 local host scenarios passed again. This changes only the host probe
link configuration; native flags and images are unaffected.

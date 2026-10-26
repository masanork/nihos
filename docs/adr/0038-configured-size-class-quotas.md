# 0038: Configured per-class quotas

Status: accepted for host and emulator qualification, 2026-10-26.

The uniform-quota experiment in ADR 0037 needs at least a 512 KiB parent for
a host SQLite sequence with a 27,456-byte usable-memory peak. Add immutable
`size_pool.Config` with ten u16 quotas, copied into each task's SRAM ledger.
The existing uniform API remains available. Disabled classes have quota zero,
occupy no header/payload bytes, and fail rather than borrowing larger classes.
An all-zero configuration is invalid. Active classes retain slab ticket,
capacity, ownership and corruption checks; lookup skips absent spans safely.
Pending configured parents and moving realloc retain opaque parent cleanup.

Typed callers use `reserveConfiguredObjects` / `openConfiguredObjects`.
C callers use scalar `nih_task_allocator_open_profile(1)`; unknown profiles
are rejected. Profile 1 is an experimental host-SQLite trace fixture with
quotas `24,12,16,12,40,4,8,12,8,1`, not a general SQL service budget. It requests
47,184 bytes and consumes a 64 KiB buddy block. No caller-supplied quota pointer
or unqualified by-value C aggregate ABI is added.

This profile passes the same host query and 308-point OOM/retry sequence as
the equal-quota path. The latter remains in CI as a compatibility check.
Both native busy workers also open/close profile 1 through the actual C ABI
before running the preceding allocation probe. Configured initialization
remains preemptible and metadata work remains bounded by ten classes.

Host tests cover sparse layouts, full/disabled classes, move failure preserving
source contents, copying caller configuration, pending cleanup and full heap
recovery. The 4 MiB integer native smoke and all six architecture ELF variants
pass; a later aggregate qualification will rerun the complete image matrix.
No hardware has been accessed. Native SQLite sizes, sustained workloads,
lookaside/page-cache tuning and larger requests remain separate work.

[Source-bound evidence](../measurements/2026-10-26-configured-class-quotas.json).

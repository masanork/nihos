# Cooperative mutation during ML-DSA snapshot copying

This headless emulator experiment extends [the after-copy mutation fixture](2026-10-29-pqc-snapshot-caller-mutation.md). It tests one controlled interleaving on CPU0: the worker copies half of a 9,612 B caller buffer, yields, and resumes the copy after the synthetic caller has either changed a message byte or left the buffer alone. A cooperative writer increments an atomic 32-bit version to odd before the write and to even afterward. The worker samples the version before and after copying and rejects the snapshot before signature verification if the version changed or was odd.

This is a bounded demonstration, not a general safe snapshot protocol. It assumes every writer participates, a single writer, a stable live source allocation and the controlled single-CPU schedule. It does not establish cross-hart memory ordering or race freedom under Zig/C memory models, protection against uncooperative callers, version wrap/ABA, retry or starvation behavior, or input-pointer authorization. Real service admission needs those contracts and verification before relying on a version counter. The `paused` log field denotes the middle-of-copy rendezvous, not completed copying.

| Case | Observed decision | Signature verification |
| --- | --- | --- |
| One cooperative write during copy | Version 0 to 2; snapshot rejected | Not called; no validity result |
| No write during the same rendezvous | Version stays 0 | Copied valid signature accepted; changed-copy test rejected |
| PSRAM absent | No snapshot or rendezvous | Not called; unavailable |

In the first two cases the caller source, worker snapshot and arena each incur a 16 KiB buddy charge: **48 KiB simultaneously**. After cleanup the owner heap returned from 1,752,384 B with all three allocations held to 1,801,536 B before/after the experiment. The worker stack is a fixed 8,192 B SRAM reservation. The changed-input early-exit case observed 688 B stack use; the successful signature case observed 2,896 B. These values are schedule- and fixture-specific, not maximums or normal-device headroom. Both workers exited, had their ledgers cleaned, and were reaped. CPU-visible zeroing is not a physical PSRAM erasure guarantee.

## Negative control and evidence

A separate audited mutant removes only the before/after version comparison. With the same midpoint mutation, it proceeds into signature verification instead of rejecting at the copy boundary; for this vector verification fails and the fixture stops. The [checker](../../probes/pqc/check_worker_copy_race_log.py) rejects that run. This does not show that all torn snapshots would be rejected by signature verification. The exact [mutant patch](evidence/2026-10-29-pqc-copy-race/mutant/remove-version-check.patch), raw and normalized logs, image audits, options, reports and source hashes are retained in [evidence](evidence/2026-10-29-pqc-copy-race/).

The changed-input image's native audit reports 103,808 B primary static SRAM and a 60,032 B primary heap span; the unchanged control reports 103,680 B and 60,160 B. Both pass the 48 KiB linker floor and use the same 8 KiB stack reservation. Changed-input ELF SHA-256 `77ac59903d37fb6603e07fa5be41e81a2163fe38f38d01c03ddbeaba7e37300c`, image SHA-256 `22c12648eedd0742bf0b852945c0be05338badeba5eb296c24ceec576f328b21`; control ELF SHA-256 `87d820ddb3e84ec00f1264b32f6ea86af0ccde480d38f586261ba9840d2d1b77`, image SHA-256 `f874781d0cd106a4e25b14e04867facf201000ebdeae760a23957a235ae45375`. Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the mldsa-native revision in the witness were used. Exact binaries remain under `build/pqc-copy-race-change`, `build/pqc-copy-race-control`, and the mutant worktree recorded in `build/pqc-copy-race-mutant-dir.txt`.

No physical hardware, normal UI, cancellation, multiple writers, arbitrary mutation points, allocator faults or physical erase behavior was tested.

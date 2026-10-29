# Copied ML-DSA input after the caller changes its buffer

This headless emulator experiment extends [the snapshot memory fixture](2026-10-29-pqc-input-snapshot.md). CPU0 bootstrap acts as a synthetic caller and owns a 9,612 B PSRAM source buffer containing a fixed public ML-DSA-65 test vector. A separate worker owns another 9,612 B snapshot and a 16,304 B arena. The worker copies the source into its snapshot, signals copy completion, and yields. Only then does bootstrap flip the first byte of the source message and acknowledge; the worker resumes and verifies from its snapshot.

On 4 MiB emulated PSRAM, the copied original signature was accepted and a further change to the copied message was rejected. The source mutation and acknowledgment were observed, the worker exited and was reaped, and each owner released its allocation. The owner heap's free count returned to its pre-allocation value. This demonstrates the specified **after-copy** sequence on this CPU0 schedule: the verifier continued using the copied bytes after the source changed. It does not establish a consistent snapshot if the source changes during copying, nor validate arbitrary caller pointers, trust anchors, permissions or a production service interface.

| Simultaneously held PSRAM | Payload | Buddy charge |
| --- | ---: | ---: |
| Synthetic caller source | 9,612 B | 16,384 B |
| Worker snapshot | 9,612 B | 16,384 B |
| Worker verification arena | 16,304 B | 16,384 B |
| **Total** | **35,528 B** | **49,152 B** |

The worker's primary SRAM stack remains an 8,192 B static reservation; the observed watermark was 2,896 B. The owner's free count was 1,801,536 B before source allocation, 1,752,384 B with all three allocations held, and 1,801,536 B after release. The caller source is part of this test's peak, not a claim that every caller must reserve a maximum-sized source. Values are fixture observations, not a worst-case bound or normal-device free memory.

When PSRAM is absent, no source or snapshot is allocated, verification is unavailable, and the worker still exits and is reaped. The test uses one short fixed vector, not a 4,096 B message; it does not cover an allocation failure after the source has been created, concurrent jobs, cancellation, actual UI, cache-off, physical PSRAM erasure or physical Tab5.

## Negative control

A separate audited mutant keeps the copy and handshake but passes the **changed source** to the verification routine. Its trace records `copied=1 mutated=1` and `valid=0`, then stops at the fixture's source-handshake failure. The [checker](../../probes/pqc/check_worker_mutation_log.py) rejects that run. This deliberately modified binary demonstrates that the test distinguishes copied input from the changed source for this vector; it is not a test of arbitrary races. The exact [mutant patch](evidence/2026-10-29-pqc-mutation/mutant/use-source.patch), rejected log and audit are retained.

The candidate's native image audit passed: primary static SRAM 103,424 B and primary heap span 60,416 B, above its 48 KiB floor. Its ELF SHA-256 is `ced09441975240d5bcfea60ff6009280755a01932b7c2e83ddc0c8cfd5ac18db`; image SHA-256 `7b1a27d907cd77c5f4e813aa8c0f8e658aa26c049fce121e322aefb6bfe3aa03`. Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the source revision in the witness were used. [Evidence](evidence/2026-10-29-pqc-mutation/) contains both logs, reports, options, audits and hashes; exact candidate binaries remain under `build/pqc-mutation-qualified`, and the mutant worktree path is stored in `build/pqc-mutation-mutant-dir.txt`.

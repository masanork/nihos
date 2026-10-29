# ML-DSA worker cleanup failure experiment

This opt-in headless emulator fixture exercises the real native task resource ledger and buddy allocator after an ML-DSA worker exits. It does not implement a production quarantine or recovery service. The preceding normal worker and cancellation results are described in [worker reuse](2026-10-29-pqc-worker-reuse.md) and [cancellation](2026-10-29-pqc-worker-cancel.md).

The worker performs the public verification fixture, zeroes its 16,304 B arena, and **deliberately retains** the allocation in its task ledger when it exits. CPU0 does not run normal cleanup. Instead, the experiment invokes `drainOne` with caller `1` for CPU0's allocation. The real buddy allocator returns `WrongOwner`; the real ledger catches that error and moves the task slot to `faulted` without dropping the allocation entry. This is a deterministic caller-mismatch injection, not an observed spontaneous hardware fault or memory corruption.

After injection, the fixture checks all of the following on CPU0:

- The task still owns one allocation; its ledger is not cleaned, does not report it as pending for ordinary drain, and refuses to open the same slot at the next generation.
- The buddy heap's free count is unchanged across the failed drain. The task's reap is refused, and starting a replacement worker is refused while its registered stack is still held.
- The worker had accepted the valid signature, rejected the modified message, and completed the partial-OOM test before exiting.

The arena was CPU-zeroed before the injected failure, but remains allocated. The experiment does not prove physical PSRAM erasure or that the allocator can recover. The normal `cleanupOne` path handles a drain error by calling the native task-failure stop path; this test intercepts the error in a dedicated probe to inspect the ledger and does **not** demonstrate that normal execution continues after the error. It stops after recording the results.

## Memory and exact candidate

The allocated PSRAM payload was 16,304 B with 16,384 B buddy charge and 10,208 B observed arena peak; 16,384 B remains unavailable after the injected failure. The owner's reported free bytes were 1,785,152 immediately before and after the error. The worker's separate 8,192 B BSS stack remains reserved; its observed watermark was 2,768 B. These numbers are for the fixture and observed schedule, not normal-device free memory or worst-case bounds.

The native image audit passed: primary static SRAM **101,568 B**, heap span **62,272 B**, above the 48 KiB linker floor. ELF SHA-256 `8a928ba7af04f4c5ad872e9fe21b6e66d88b8ec1074dfdd8dcaacbec505f7e34`; image SHA-256 `a4ba9d285cd2bf6fc4821ce1103239caf621ed83e68ad31b4b1e386db16daea6`. The candidate used Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the pinned mldsa-native revision in the source witness.

The [checker](../../probes/pqc/check_worker_quarantine_log.py) binds the result to the audited ELF/image and the stack symbol in SRAM BSS, verifies the complete ordered record, and requires the retained charge and all rejection observations. Six negative controls altering the failure, retained ownership, reopen/reap/restart rejection or heap count were rejected. [Evidence](evidence/2026-10-29-pqc-quarantine/) includes normalized and raw logs, options, image audit, report and source hashes; binaries remain under `build/pqc-quarantine-qualified` in the study worktree.

No no-PSRAM case is claimed: this injection requires an allocation. No physical hardware, real UI, failed zeroing, arbitrary allocator corruption, asynchronous cleanup race, restart recovery, reset or power-loss behavior was tested. The result does not establish that a live service can safely report and recover from every cleanup error.

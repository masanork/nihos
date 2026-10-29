# ML-DSA copied-input worker and simultaneous memory charge

This opt-in headless emulator fixture extends the [independent ML-DSA worker](2026-10-29-pqc-independent-worker.md). It allocates a task-owned PSRAM input buffer and a separate task-owned verification arena concurrently, copies the fixed public test-vector fields into the former, and verifies using pointers into that copy. It is not a service admission API or a demonstration that arbitrary caller memory can safely be snapshotted while another task modifies it.

The fixed snapshot layout reserves 1,952 B for an ML-DSA-65 public key, 3,309 B for its signature, up to 255 B for the context, and up to 4,096 B for the message: **9,612 B payload**. The fixture copies the actual, shorter test-vector message and context; it does not verify a 4,096 B message. It accepts the copied valid vector, changes a byte in the copied message and observes rejection, restores it, and exercises a partial arena OOM. The worker then CPU-zeroes and releases both allocations, exits, and is reaped. The source of this copy is a fixed immutable test vector; no concurrent caller mutation, pointer validation or client ownership is tested.

| Resource | Payload / observation | Buddy charge |
| --- | ---: | ---: |
| Input snapshot reservation | 9,612 B | 16,384 B |
| Verification arena | 16,304 B; observed peak 10,208 B | 16,384 B |
| Simultaneously held | 25,916 B payload | **32,768 B** |
| Worker SRAM stack | 8,192 B static reservation; observed use 2,896 B | Not from PSRAM |

On the 4 MiB PSRAM run, the worker owner's heap reported 1,801,536 B free before the allocations, 1,785,152 B after the snapshot, 1,768,768 B with both held, and 1,801,536 B after both were released. These values belong to this emulated fixture and its owner partition, not a normal-device or all-application budget. The 8 KiB stack remains statically reserved after reap. The observed stack watermark and arena peak do not bound all inputs or schedules.

With PSRAM absent, snapshot allocation was unavailable; no verification ran, and the worker exited and was reaped. Allocation failure after the first allocation, resource fragmentation, concurrent jobs, caller mutation, cancellation, full-size requests and physical erasure/cache writeback were not tested in this fixture. In particular, CPU-visible zeroing is not a physical PSRAM erasure guarantee.

The exact candidate passed native image audit. Primary static SRAM was 101,952 B, and primary heap span was 61,888 B, above the 48 KiB linker floor. ELF SHA-256 `a96ba6f2d4889d602fe011025a29235251c6207f724ea4f049551915ca6a7bc5`; image SHA-256 `74eecd3dfd9b38e4421ff18a02b205d06c272b05693a6faf10ecf77252c65965`. The image used Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the mldsa-native revision in the source witness. The normal-device XIP fixture still passes its build-time audit after this change; it does not run this worker or establish cache-off safety.

The [checker](../../probes/pqc/check_worker_snapshot_log.py) binds the log to the audited image and stack symbol, checks signature outcomes and task retirement, and verifies individual and simultaneous charges and full free-count restoration. Six mutated logs were rejected. [Evidence](evidence/2026-10-29-pqc-snapshot/) contains logs, reports, options, audit and source hashes; binaries remain in `build/pqc-snapshot-qualified` in the study worktree.

Real service admission still needs authenticated requester identity, length and pointer validation, a consistent snapshot protocol under mutation, error handling for each allocation and cleanup stage, bounded result publication, cancellation ownership, and real UI and physical-device testing. Mathematical validity with a caller-supplied key does not establish signer trust or authorize updates.

# Snapshot allocation followed by a full task ledger

This headless emulator fixture extends [the copied-input worker](2026-10-29-pqc-input-snapshot.md). It runs three sequential task generations. The middle job allocates the 9,612 B snapshot, then deliberately consumes the task's second and final ledger entry with an extra 64 B allocation. The verifier's subsequent 16,304 B arena request reaches the actual task ledger and returns `error.Full` before verification. This is **ledger capacity exhaustion**, not proof of physical PSRAM exhaustion or buddy fragmentation behavior.

The worker records the failure as unavailable, frees the 64 B blocker, CPU-zeroes and frees the snapshot, and exits. Bootstrap observes ledger cleanup, reaps the task, yields, and runs the next generation. Before each snapshot worker starts, its result report is reset: an early allocation failure must not leave the prior job's validity fields in the next result. This reset is a preventive fix; the fixture's central failure occurs at the arena allocation, not at the initial snapshot allocation.

| Job | Outcome on 4 MiB emulated PSRAM | Observed resource result |
| --- | --- | --- |
| 1 | Copied valid signature accepted, changed message rejected | Snapshot + arena charged 32,768 B; free restored |
| 2 | Arena allocation reports ledger `Full`; no signature result | Snapshot charged 16,384 B; blocker charged 256 B; both released and free restored |
| 3 | Copied valid signature accepted, changed message rejected | Snapshot + arena charged 32,768 B; free restored |

All three workers exited, had their ledger cleaned, and were reaped; same-slot identities advanced through generations 1, 2 and 3, with stale-handle checks for replacements. Owner heap free was 1,801,536 B before each job and after each cleanup. In the successful jobs the dedicated SRAM stack watermark was 2,960 B; the 8,192 B stack remains statically reserved throughout. These are fixture observations, not maximums or normal-device headroom. The blocker contributes its own transient 256 B PSRAM charge; it is test instrumentation, not a service requirement.

With PSRAM absent, all three jobs return unavailable before snapshot allocation and are reaped; no ledger-full injection takes place. Neither run establishes recovery from heap OOM, first-allocation failure after a preceding success, arena free failure, concurrent mutation, cancellation, arbitrary input lengths, hardware cache/physical erasure or physical Tab5 behavior. CPU-visible clearing is not proof of physical erasure.

## Candidate and validation

Native image audit passed: primary static SRAM 103,040 B, heap span 60,800 B, above the 48 KiB linker floor. The candidate used Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0, and the mldsa-native revision in the source witness. ELF SHA-256 `31a2c480e055c71ecaba636df5d46d983901ee45eace84bc2e9891ab69991890`; image SHA-256 `8fa51da71039f48282bbe25e24049bbab2ee252312a98aa5fae5d55cfc58b45e`.

The [checker](../../probes/pqc/check_worker_pressure_log.py) binds each job to the exact audited image and worker-stack symbol; verifies pressure outcome, cleanup, free-count restoration and generation sequence; and applies the copied-input or unavailable checks to each job. Six altered traces were rejected. [Evidence](evidence/2026-10-29-pqc-pressure/) retains logs, reports, audit, options and source hashes; binaries remain in `build/pqc-pressure-qualified` in the study worktree. This is an opt-in experiment, not a production service API.

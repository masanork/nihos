# Native worker drain failure: normal error path and control

This experiment follows the [ledger fault retention probe](2026-10-29-pqc-worker-quarantine.md), which intercepted an allocator error to inspect the retained entry. Here the headless emulator exercises the **ordinary native `cleanupOne` error branch** instead. Two separately audited images execute the same fixture with different compile-time injection modes.

In both images a CPU0 worker verifies the public ML-DSA-65 fixture, wipes its 16,304 B arena, deliberately retains the allocation, and exits. Before cleanup, the bootstrap verifies that its ledger has one owned, pending allocation and records the 16,384 B charge. In failure mode only, `cleanupOne` passes caller 1 instead of owner 0 to the real buddy-backed `drainOne`; all other cleanup logic is the normal path. In control mode it passes the correct owner. The erroneous caller is a deliberate deterministic fault, not evidence of spontaneous hardware failure.

| Observation | Wrong-owner injection | Correct-owner control |
| --- | --- | --- |
| Ledger before drain | One owned and pending | One owned and pending |
| CPU0 outcome | `NIHOS_NATIVE_FAIL task invariant` | Cleanup and reap completed |
| Owner free bytes | 1,785,152 before failed drain; no post-failure sample | 1,785,152 before drain; 1,801,536 afterward |
| Observation window | 4 seconds; no control completion record | 4 seconds; completion record present |

The failure handler masks CPU0 interrupts and spins. No post-fault ledger or heap observation is made in that run, and the experiment does not assert that CPU1 is stopped. The preceding intercepted-error experiment separately observed a retained entry and unchanged free count. Neither experiment implements a recoverable error report or a quarantine recovery workflow. The control confirms the worker-owned allocation is released by the existing ordinary cleanup path under the specified correct-owner conditions.

## Exact images and checks

Both used Zig 0.17.0, the ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0, 4 MiB emulated PSRAM and the source revision in the witness. Both passed native image audit. Primary static SRAM / heap span were 99,904 B / 63,936 B for failure mode and 100,544 B / 63,296 B for control mode; both include the fixed 8,192 B worker stack and pass the 48 KiB linker floor. These are fixture-image quantities, not normal-device headroom.

- Failure ELF `84ca22449f7523bfad82fce47798f55a9bfe9f8be2955a8e3d0ea4464efc8813`; image `a83f399ef9bf526441708262442dffc3581568c475bb1e9c2f043ef60cfdcd9c`.
- Control ELF `90b809eb93f5bf3cf150850ea222043b234da3eccd3e0c4cd7e6aa37f2636879`; image `1a9eeaf7f0897cf4ec4d206416b7f7931600748b10bff7ddb04d84aaf3c41218`.

The [checker](../../probes/pqc/check_worker_drain_log.py) binds each log to its exact audited ELF/image and SRAM stack symbol, checks preconditions, expected failure or cleanup, and the bounded timeout. Six mutated failure/control traces were rejected. [Evidence](evidence/2026-10-29-pqc-drain/) retains raw and normalized logs, reports, image audits, options and source hashes; exact binaries remain under `build/pqc-drain-failure` and `build/pqc-drain-control` in the study worktree. The 4-second observation is a bounded trace, not a proof of behavior for all later time.

No PSRAM-absent, physical Tab5, UI, concurrent job, reset, power-loss, corrupted allocator, failed zeroing, or cross-hart error recovery case was tested.

# ML-DSA verification on an independent native worker

An opt-in **headless emulator experiment** executes the same public ML-DSA-65
fixture as the previous arena probe on a distinct CPU0 scheduler task. It is
not the normal UI, a reusable crypto service, a general dynamic task API, or a
physical Tab5 result. The mode is restricted to `PQC_VERIFY_PROBE=2`, emulator,
integer and no display/network/normal-fast boot. `PQC_XIP` is not used; this
candidate places its verification code in SRAM.

The experiment reserves one separate 8,192 B, 64-byte-aligned stack in primary
SRAM BSS. Existing bootstrap, interrupt and 4 KiB worker stack reservations are
unchanged. The stack is registered only from CPU0 with local interrupts masked,
and only inside the linked BSS. Trap capture verifies its guard, frame bounds,
alignment and CPU0's IRQ stack; the scheduler also validates the task image's
own stack bounds. Registration is experimental and cannot register arbitrary
PSRAM. The stack is **static**, remains reserved after the task completes, and
is not added to the heap.

The worker owns its PSRAM arena. The foreground loop publishes a completion
only after the worker has returned, its task has exited, its resource ledger is
cleaned, and the task image is reaped. The experiment unregisters and clears
the static stack after reaping, then makes a scheduler yield before recording
completion, exercising post-reap accounting. This is one job: repeated task
reuse, cancellation, dynamic ownership and forced termination are not tested.

## Exact candidate and execution

The candidate used Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the
pinned mldsa-native revision in the source witness. Its standard image audit
passed. The primary static SRAM was **100,288 B** and the primary heap span was
**63,552 B**, above the 48 KiB linker floor. Its audited worker-stack symbol is
`0x4ff35900..0x4ff37900` (8,192 B) inside SRAM BSS. These are fixture image
figures, not the normal-device budget or runtime free memory.

| Check | 4 MiB emulated PSRAM | PSRAM absent |
| --- | --- | --- |
| Verification | valid accepted, changed message rejected | unavailable; no crypto call |
| Partial OOM cleanup | 25 allocations / 25 frees, two failures, zero live | not applicable |
| Arena | 16,304 B usable; 16,384 B charged; 10,208 B observed peak | none |
| Worker stack watermark | 2,768 B | not measured |
| Captured worker trap frames | 9 | 1 |
| Worker exited, ledger cleaned, task reaped | yes | yes |

During the two signature checks, CPU0's timer advanced 16 ticks and the
foreground bootstrap loop advanced by 68,297 synthetic iterations; CPU1's
bootstrap progressed by 16,883. This demonstrates preemption and both owners'
progress for this input and schedule, not an input-to-display latency or a UI
responsiveness measurement. `mie=8` was observed after verification. The
watermark is based on canary writes and is not a maximum stack bound. CPU-visible
arena clearing is not proof of physical PSRAM erasure/cache writeback.

The [worker checker](../../probes/pqc/check_worker_log.py) binds each report
to the exact ELF and image hashes in the image audit, locates the 8 KiB object
symbol and checks its bounds in audited SRAM BSS. It validates the success and
no-PSRAM logs and rejects manipulated foreground progress, capture count and
reap status. The 4 MiB run terminates at the experimental completion marker;
it is **not** the 300-round scheduler smoke. The prior and current ordinary
smokes are separate checks and do not extend this fixture's scope.

[Retained evidence](evidence/2026-10-29-pqc-worker/) contains normalized logs,
raw gzipped serial bytes, reports, options, audit and source hashes. Exact ELF
and images remain under `build/pqc-worker-qualified` in the study worktree.
Reproduction and checker commands are in [the probe README](../../probes/pqc/README.md).

No normal UI, actual touch input, cache-off/Flash write, cancellation race,
long workload, timing tail, concurrent device activity or physical hardware was
tested. Before use as a service, establish a reusable task/stack lifecycle,
context switching and failure behavior for repeated jobs, input ownership and
cancellation; then implement real Flash/cache coordination and measure the
normal live UI, finally testing identity-matched physical firmware.

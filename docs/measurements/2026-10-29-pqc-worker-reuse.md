# Repeated ML-DSA worker jobs

This extends the [single-worker headless experiment](2026-10-29-pqc-independent-worker.md), not the normal device UI or a production crypto service. With `NIHOS_NATIVE_PQC_WORKER_REPEAT=1`, CPU0 starts, observes exit and resource-ledger cleanup, reaps and yields after each of three sequential jobs. It then re-registers the same fixed SRAM stack for the next job. The report publication flag is reset only after the previous task has exited and been reaped. The dedicated 8,192 B stack remains reserved throughout.

After starting jobs 2 and 3, the fixture checks that the previous generation's task handle is rejected by the CPU0 scheduler policy. The observed handles were `00010001`, `00020001`, `00030001`: slot 1, generations 1, 2 and 3. This exercises stale scheduler handles, not all resource APIs or a cancellation race. The first job has no previous handle; its recorded stale flag is a placeholder.

The exact candidate's standard native image audit passed. Primary static SRAM was 100,800 B and heap span 63,040 B; these are headless fixture numbers, not normal-device free memory. ELF SHA-256 is `8159312aa7bb5b9f1fc9e90e458d28e37bff2b776724b30f9947b379d1cfdaf7`; image SHA-256 is `d7eb63888256b83ee2519074edb31751893660d029a260700d4fc497a6e98a9e`. Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the pinned mldsa-native source in the witness were used.

| Each of three jobs | 4 MiB emulated PSRAM | No PSRAM |
| --- | --- | --- |
| Outcome | Valid signature accepted; modified message rejected | Unavailable; no crypto call |
| Arena | 16,304 B payload, 16,384 B charged, 10,208 B observed peak | None |
| Allocation cleanup | 25 allocations and frees; 2 injected failures; no live allocations | No allocation |
| SRAM stack watermark | 2,768 B | Not measured |
| Worker trap captures | 9 | 1 |
| Exit, ledger cleanup, reap | Each completed | Each completed |

Each 4 MiB job recorded 16 timer ticks and positive synthetic bootstrap progress on both CPUs during verification. This is evidence of progress for these inputs and this schedule, not UI latency, a worst-case stack bound, or long-term endurance. Clearing is CPU-visible; physical PSRAM erasure is not established.

The [repeat checker](../../probes/pqc/check_worker_repeat_log.py) applies the original worker checks independently to all three jobs, binds the ELF and image to the audit, requires ordered completion and same-slot increasing generations, and validates the stale-handle results. Negative controls changing a stale rejection, generation, completion count, or reap result were rejected. The [evidence](evidence/2026-10-29-pqc-repeat/) contains logs, audit, options, reports and source hashes; exact binaries remain under `build/pqc-repeat-qualified` in the study worktree.

Not tested: cancellation, overlapping jobs, failures during worker setup/reap, generation wrap, forced termination, real UI or touch, Flash/cache-off coordination, or physical hardware. This three-job fixture is not a reusable service or a 300-round scheduler qualification.

# Preemptible ML-DSA verification with a bounded PSRAM arena

This opt-in experiment addresses the interrupt-enabled PSRAM-stack failure in
the [preceding study](2026-10-29-native-mldsa-verify.md). It leaves the CPU on
its existing internal-SRAM bootstrap stack, and passes an owner-bound PSRAM
arena to mldsa-native's `MLD_CONFIG_CUSTOM_ALLOC_FREE` hooks. The allocator is
a bounded bump allocator for **one fixed public test fixture**. It is not a
production cryptographic service, general allocator, key store, or trust policy.

## Results

- ESP-EMU 0.50.0, emulated ESP32-P4 revision 3, 4 MiB PSRAM; Zig 0.17.0,
  ESP-IDF 5.4.4 loader, integer mode, no display/network. Upstream portable C
  mldsa-native revision `33031ee66dfe0231cc5995dd1d4ced467df6b8de`, ML-DSA-65,
  verify-only, `-O2`, reduce-RAM and caller-context custom allocation.
- A valid signature was accepted and a changed message rejected. The fixture
  then limited the arena to 4,096 B, provoked failure after some allocations
  succeeded, required the out-of-memory return and checked cleanup: 25 total
  allocations, 25 frees, two failed allocation requests, zero live allocations.
- The arena has 16,304 B of usable payload; its allocation charged **16,384 B**
  to the owner-local PSRAM buddy heap. `heap_before=1,801,536 B` and
  `heap_after=1,785,152 B` were sampled with local interrupts briefly masked
  around the allocation. They are this emulated owner's instantaneous free
  bytes, not total Tab5 application capacity. The arena high-water was 10,208 B.
- Bootstrap SRAM stack watermark was **3,600 B**, including the caller's live
  stack and any sampled interrupted frames. The 8,192 B bootstrap reservation
  was unchanged. This is a canary-based observed value for these inputs, not a
  worst-case stack bound. The fixed stack guards passed the later full smoke.
- During the two verification calls, CPU0's timer advanced 24 ticks and the
  two CPU0 workers advanced 10,758 and 10,624 progress units, respectively.
  These observations bracket the valid and modified-message verifications and
  show preemption in this run; they are not input-to-display latency evidence.
  Interrupts were restored immediately after the bounded allocation snapshot,
  and `mie=8` was observed after verification. There is no PSRAM stack switch.
- The CPU observed the arena as zero after clearing it, and the task lease was
  returned. This is not proof of external PSRAM erasure or cache writeback.
- With PSRAM absent, the fixture returned unavailable before verification.

## Same-source native image comparison

The `0` and `2` opt-in builds use the same source, integer configuration and
loader; the feature switch is the relevant change. C code and public fixture
bytes reside in internal SRAM in this experiment, not Flash XIP.

| Resource | Off | Arena fixture | Difference |
| --- | ---: | ---: | ---: |
| Primary static SRAM | 76,416 B | 96,640 B | +20,224 B |
| Primary heap span | 87,424 B | 67,200 B | -20,224 B |
| SRAM reserved including fixed stacks | 133,760 B | 153,984 B | +20,224 B |
| Application image | 80,880 B | 101,408 B | +20,528 B |

The 48 KiB primary-heap link gate and complete native image audit passed for
both candidates. The heap span is not instantaneous free bytes. These figures
include fixture and measurement instrumentation; they are not a measured
production service cost or the normal interactive image's headroom.

Both candidates passed the 300-round native scheduler/lifecycle, IPI/idle, FP
and owned-memory smoke. The fixture's host C test also passed the valid,
modified-message and partial-OOM cases. The targeted log checker rejects loss
of worker progress, incorrect charge and native failure. Exact logs, audit
receipts and source hashes are in [the evidence folder](evidence/2026-10-29-pqc-arena/).
`.log.gz` preserves raw serial bytes; `.log` has normalized line endings, and
the raw hashes are in the source witness. The exact ELF and images remain in
`build/pqc-arena-account` and `build/pqc-arena-final-off` in this worktree.
See [probe instructions](../../probes/pqc/README.md) to reproduce.

## Boundaries and next work

No physical Tab5, normal display/touch workload, cache-off/Flash-write
interaction, repeated worst-case workload, authenticated update or production
security validation was tested. The failure injection is one controlled OOM
path, not exhaustive allocation-failure coverage. The 16,304 B arena is an
experimental bound: other valid or malformed inputs and future compiler or
library changes still require analysis and testing. The bump allocator resets
only when the operation is finished and owns no concurrent users.

Next establish a real service contract with bounded request and buffer
lifetimes, cancellation and cleanup, public-key trust policy, PSRAM/cache
coordination, and separately evaluated Flash code placement. Verify the normal
image's SRAM margin and UI/input latency, then use an identity-matched physical
candidate. ML-KEM additionally needs entropy readiness and secret-key lifetime.

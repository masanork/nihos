# Experimental native ML-DSA verification: SRAM and stack

This is an opt-in measurement fixture, not a cryptographic service. It uses
public ML-DSA-65 vectors from mldsa-native revision
`33031ee66dfe0231cc5995dd1d4ced467df6b8de` (Apache-2.0 OR ISC OR MIT for
library files). The external checkout is revision-checked and not vendored.
The fixture tests one valid signature and one modified message.

The measured native image uses Zig 0.17.0, ESP-IDF 5.4.4 loader, portable
mldsa-native C `-O2` with `MLD_CONFIG_REDUCE_RAM`, verify-only, and no
randomized API. It places the C code and fixture data in **internal SRAM**.
The comparison uses emulator revision-3 integer images from the same source
and options, with only `NIHOS_NATIVE_PQC_VERIFY_PROBE` changed. This is not
the normal display/network/device profile.

| Resource | Probe off | Probe on | Difference |
| --- | ---: | ---: | ---: |
| Primary static SRAM | 76,416 B | 94,848 B | +18,432 B |
| Primary SRAM heap span | 87,424 B | 68,992 B | -18,432 B |
| Reserved SRAM including fixed stacks | 133,760 B | 152,192 B | +18,432 B |
| Application image bytes | 80,880 B | 99,520 B | +18,640 B |

The 48 KiB heap linker gate passed. Heap span is not observed free space or
per-task capacity. The application image includes its SRAM load contents;
therefore the Flash image growth above is not XIP code placement. The values
are for this fixture, not the normal profile. A separate device-revision ELF
link (not a complete/audited device image) gave heap spans 87,168 B and
68,736 B with the same 18,432 B difference.

## Execution and failure boundary

With 4 MiB emulated PSRAM, the fixture borrowed a 32,768 B task-owned lease
as a stack, accepted the good signature, rejected a modified message, observed
12,336 B stack watermark with its 256 B guard intact, zeroed the stack as read
by the CPU, and returned the lease. These results cover **two consecutive
verifications in this one fixture**, not an upper bound over all inputs.
A zero-byte PSRAM run reported allocation unavailable, without executing the
cryptographic operation.

The first attempt left CPU0 interrupts enabled and failed with
`NIHOS_NATIVE_FAIL interrupt stack/MIE`; its ELF/image audit and log are retained.
The native stack capture only accepts the configured internal stack regions,
so a PSRAM interrupted frame is a likely cause, although that generic failure
record did not isolate which predicate failed. For measurement only, the
successful fixture masks CPU0 interrupts around both verifications. This blocks
local interrupt handling, so it is not suitable for UI/real-time use. It logs
`masked_cycles=8332475` in this emulated run; emulator cycles are not a Tab5
wall-time measurement. Other log ticks cover a larger interval and do not prove
UI responsiveness. Cache-disabled access, exception paths and preemptible PSRAM
stacks remain unsolved.

The watermark measures writes against a canary, not every possible stack pointer
movement, and guard preservation is not a complete overflow proof. CPU-visible
zero readback is not evidence of physical PSRAM erasure or cache writeback.
No private key or production entropy is used. No physical Tab5 was accessed.

## Evidence and reproduction

[Artifacts and source witness](evidence/2026-10-29-pqc-native/), including the
failed attempt, bind the logs to the retained image audits. The `.log` files
normalize CRLF; the corresponding `.log.gz` files preserve raw bytes, with raw
SHA-256 values in the source witness. Exact ELF and image
files remain under `build/pqc-image-final` and `build/pqc-failed-interrupt` in
the study worktree. Rebuild and log-check instructions are in
[probes/pqc/README.md](../../probes/pqc/README.md). A full base smoke and the
fixture smoke validate the 300-round scheduler/lifecycle, IPI, floating-point
and owned-memory checks under the emulator. They are not physical, UI, side
channel or FIPS certification evidence.

Before production support, measure the same comparison under the real normal
image, investigate a preemptible task/stack contract or a measured bounded
SRAM-only implementation, and validate Flash execution/cache interaction,
cleanup, latency, trust anchors and physical hardware. The ML-KEM key path
still requires a suitable entropy and secret-key lifetime design.

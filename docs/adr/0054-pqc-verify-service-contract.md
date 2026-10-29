# ADR 0054: Proposed ML-DSA verification service boundary

Status: **proposed; lifecycle model only**. This is not a shipped service or
an authorization to accept signed updates. The measurement fixture in
[the arena study](../measurements/2026-10-29-preemptible-mldsa-arena.md)
uses synthetic public data and does not implement this contract.

## Purpose and first scope

Allow a responsive application to ask the OS to verify a small, immutable
message without owning the verifier's working memory or blocking the UI.
The first profile is **pure ML-DSA-65** with an explicitly supplied FIPS 204
context. A preliminary message limit of 4,096 bytes is a design target, not a
measured or guaranteed service capacity. Encoded public key, signature and
context bounds are respectively 1,952, 3,309 and 255 bytes. Reject oversized,
malformed and unsupported inputs before publishing a request. HashML-DSA,
streaming file verification, other parameter sets, signing and ML-KEM are
separate profiles and are not implied by this one.

The small-message profile deliberately does not equate a caller's arbitrary
prehash with HashML-DSA. For larger immutable content, specify the signed
format, prehash mode and snapshot lifetime separately before adding an API.

## Interfaces and authority

The following is an intended contract, not existing Zig ABI:

```text
submit_verify(requester, public_key, signature, context, message) -> job | error
poll_or_notify(requester, job) -> pending | result
cancel(requester, job) -> accepted | too_late | stale
```

`result` distinguishes valid, invalid, unavailable/resource exhausted,
cancelled and internal failure. A verifier operating on a caller-supplied key
reports only mathematical signature validity. It does **not** attest the
signer, trust an artifact, or authorize firmware installation.

A future higher-level signed-artifact policy must select an OS-managed trust
anchor by authorized purpose and key identifier, validate the artifact format,
algorithm/context and version, and bind the verified bytes to the bytes used.
Only an authorized administrator or provisioned update mechanism can change
trust anchors or their purposes. Key rotation/revocation, persistence,
anti-rollback and recovery are separate required designs; an arbitrary caller
cannot promote a raw public key to a trust anchor. Fail closed on missing,
ambiguous, expired-by-policy or unauthorized anchors. An untrusted network time
source must not silently establish certificate expiry validity.

## Ownership and state transitions

- Admission authenticates the actual task identity `(hart, slot, generation)`,
  checks job generation, resource limits and permissions, then snapshots the
  exact request bytes into service-owned bounded memory. A job token is not a
  substitute for authenticating the calling task. Reject a stale generation,
  token reuse, duplicate publication and saturation without changing live jobs.
- The initial proposal is one active job and no unbounded queue. `Busy` is an
  explicit retry result. The service worker, not the requesting application,
  owns the input snapshot and arena until the worker has stopped using them.
  No call may retain a pointer to caller memory past admission.
- With a cancelled queued job, discard it and enter cleanup. For a running
  synchronous verifier, cancellation marks the result for discard; it does
  **not** stop the C call or permit freeing input/arena while it runs. Once the
  worker acknowledges completion, cancellation wins over the computed result
  if it was accepted before completion. If completion already won, cancellation
  reports `too_late`. A timeout follows the same deferred-cleanup rule and is
  not a hard execution deadline.
- The worker publishes exactly one result only after successful cleanup and
  release. Failed cleanup or ambiguous ownership quarantines the job and its
  workspace, blocks reuse, and yields an explicit service failure/recovery
  path; it must not make the workspace appear free. A vanished or reused client
  generation never receives an old completion, and the worker must still finish
  and clean up. Cross-hart routing and task death require explicit integration
  with the real ledger, not merely the model below.
- Interrupt/trap paths never perform verification, allocate or access the
  PSRAM arena. CPU0 must not run a synchronous verifier from the UI foreground
  if responsiveness is required. Use a schedulable, separately owned worker
  and bounded result publication; the current normal boot does not yet provide
  such a verification worker. The existing 4 KiB worker stacks are not assumed
  sufficient from a 3,600 B bootstrap watermark.

## Memory and coordination

For a feasibility budget only, the largest proposed copied request is 9,612 B
(1,952 + 3,309 + 255 + 4,096), before metadata. A single 16,304 B arena
payload measured a 16,384 B PSRAM buddy charge in the emulator. With the
current buddy header/alignment and a separately allocated 9,612 B snapshot,
the two charges would total 32,768 B, before service metadata or other live
allocations. This is an arithmetic estimate, not a measured integrated peak;
actual allocation size, alignment, granularity, duplication and fragmentation
must be measured with the chosen layout. The 16,304 B arena limit is
experimental and its behavior over all valid/malformed inputs is unqualified.

A future cache-off coordinator must close admission before observing holders,
wait for every previously admitted cache-dependent operation and relevant DMA
to quiesce, and receive generation-matched quiescence acknowledgments from both
harts before disabling the cache. No new holder may enter during draining or
cache-off. Reopen only after restoration is confirmed; failed restoration is a
quarantined state. The coordinator, acknowledgment path and any required IRQ
handlers must themselves remain available with the cache off. An early check
followed by later unregistered entry has a TOCTOU race.

`probes/pqc/cache_gate_model_test.py` tests a serialized abstraction of these
transitions and the check-then-enter counterexample. It assumes all actual
cache-dependent operations, interrupts and DMA are registered and models no
hardware memory ordering, cache registers, or interrupts. The native system has
no integrated coordinator, and the model is not a production cache-off guard.

The service must preserve the existing SRAM heap minimum, separately account
for permanently resident code/data and peak task/IRQ stacks, and verify
PSRAM cache availability throughout execution. Coordinate Flash writes and
cache-disabled windows with all affected cores and DMA; if availability cannot
be guaranteed, refuse/defer execution before taking the job. CPU-visible zero
checks alone do not prove PSRAM writeback or physical clearing. Public verify
inputs are not secret by default; do not make a secret-erasure guarantee for
this path. Future signing/KEM needs its own stronger key and cleanup contract.

## Acceptance tests before promotion

1. Known-answer vectors and independently generated valid and invalid cases;
   context mismatch, malformed encodings, unsupported profiles, length limits
   and OOM at every allocation point. Confirm output errors are unambiguous.
2. Lifecycle race tests: queued/running cancellation, completion-vs-cancel,
   caller death and generation reuse, duplicate/stale token, bounded capacity,
   repeated calls, failed cleanup/quarantine, and no release before worker stop.
3. Exact-image SRAM/PSRAM ledger, actual peak stack, code/rodata placement and
   largest allocation with UI, network and devices active. Test absent PSRAM,
   allocation failure, cache-disabled/Flash-write coordination and recovery.
4. Native emulator and exact-candidate physical Tab5: UI input-to-display latency
   distribution and worst tail under repeated verifications, frame progress,
   task fairness, lifecycle, cancellation and resource return. Record hashes,
   loader and serial ownership; warm reset and cold power cycle are separate.
5. Only a higher-level artifact policy can accept a signer or an update; test
   unauthorized keys, incorrect purpose/context, rotation, rollback and recovery.

`probes/pqc/service_model.zig` exercises a serialized lifecycle abstraction and
negative controls. It does not model data races, actual scheduling, memory
safety, cache behavior, cryptographic conformance or trust-store persistence.

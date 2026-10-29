# Isolated PQC resource probes

These compile-only wrappers exercise the pinned Zig standard library with encoded
inputs and outputs. Deterministic seeds are test fixtures, never production
entropy. They do not erase secrets and must not be shipped as a service.

Reproduce with Zig 0.17.0:

```sh
ZIG=/path/to/zig python3 probes/pqc/measure.py
/path/to/zig test probes/pqc/host_test.zig -O ReleaseSafe
```

`build/pqc-resource/report.json`, object files and assembly are generated locally.
Object allocated sections are summed before linking, garbage collection, alignment,
compiler runtime and other system code; they are not firmware growth measurements.
The frame parser reads the straight-line entry prologue up to its first branch or
call. It is not a call graph or whole-operation stack bound. Inspect emitted
assembly when changing compiler or wrapper. Host testing does not execute RV32.

## PQ Code Package comparison

Check out the exact upstream revisions listed in the measurement report,
then run the first `measure.py` command above followed by:

```sh
ZIG=/path/to/zig MLKEM_SOURCE=/path/to/mlkem-native \
  MLDSA_SOURCE=/path/to/mldsa-native python3 probes/pqc/compare_native.py
```

The script checks the revisions and rejects tracked source modifications. It
links standalone operation roots with garbage collection and a minimal runtime;
they are not complete firmware images. The C implementation is compiled with
`-O2`, while Zig is ReleaseSafe; compare build choices as well as algorithms.

For the host interoperability fixture, using the same source revisions:

```sh
"$ZIG" test probes/pqc/interop_test.zig -O ReleaseSafe -lc \
  -DMLK_CONFIG_NO_RANDOMIZED_API -DMLK_CONFIG_PARAMETER_SET=768 \
  -DMLD_CONFIG_PARAMETER_SET=65 -DMLD_CONFIG_REDUCE_RAM \
  -DMLD_CONFIG_NO_RANDOMIZED_API -DMLD_CONFIG_NO_SIGN_API \
  -DMLD_CONFIG_NO_KEYPAIR_API -I "$MLKEM_SOURCE/mlkem" \
  -I "$MLDSA_SOURCE/mldsa" "$MLKEM_SOURCE/mlkem/mlkem_native.c" \
  "$MLDSA_SOURCE/mldsa/mldsa_native.c"
```

Fixed test seeds do not provide production entropy. No external source is
vendored by this probe.

## Experimental native verification fixture

The opt-in `NIHOS_NATIVE_PQC_VERIFY_PROBE=1` links the pinned external
mldsa-native checkout (`NIHOS_MLDSA_SOURCE`) into the regular native ELF build.
It verifies upstream's public fixture and rejects a changed message on a 32 KiB
owner-allocated PSRAM stack. The current trap stack contract rejects PSRAM task
frames; the measurement temporarily masks CPU0 interrupts during both checks.
This is a measurement fixture, **not** an interactive or production service.
CPU-visible zero readback does not establish external-memory erasure.

```sh
NIHOS_NATIVE_PQC_VERIFY_PROBE=1 NIHOS_MLDSA_SOURCE=/path/to/mldsa-native \
  sh tools/build-native.sh emulator integer
```

Retain the exact built image/ELF/audit before running ESP-EMU. Check a full log
with both `tools/check-native-log.py` and `probes/pqc/check_native_log.py LOG 4M`.
For no PSRAM, the latter accepts `LOG 0` and requires unavailable status.
See the native measurement document for commands, results and limitations.

## Preemptible verification with a bounded arena

The opt-in value `NIHOS_NATIVE_PQC_VERIFY_PROBE=2` configures mldsa-native's
per-call allocator/context hooks. It keeps the CPU on the existing bootstrap
SRAM stack and allocates a 16,304-byte owner-bound PSRAM workspace. A brief
local interrupt mask makes the heap accounting snapshot and allocation atomic;
the two verification calls run with interrupts enabled. This is still a
fixed-vector fixture, not a service or a validated general-purpose allocator.
It also injects partial allocation failure and requires every successful
allocation to be freed. The `0` profile below disables the fixture.

```sh
NIHOS_NATIVE_PQC_VERIFY_PROBE=2 NIHOS_MLDSA_SOURCE=/path/to/mldsa-native \
  sh tools/build-native.sh emulator integer
```

After retaining the exact image, run the emulator and check the record with
`python3 probes/pqc/check_arena_log.py LOG 4M` (or `LOG 0` for absent PSRAM),
in addition to the normal native smoke checker for a full run.

The fixture can also be compiled and tested on the host with:

```sh
"$ZIG" cc -O2 -std=c11 -DMLD_CONFIG_PARAMETER_SET=65 \
  -DMLD_CONFIG_REDUCE_RAM -DMLD_CONFIG_NO_RANDOMIZED_API \
  -DMLD_CONFIG_NO_SIGN_API -DMLD_CONFIG_NO_KEYPAIR_API \
  -include probes/pqc/native_arena.h -I probes/pqc \
  -I "$MLDSA_SOURCE/mldsa" \
  -I "$MLDSA_SOURCE/examples/monolithic_build_multilevel" \
  "$MLDSA_SOURCE/mldsa/mldsa_native.c" \
  probes/pqc/native_arena_verify.c probes/pqc/native_arena_host.c \
  -o /tmp/nihos-pqc-arena-host
/tmp/nihos-pqc-arena-host
```

## Normal-profile link-size diagnostic

After the expected normal-image PQC link failure has compiled its two C
objects, run `sh probes/pqc/normal_link_study.sh`. It links only the C fixture
root with stand-in memory routines and a no-op observer. Its output is not
a native image, an XIP qualification, or an integrated firmware size. See
[the normal-image study](../../docs/measurements/2026-10-29-pqc-normal-image-budget.md).

## Proposed service lifecycle model

`zig test probes/pqc/service_model.zig -O ReleaseSafe` exercises the proposed
single-job ownership, cancellation, cleanup and generation transitions. This
host-only model is not the native service implementation; see
[ADR 0054](../../docs/adr/0054-pqc-verify-service-contract.md).

## Experimental normal-device XIP image

`NIHOS_NATIVE_PQC_XIP=1` moves the fixed verify fixture C objects into the
explicitly audited Flash sections. It is only accepted with the normal device
arena fixture profile and does not implement an asynchronous worker or a
cache-off protocol. It is not a production switch. Build only:

```sh
NIHOS_NATIVE_PQC_XIP=1 NIHOS_NATIVE_PQC_VERIFY_PROBE=2 \
  NIHOS_MLDSA_SOURCE=/path/to/mldsa-native sh tools/build-native.sh device integer
```

`inspect_xip_calls.py OBJDUMP ELF IMAGE_AUDIT OUTPUT.json` reports annotated
direct incoming branches and unannotated indirect `jalr` sites. It validates
the ELF hash but cannot prove a complete call graph or cache-off safety.
`python3 -m unittest probes.pqc.cache_gate_model_test` checks a separate host
model of the desired gate; no such gate is integrated into native execution.

## Independent worker experiment

`NIHOS_NATIVE_PQC_WORKER_PROBE=1` uses a dedicated 8 KiB internal SRAM BSS
stack for a single arena verification worker. It is restricted to the
headless integer emulator fixture and never implements the normal UI service.
The 8 KiB stack remains statically reserved after the task is reaped.

```sh
NIHOS_NATIVE_PQC_WORKER_PROBE=1 NIHOS_NATIVE_PQC_VERIFY_PROBE=2 \
  NIHOS_MLDSA_SOURCE=/path/to/mldsa-native sh tools/build-native.sh emulator integer
```

After preserving the exact image and ELF, capture the emulator output until
`NIHOS_NATIVE_PQC_WORKER_OWNER`, then validate with
`python3 probes/pqc/check_worker_log.py LOG ELF BIN AUDIT 4M REPORT.json` (or
`0` for absent PSRAM). This is a targeted worker test, not the normal
300-round smoke. See [the worker measurement](../../docs/measurements/2026-10-29-pqc-independent-worker.md).

### Three sequential worker jobs

Add `NIHOS_NATIVE_PQC_WORKER_REPEAT=1` to the independent-worker build to
reap and restart three jobs on the same reserved stack. Capture through
`NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS`, then use
`python3 probes/pqc/check_worker_repeat_log.py LOG ELF BIN AUDIT 4M REPORT.json`
(or `0` with no PSRAM). See [the repeat measurement](../../docs/measurements/2026-10-29-pqc-worker-reuse.md).

### Deferred-cancellation fixture

Add `NIHOS_NATIVE_PQC_WORKER_CANCEL=1` to the three-job worker build to
request cancellation in the verification observation interval of job 2.
Capture through `NIHOS_NATIVE_PQC_WORKER_REPEAT_PASS`, then run
`python3 probes/pqc/check_worker_cancel_log.py LOG ELF BIN AUDIT 4M REPORT.json`
(or `0` for absent PSRAM). The outcome is a fixture record, not a service API.
See [the cancellation measurement](../../docs/measurements/2026-10-29-pqc-worker-cancel.md).

### Cleanup failure and retention fixture

Set `NIHOS_NATIVE_PQC_WORKER_QUARANTINE=1` with the single-worker arena
fixture (do not set repeat/cancel). It retains the worker allocation, injects
an incorrect owner into the real ledger drain, checks the resulting faulted
state and stops. Capture through `NIHOS_NATIVE_PQC_QUARANTINE_DONE`, then run
`python3 probes/pqc/check_worker_quarantine_log.py LOG ELF BIN AUDIT REPORT.json`.
See [the cleanup failure measurement](../../docs/measurements/2026-10-29-pqc-worker-quarantine.md).

### Native cleanup error path and control

With the single worker build, set `NIHOS_NATIVE_PQC_DRAIN_PROBE=1` to retain
its arena and inject a wrong owner into the ordinary cleanup path; `=2` uses
the correct owner as a control. Run each 4 MiB image for 4 seconds (without
an exit-on marker), retain its exact audit and binaries, and run
`python3 probes/pqc/check_worker_drain_log.py LOG ELF BIN AUDIT failure|control REPORT.json`.
See [the fail-stop measurement](../../docs/measurements/2026-10-29-pqc-drain-fail-stop.md).

### Copied-input memory fixture

Set `NIHOS_NATIVE_PQC_SNAPSHOT_PROBE=1` with the single ordinary worker
fixture. It copies the fixed public vector into a 9,612 B task-owned PSRAM
snapshot and verifies from that copy while holding a separate arena. Capture
through `NIHOS_NATIVE_PQC_WORKER_OWNER`, then run
`python3 probes/pqc/check_worker_snapshot_log.py LOG ELF BIN AUDIT 4M REPORT.json`
(or `0` without PSRAM). See [the snapshot measurement](../../docs/measurements/2026-10-29-pqc-input-snapshot.md).

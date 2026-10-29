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

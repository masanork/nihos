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

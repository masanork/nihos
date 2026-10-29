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

# PQC isolated RV32 resource study

Base: nihos `c0ff17d`; Zig 0.17.0, `riscv32-freestanding-none`,
`generic_rv32+m+a+c+zicsr+zifencei`, ReleaseSafe. Probes use encoded
inputs and outputs and compile each operation into a separate object. Reproduce
using [the probe instructions](../../probes/pqc/README.md). No native image was
linked or run, and no Tab5 was accessed.

| Operation | Entry stack frame, bytes | Object executable bytes | Object read-only allocated bytes |
| --- | ---: | ---: | ---: |
| ML-DSA-65 verify | 178,160 | 35,812 | 2,817 |
| ML-KEM-768 keygen | 61,472 | 119,920 | 1,388 |
| ML-KEM-768 encaps | 45,376 | 60,032 | 1,542 |
| ML-KEM-768 decaps | 31,488 | 61,822 | 1,754 |

These are wrapper-specific, compiler-specific values, not inherent algorithm
requirements. Entry frames exclude all callees. In the emitted decapsulation
assembly, the entry calls `SecretKey.decaps`, whose prologue reserves another
42,080 bytes; the two frames alone total 73,568 bytes while that call is live.
Additional callees and interrupt stacks are not included. No stack high-water,
execution time, maximum total working RAM, or native linker impact is measured.
Object sections include code before link-time garbage collection and cannot be
summed as an integrated image budget. Writable allocated and NOBITS sections in
these four objects are zero; this does not mean the firmware uses no SRAM.

The existing 64 KiB private stack for a separate card candidate cannot be assumed
to run these wrappers: even the ML-DSA entry frame alone exceeds it, and the
ML-KEM decapsulation call path shown above exceeds it. The 48 KiB primary heap
linker floor remains a constraint, not runtime free space. This study does not
establish that PSRAM stacks are safe for these operations, nor that direct Zig
stdlib use is the only implementation option.

The host test exercises the actual wrappers with fixed test seeds: KEM roundtrip,
implicit rejection of a modified ciphertext (different shared secret), valid
signature verification and altered-message rejection. It is a smoke test, not a
FIPS conformance test, independent implementation comparison, or security audit.

Next compare a bounded-workspace implementation, with provenance and license,
against the Zig baseline; measure per-operation complete stack and workspace,
plus linked Flash and SRAM against an identical native image. Before production
key operations, design entropy readiness, key lifetime and erasure. Any eventual
PSRAM stack also needs cache-disabled, interrupt, cancellation and lifecycle
qualification. Physical timings, UI responsiveness and side-channel behavior
remain unknown.

# ML-KEM-768 custom arena: host behavior and RV32 link study

This opt-in standalone study evaluates [mlkem-native](https://github.com/pq-code-package/mlkem-native/tree/e0e0ae95765f4c48585dc8cdaa0656d4eda46a06), pinned at `e0e0ae95765f4c48585dc8cdaa0656d4eda46a06`, with its experimental custom-allocation and context-parameter configuration. It is not part of the nihos firmware or a production KEM service. Upstream describes its [custom allocator option](https://github.com/pq-code-package/mlkem-native/blob/e0e0ae95765f4c48585dc8cdaa0656d4eda46a06/mlkem/mlkem_native_config.h) as experimental, and it does not move every stack allocation into the custom arena.

A test-only 32-byte-aligned bump arena is reset between operations. It does not reuse an allocation's space when freed; its `peak` is the cumulative rounded allocation cursor during one operation, not peak live bytes or a proven minimum workspace. On an arm64 host, Zig 0.17.0 and portable C `-O2`, the deterministic ML-KEM-768 test measured:

| Operation | Arena cursor peak | Successful allocations / frees | Injected failure positions |
| --- | ---: | ---: | ---: |
| Key generation | 10,112 B | 7 / 7 | 7 |
| Encapsulation | 15,904 B | 14 / 14 | 14 |
| Decapsulation | 19,232 B | 19 / 19 | 19 |

Each of the **40** allocations on the corresponding successful path was failed in a separate run; each returned the out-of-memory error with zero live allocations and balanced successful allocations/frees. A separate [negative-control patch](evidence/2026-10-29-mlkem-arena/leak-mutant.patch) deliberately leaves the live count unretired; the test rejects it at key generation (expected zero, observed seven). The test's free hook also inspected each returned region and saw zero bytes before releasing it. This is an observation of the host implementation and test inputs; it does not prove PSRAM physical erasure or erasure of every secret copy.

Using fixed public test seeds and coins, C and Zig produced matching encoded public and secret keys, ciphertext and shared secret; decapsulation matched. For a modified ciphertext, both implementations returned the same alternate shared secret, different from the original, while the C decapsulation call returned success. This is the relevant implicit-rejection behavior for this vector: a service must not treat successful decapsulation alone as peer authentication. See [FIPS 203](https://csrc.nist.gov/pubs/fips/203/final) and [NIST SP 800-227](https://csrc.nist.gov/pubs/sp/800/227/final).

## Standalone RV32 code generation

The same custom allocator configuration compiled for `riscv32-freestanding-none`, `generic_rv32+m+a+c+zicsr+zifencei`, `-O2`. Each operation was linked separately with the test allocator and a tiny link-only runtime, with dead-section elimination. Totals count allocated executable and read-only ELF sections and exclude writable data, alignment/padding, callers, firmware, key buffers and stack. They cannot be summed to predict a combined service because operations share code.

| Standalone root | Executable | Read-only |
| --- | ---: | ---: |
| Key generation | 13,470 B | 1,852 B |
| Encapsulation | 15,294 B | 2,160 B |
| Decapsulation | 16,500 B | 2,304 B |

All three had zero writable or NOBITS allocated sections in this isolated link; that is not a total RAM measure. The RV32 binaries were not run. In particular, the 19,232 B host decapsulation cursor is greater than the 16,304 B arena payload used by the ML-DSA experiment, so that allocation size is not sufficient for this host allocator and input. It is not an RV32 maximum or a measured PSRAM buddy charge. Stack high-water, code placement, complete image SRAM impact, PSRAM footprint, device latency, concurrent UI, cleanup under target failures and side channels remain unmeasured.

The use case is KEM-based shared-key establishment inside a separately specified authenticated protocol, not a replacement for ML-DSA signature verification. A production path additionally needs sound entropy for key generation and encapsulation, authenticated peer and algorithm binding, secret-key/shared-secret ownership, error handling, key derivation, zeroization and storage/recovery policy. Deterministic seeds and coins here are test material only; they are unsafe for real keys. No FIPS validation or production security claim follows from this test.

[The script](../../probes/pqc/run_mlkem_arena.sh) checks the upstream revision and tracked cleanliness, reproduces host tests and RV32 links, and writes `build/pqc-mlkem-arena/`. [Evidence](evidence/2026-10-29-mlkem-arena/) records the log, ELF-section report and source/artifact hashes; exact objects and ELFs remain in that build directory. No third-party source is vendored. Before integrating the pinned source, review its exact files' licenses and notices.

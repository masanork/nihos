# PQC Code Package standalone RV32 comparison

Base nihos `623b9e7`; Zig 0.17.0, `riscv32-freestanding-none`,
`generic_rv32+m+a+c+zicsr+zifencei`. The external sources are not vendored.
The comparison uses the portable C monolithic build at these exact revisions:

- [mlkem-native](https://github.com/pq-code-package/mlkem-native/tree/e0e0ae95765f4c48585dc8cdaa0656d4eda46a06), `e0e0ae95765f4c48585dc8cdaa0656d4eda46a06`.
- [mldsa-native](https://github.com/pq-code-package/mldsa-native/tree/33031ee66dfe0231cc5995dd1d4ced467df6b8de), `33031ee66dfe0231cc5995dd1d4ced467df6b8de`.

Both projects state that their library source is available under Apache-2.0 OR
ISC OR MIT, with file-specific exceptions outside the library. No third-party
code has been copied here. Any future vendoring must retain file copyright and
license notices and review the exact files used.

The ML-DSA build selects 65, `MLD_CONFIG_REDUCE_RAM`, verify-only and no
randomized API. ML-KEM selects 768 and deterministic test APIs. These are
measurement configurations, not an entropy or production-key design. The
low-RAM option reduces internal stack allocations; it does **not** expose an
explicit caller-owned workspace in the API.

## Standalone link sizes

Each root is linked separately with `--gc-sections` and the same tiny link-only
`memcpy`/`memset` runtime. The C library is `-O2`; the Zig probe is
`ReleaseSafe`, so this is a comparison of complete build choices, not a
controlled claim about language or algorithm. Totals below are allocated
executable plus read-only section bytes; they exclude padding and ELF metadata.
They are **not** incremental sizes of a nihos firmware image, do not include
service wrappers, and cannot be added to estimate multiple operations because
functions may be shared.

| Operation | PQ Code Package code + read-only | Zig probe code + read-only |
| --- | ---: | ---: |
| ML-DSA verify | 11,072 + 1,976 B | 35,882 + 3,000 B |
| ML-KEM keygen | 13,198 + 1,752 B | 119,990 + 1,604 B |
| ML-KEM encaps | 14,722 + 2,048 B | 60,102 + 1,758 B |
| ML-KEM decaps | 15,822 + 2,180 B | 61,892 + 1,994 B |

All isolated linked binaries have zero writable allocated/NOBITS sections.
This does not count stack or caller buffers and is not a runtime SRAM result.

## Stack evidence

ML-DSA verify's entry prologue reserves 384 bytes and calls `verify_internal`,
whose prologue reserves 10,336 bytes. Both additionally align the stack down to
32 bytes. Therefore at least 10,720 fixed bytes are live on this path, plus
alignment and any further calls. In the prior Zig probe, the verification entry
frame alone was 178,160 bytes. The measurements show a strong candidate for
further evaluation, but **neither number is a whole-operation stack bound**.

The ML-KEM C entry prologues reserve 240 B for keygen, 384 B for encaps and
1,568 B for decaps. These are only entry frames and cannot be compared directly
with the Zig entry frames to establish peak use: most C work is in callees.
No static complete call graph, stack watermark, PSRAM workspace or SRAM firmware
budget has been measured here.

## Checks and boundaries

- Upstream deterministic ML-KEM example passed its known vectors and the
  mldsa-native low-RAM example passed roundtrip for 44/65/87 on the host,
  rebuilt with portable C (`AUTO=0`). Those example builds are not identical
  to the verify-only RV32 configuration.
- A host test compiled both monolithic portable implementations using the
  comparison configuration. It verified a Zig ML-DSA signature with C, rejected
  an altered message, compared deterministic ML-KEM encoded keys, ciphertexts
  and shared secrets byte for byte, and decapsulated in both implementations.
- All four RV32 standalone roots linked; they were **not executed on RV32**.
  No target speed, all-service SRAM/PSRAM budget, physical Tab5 behavior,
  entropy, side-channel assessment or FIPS validation is established.
- The test inputs are fixed and non-secret. The test runtime is for linking
  only. Neither constitutes a production security integration.

Reproduce using [probe instructions](../../probes/pqc/README.md). Next, freeze
one native firmware baseline and implement an opt-in verify-only adapter with
explicit ownership, PSRAM availability and cleanup. Compare identical images
and measure actual full call-chain stack high-water on emulator and then Tab5,
including UI/input and Flash-cache interactions. Evaluate ML-KEM separately;
production key generation requires the RNG and secret-lifetime contracts first.

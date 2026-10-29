# Combined ML-DSA / ML-KEM in the normal device profile: link study

This compares four ESP32-P4 rev1/2 device-profile **builds**, with the same normal display/live console, network and on-demand device configuration. None was flashed or executed on physical hardware. The first is PQC-disabled; the second is the existing ML-DSA-65 verify-only XIP fixture; the last two are separate, patched worktrees with both ML-DSA and ML-KEM-768 code retained. The experimental patches are not part of the normal product build.

| Build | Primary static SRAM | Linker heap span | Application image |
| --- | ---: | ---: | ---: |
| PQC disabled | 100,992 B | 62,848 B | 185,648 B |
| ML-DSA fixture | 102,976 B | 60,864 B | 206,336 B |
| ML-DSA + full ML-KEM test fixture | 111,104 B | 52,736 B | 232,032 B |
| ML-DSA + retained ML-KEM API roots | **105,728 B** | **58,112 B** | 226,096 B |

All four linked with the existing 49,152 B heap floor and passed their respective structural image audits. Heap span is a linker address range, not measured free capacity after runtime initialization. The retained-roots image increases static SRAM by **4,736 B** against disabled and **2,752 B** against the ML-DSA fixture. It retains all three deterministic ML-KEM API entry points and their reachable code through linker `KEEP`; it excludes the ML-KEM test worker and its fixed key/ciphertext vectors. It does **not** submit a KEM job, provide an API, exercise key handling or prove that such a service will fit.

The 8,192 B experimental worker stack from the headless runs is **not reserved in either normal-profile dual build**. For the retained-roots image, subtracting exactly 8,192 B from the linked heap leaves 49,920 B, only 768 B above the policy floor. This is arithmetic, not a build of a real worker; its wrapper, state, alignment, request handling and other integration costs could consume more. For the full-test-fixture image, the same arithmetic gives 44,544 B, 4,608 B below the floor. Neither result proves that an asynchronous worker fits.

## Flash placement tradeoff

Placing the complete two-algorithm C fixtures in the existing two Flash windows failed: the executable window overflowed by 3,508 B and the read-only window by 2,208 B. Another first attempt at a split placement linked but `esptool` rejected the resulting ELF segment order as overlapping a 64 KiB Flash mapping. Both failed logs are retained.

The full-fixture image moves the 5,668 B ML-KEM Keccak function and the 2,400 B fixed **test** secret-key vector into primary SRAM. It leaves 2,160 B in the first Flash window and 192 B in the read-only window. The retained-roots image instead excludes the KEM test fixture and moves two KEM internal functions, 2,710 B total, into SRAM; its Flash executable/read-only remainders are **302 B** and **2,592 B**. The 302 B executable slack is especially sensitive to compiler changes or added code. The test vector is public test material, not a production secret, and the particular split is a sizing experiment rather than a recommended production layout.

Both experimental device-profile audits were adapted for their respective fixed function inventories and exact mapped image bytes, and retained the heap floor. Those inventories are based on these test builds; they are not independently reviewed production call graphs. Four audit negative controls per variant rejected an unknown Flash function, missing profile marker, executable read-only section and changed Flash image byte. The comparison checkers reject mismatched options, images and fixtures. Original native-image host tests also passed. The generated Zig options are identical across the ML-DSA and dual builds; the normal-link switch is a separate experimental compile/link setting.

## Artifacts and limitations

The retained-roots ELF SHA-256 is `df6c4ea53282b0be78bd316434212826f91ba6f0ae2b089571378023db59ddd2`, image SHA-256 `324f2a1d924aea52e08b63497335addd8ca56865c21644d2441c1c39931b07e4`. Its underlying Zig 0.17.0, ESP-IDF 5.4.4 loader and exact upstream revisions are recorded in the witness. [Evidence](evidence/2026-10-29-pqc-normal-dual/) retains all four audits and options, reports, failed and successful build logs, negative controls, source hashes and compressed experimental patches. Exact images are retained under `build/pqc-normal-dual-disabled`, `build/pqc-normal-dual-baseline`, `build/pqc-normal-dual-qualified` and `build/pqc-normal-roots-qualified`; corresponding patched worktree paths are recorded in the study build directory.

This is a **link and image-layout result**. The normal profile's existing ML-DSA fixture is still a synchronous test fixture; the retained ML-KEM roots are not called. It does not demonstrate combined operation in the normal UI, actual workload SRAM free, PSRAM availability, Flash/cache-off coordination, production entropy, secret ownership, caller input validation, cancellation, side-channel safety, physical Tab5 operation or power-cycle behavior. Before adopting the placement, implement a genuinely schedulable worker, independently audit its code and Flash dependencies, establish cache-off quiescence, and remeasure the exact integrated image under live device load.

# Combined ML-DSA / ML-KEM with experimental Flash placement

The [all-SRAM combined fixture](2026-10-29-pqc-combined-link-budget.md) failed the 48 KiB primary-heap floor. In a separate worktree, this experiment places both pinned C libraries, their test adapters and their read-only test data into the existing Flash mapping. The **48 KiB linker floor remains intact**. The worktree's [experimental patch](evidence/2026-10-29-pqc-combined-xip/experimental-placement.patch.gz) also enables this headless emulator profile and adapts the image auditor; it has not been applied to the normal device configuration.

| Primary SRAM | All-SRAM combined diagnostic | Combined Flash fixture |
| --- | ---: | ---: |
| Static span before heap, including 8 KiB worker stack | 129,920 B | 85,888 B |
| Linker heap span | 33,920 B | **77,952 B** |
| Headroom over the 49,152 B linker floor | Below by 15,232 B | Above by 28,800 B |

The all-SRAM figure comes from an **ELF-only link with the heap assertion relaxed**; its normal gated build failed. The Flash result uses an image that passed the study's modified structural audit and retained the normal 48 KiB floor. The 44,032 B reduction is a comparison of these particular headless fixtures; it includes fixed test vectors and wrappers and is not the cost or savings of a production service. Neither heap span is measured runtime free SRAM or a normal-device UI budget. The Flash executable and read-only sections are 32,196 B and 11,872 B, respectively; these also include fixture code and data.

## Exact-image emulator results

On 4 MiB emulated PSRAM, the **same audited image** ran ML-DSA-65 verification followed by ML-KEM-768 key generation, encapsulation and decapsulation. Both jobs used the same fixed SRAM stack in different task generations; each exited, had its resource ledger cleaned and was reaped before the next job. The old task handle was rejected during replacement.

- ML-DSA accepted the valid signature, rejected a changed message and completed its partial-OOM check. Its arena payload was 16,304 B with a 16,384 B buddy charge; observed stack watermark was 2,896 B.
- ML-KEM matched the pinned upstream fixed vectors, observed the altered-ciphertext alternate-secret behavior and completed a partial-OOM check. Its 32,688 B arena and 6,144 B test-I/O buffer were charged 32,768 B and 8,192 B; the largest observed phase stack watermark was 4,912 B.
- The jobs are sequential: the measured maximum of their separate PSRAM charges is 40,960 B, not a measurement of concurrent algorithms or of a service with caller-owned input snapshots. The separate 8,192 B SRAM stack remains reserved after both jobs.
- In each crypto operation interval, the timer and synthetic bootstrap work progressed; this is not input-to-display latency. CPU-visible zeroing and successful release do not establish physical PSRAM erasure.

With PSRAM absent, the same image reported both jobs unavailable and retired both tasks; no crypto operation ran. These are targeted fixture completions, not the 300-round scheduler smoke, normal UI or physical Tab5 evidence.

## What the audit proves

The study-specific auditor checks the 48 KiB floor, section/segment bounds and permissions, 41 fixture-specific function extents, loader/profile requirements and exact Flash image bytes against ELF contents. Its function inventory was obtained for this pinned test image and is **not an independently reviewed production allowlist or complete call graph**. It was deliberately adapted for this headless profile, including permitted read-only alignment padding. Four negative controls rejected an unknown function, missing profile marker, executable read-only section and modified Flash image byte. Five modified combined logs were also rejected. The [combined checker](../../probes/pqc/check_combined_xip_log.py) binds both job reports to the same exact ELF/image audit, validates the individual operation/resource records, generation transition and completion order; [the link inspector](../../probes/pqc/inspect_combined_xip.py) separately checks Flash sections and function extents.

The audited executed image's ELF SHA-256 is `c002f71a5e67ad83f7145a7828a348214ee3df39ee3e97deab7028992abfb5e7` and image SHA-256 is `df42ac3d37476484549812487b358f45d035fe13b0be8ccf656d9d0e070255bd`. The earlier ELF-only placement comparison is a separate artifact, SHA-256 `b23000d7610b553d8402476685e21ca027c2fe9ca448e4797562d5f8c3ae37cb`; its linked resource spans match the audited image. Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0 and the source revisions in the witness were used. [Evidence](evidence/2026-10-29-pqc-combined-xip/) retains the patch, audit, options, reports, raw and normalized logs, image-audit negative controls and source/artifact hashes. Exact binaries are under `build/pqc-combined-xip-qualified`, and the isolated study worktree path is in `build/pqc-combined-xip-dir.txt`.

The compressed patch can be piped from `gzip -dc` into `git apply` in an isolated checkout of base commit `e1231c4`, with the two pinned external checkouts and Zig/IDF toolchains, before invoking the existing combined-worker emulator build with `NIHOS_NATIVE_PQC_XIP=1`. Do not apply it to the production profile without a separately reviewed integration.

## Remaining boundary

The result makes Flash placement a concrete viable **emulator fixture**, not a claim that normal Tab5 firmware supports both algorithms. There is no implemented cross-core admission/quiescence protocol for Flash erase/write or cache-off, and this test did not disable the cache or exercise storage updates. Real UI/network/device SRAM budgets, simultaneous jobs, runtime trust policy, authenticated KEM integration, entropy and secret-key lifetime, long-run/cancellation/failure coverage, physical-device execution and power behavior remain unverified. A production path must first establish these boundaries and independently audit the Flash call graph and image profile.

# ML-KEM-768 on an independent native worker

This opt-in **headless emulator fixture** runs fixed public ML-KEM-768 test vectors on a distinct CPU0 scheduler task, using the pinned portable `mlkem-native` custom allocator. It is not a production KEM service, a normal UI build or a physical Tab5 result. [The preceding host and RV32 link study](2026-10-29-mlkem-custom-arena.md) describes the allocator and its experimental upstream status.

The worker generates a key pair from fixed test seeds, encapsulates using fixed test randomness, and compares the generated public key, secret key, ciphertext and shared secret with the pinned upstream test vectors. It checks valid decapsulation and that an altered ciphertext returns a different shared secret, and injects a failure at the fourth allocation of a separate decapsulation. The worker then CPU-zeroes and releases both owned buffers, exits, has its ledger cleaned, and is reaped. The test keys, randomness and shared secrets are public fixtures; none is suitable for real use. The upstream vector header is compiled from the pinned external checkout and not copied into the repository.

## Resource observations

| Resource | Payload / observed use | Reservation or charge |
| --- | ---: | ---: |
| Native worker stack | 4,720 B observed watermark | 8,192 B primary SRAM BSS, remains reserved |
| PSRAM custom arena | 32,688 B payload; highest operation cursor 19,232 B | 32,768 B buddy charge |
| PSRAM key, ciphertext and test-I/O buffer | 6,144 B payload | 8,192 B buddy charge |
| Simultaneous PSRAM allocations | 38,832 B payload | **40,960 B** |

The monotonic arena's per-operation rounded cursor peaks were **10,112 B key generation**, **15,904 B encapsulation**, and **19,232 B decapsulation**. The arena does not reclaim its cursor on each internal free; these are cumulative per-operation cursor observations, not maximum live bytes. Across the fixture, 62 successful internal allocations and frees balanced, the injected OOM returned the expected error, and the free hook observed zeroed regions. These observations do not establish physical PSRAM erasure, all-input maxima, memory isolation or side-channel safety.

The 4,720 B observed watermark exceeds the existing 4 KiB worker-stack reservation; the separate 8 KiB experimental stack was required for this run. The watermark covers this fixture and schedule, not a worst-case stack bound. During the four ordinary KEM operations (keygen, encapsulation, valid and altered-ciphertext decapsulation), CPU0's timer advanced 10 ticks and the CPU0 and CPU1 synthetic bootstrap counters advanced 42,685 and 9,486 respectively; six worker trap frames were captured. This demonstrates scheduled progress for this run, not touch-to-display latency. CPU-visible MIE was enabled after the fixture.

The CPU0 owner's PSRAM free count was 1,801,536 B before allocation, 1,768,768 B after the arena, 1,760,576 B with both allocations, and 1,801,536 B after release. These counts describe the emulator fixture and owner partition, not total normal-device application capacity. With PSRAM absent, no crypto operation was performed; the worker still exited and was reaped. The second-allocation failure and its cleanup are implemented but not fault-injected in this run.

## Image and reproducibility

The exact candidate passed the standard native image audit: **107,712 B primary static SRAM** and **56,128 B primary heap span**, above the 48 KiB linker floor. These figures include the fixed stack and fixture data, and are not measured normal-device free memory. ELF SHA-256 `f53642e09a481bf02afe3ea064ee7a5bd6140e22e92f0b20ac4401ca385b85c1`; image SHA-256 `c7d74c311701234dab79b52706726294350ffb167c35782dbab27de0fe150d3f`. Zig 0.17.0, the ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0, and the exact upstream revisions in the source witness were used. The build currently also requires the pinned ML-DSA checkout to enter the existing worker fixture configuration; the audited ELF symbol table has no defined ML-DSA function symbols. This is not a combined KEM + DSA image budget.

The [checker](../../probes/pqc/check_mlkem_worker_log.py) binds each log to the audited ELF/image and the 8 KiB SRAM stack symbol; validates fixed-vector outcomes, injection, progress, charges, clearing and owner retirement; and requires the no-PSRAM outcome. Six altered logs were rejected. [Evidence](evidence/2026-10-29-mlkem-worker/) contains both logs, reports, options, audit and source hashes; exact binaries remain under `build/mlkem-worker-qualified` in the study worktree.

No normal UI, network protocol, real entropy, production secret, key persistence, authenticated key exchange, asynchronous cancellation, Flash/cache-off coordination, physical hardware, power cycle or FIPS validation was tested. Altered-ciphertext decapsulation can return success with a different shared secret; callers need protocol-level authentication and key confirmation. The custom allocator and test code are experimental.

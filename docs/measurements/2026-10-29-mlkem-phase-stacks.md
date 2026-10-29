# ML-KEM-768 per-operation worker stack observations

This extends [the headless ML-KEM worker fixture](2026-10-29-mlkem-native-worker.md) with a separate stack-canary interval immediately around each KEM call. The worker uses fixed upstream public test vectors, a static 8,192 B CPU0 SRAM stack, a 32,688 B PSRAM arena payload and a separate 6,144 B test-I/O payload. It is not a production service or physical Tab5 measurement.

Before each operation the fixture paints only unused worker-stack space below its current live stack pointer; after the call it scans for the lowest changed canary. Each value is measured from the top of the reserved stack, and therefore includes the active worker, Zig/C wrapper frames, measurement overhead and any interrupt context captured on that stack, not just the called KEM function. The interrupt handler uses its own IRQ stack. Repainting between operations is necessary to isolate phases; it erases earlier canaries. The aggregate reported `stack_used` is the maximum of the five phase samples and the final post-fixture scan, **not** an independently measured whole-run maximum. These are watermarks for one input and schedule, not worst-case bounds.

| KEM call | SRAM stack watermark | Arena rounded cursor peak |
| --- | ---: | ---: |
| Deterministic key generation | 4,784 B | 10,112 B |
| Deterministic encapsulation | 4,624 B | 15,904 B |
| Valid decapsulation | **4,816 B** | 19,232 B |
| Modified-ciphertext decapsulation | 4,688 B | Not separately reported |
| Decapsulation with fourth allocation failed | 1,208 B | Not separately reported |

Each ordinary call's observed watermark exceeds the existing 4 KiB worker stack reservation in this instrumented run. The dedicated 8 KiB stack remained inside its guard and its reservation remains after task reap. These results do not establish the required size for every input, compiler or scheduling condition, or prove that a different task stack can safely be used.

The 4 MiB emulated PSRAM run also passed the pinned key/ciphertext/shared-secret vector checks, modified-ciphertext check and one partial OOM check, and reported 62 successful allocations and frees, zero live allocations and zero uncleared freed regions. The arena and I/O allocations were charged 32 KiB and 8 KiB respectively; the owner heap's free count returned to 1,801,536 B after release. The worker was cleaned and reaped. Across the four ordinary operations, CPU0's timer advanced 10 ticks and the CPU0/CPU1 synthetic bootstrap loops progressed; six worker trap frames were captured. This is not real UI latency or physical PSRAM erasure evidence.

With PSRAM absent, no crypto call or stack-phase measurement ran, and the worker exited and was reaped. The injected OOM run is one particular internal allocation failure, not all target failure positions.

## Exact candidate and limits

The standard native image audit passed: primary static SRAM **108,288 B**; primary heap span **55,552 B**, above the 48 KiB linker floor. These are fixture-image values, not a normal-device free-memory measurement. ELF SHA-256 `1a0b0125828096c8f0333c1fcfeaa713dec5e0a4b2bd9de165fd8558a27777f2`, image SHA-256 `aaaa26ebe87b39f643d1591a3ba8ce6e6c248b968e1e94d2aab738bd877b92c1`. Zig 0.17.0, ESP-IDF 5.4.4 loader, ESP-EMU 0.50.0, and the pinned upstream revisions in the witness were used.

The [phase checker](../../probes/pqc/check_mlkem_phases_log.py) applies the original audited-image, KAT, resource, cleanup and progress checks and verifies each phase sample fits within the registered stack. Six modified traces were rejected. [Evidence](evidence/2026-10-29-mlkem-phases/) contains normalized/raw logs, image audit, options, reports and source hashes; exact ELF and images remain under `build/mlkem-phases-qualified` in the study worktree. The standard checker remains usable for the preceding single-watermark evidence.

No physical Tab5, full-size unknown inputs, production entropy or secrets, normal UI, authenticated protocol, cache-off coordination, cancellation, repeated-job soak, target-wide allocation-failure coverage, physical secret erasure, side-channel safety or FIPS validation was tested.

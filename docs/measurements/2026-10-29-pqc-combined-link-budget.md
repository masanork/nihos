# ML-DSA and ML-KEM in one headless native link

The previous ML-DSA-65 verification and ML-KEM-768 worker images were separate; their individual free-space figures could not establish the cost of placing both algorithms in one firmware. This opt-in study builds one headless emulator worker fixture with both C implementations reachable. The intended fixture has a sequential ML-DSA verification job and ML-KEM job reusing the same 8 KiB static worker stack; this intended two-job path was **not executed** because the normal SRAM gate failed.

The normal combined build stopped at `native SRAM heap below 48 KiB`. To quantify it, a separate diagnostic worktree changed only the linker assertion from 49,152 B to zero and performed an **ELF-only link**. No diagnostic firmware image was generated or run. This alteration is recorded as [a patch](evidence/2026-10-29-pqc-combined-link/diagnostic-linker.patch); the normal source retains its 48 KiB assertion. The linked diagnostic is not a qualified build and must not be treated as proof of runtime behavior.

A same-source ML-KEM-only baseline was linked with the normal gate. Apart from the `pqc_combined_probe` boolean and the diagnostic-only assertion, generated options match. Both links use the same headless profile, 8 KiB worker reservation, optimization, test fixtures and pinned external sources.

| Primary SRAM quantity | ML-KEM baseline | Combined diagnostic | Difference |
| --- | ---: | ---: | ---: |
| Static span before the heap, including 8 KiB worker reservation | 108,288 B | 129,920 B | +21,632 B |
| Linker heap span | 55,552 B | 33,920 B | −21,632 B |
| Shortfall against the 49,152 B floor | none | **15,232 B** | — |

These are linked address spans, not measured runtime free memory or a production-service budget. The difference includes the fixed public test vectors, adapters and fixture logic as well as reachable algorithm code/tables. It is not a general incremental ML-DSA implementation cost, and no normal UI, Wi-Fi, service request buffers, runtime allocator fragmentation or physical-device workload is included. The ELF inspection found defined ML-KEM roots in both links and ML-DSA verification roots only in the combined link; the options comparison confirms that only the combined switch differs.

The figures make an all-SRAM placement of this exact dual fixture incompatible with the existing heap floor. They do not establish that supporting both algorithms is impossible: a separately designed and audited Flash/XIP placement, smaller fixture data, operation selection or other code-placement changes could alter the result. In particular, the existing [single-algorithm XIP study](2026-10-29-pqc-xip-audit.md) does not validate combined placement, cache-off coordination or a real UI worker. Do not lower the production heap floor as a workaround.

## Evidence and validation

The [inspection script](../../probes/pqc/inspect_combined_link.py) reads the exact ELF hashes, stack symbol/BSS bounds, heap endpoints, algorithm symbols and generated options, and requires the normal gate failure. Three negative controls changed the failure log, substituted the baseline ELF, or reused the wrong options; each was rejected. [Evidence](evidence/2026-10-29-pqc-combined-link/) retains the report, options, failed-build log, linker patch and source hashes. The exact baseline ELF remains in `build/pqc-combined-baseline`; the diagnostic worktree path is stored in `build/pqc-combined-diagnostic-dir.txt`.

Baseline ELF SHA-256 `5035a75e523c286b8fd21ba0697a3035291a6144a530f2a30a88977f947adc0d`; diagnostic ELF SHA-256 `40019c4861783238aea2272287637f487a4ee9ce4f1b575ad5eeaaac89f07033`. Both used Zig 0.17.0 and the source revisions in the witness. The normal-gated combined attempt used the ESP-IDF 5.4.4 loader, but failed before an application image could be built. A separate current-source ML-KEM-only image passed the native structural audit and its 4 MiB emulator phase checks; its image is a different artifact from the link comparison. No combined execution, SRAM runtime free sample, normal-device build, cache-off test, physical Tab5 test or production security validation is claimed.

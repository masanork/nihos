# Native SRAM ownership qualification

- Date: 2026-10-26
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU 0.50.0
- [Source file hashes, image digests and complete mode reports](2026-10-26-native-sram-ownership.json)
- [ADR 0023](../adr/0023-owner-local-native-sram.md)
- Reproduce with `sh tools/run-native-smoke.sh` and its `floating` / `compiled` modes.

## Result

All three modes booted with PSRAM absent, completed 300 scheduler rounds and
64 ordered IPI/idle exchanges per direction, and passed both owners' final
SRAM checks. Each owner allocated 64 bootstrap bytes and two independent
192-byte worker buffers. Their patterns, alignment and both 64-byte boundary
guards remained valid after workers exited and were reaped. All allocations
came from the current hart's partition of the linker-provided SRAM tail.

The fixture explicitly checked that allocation preserves disabled
interrupts before task startup and enabled interrupts in the workers.
Zero-length, invalid-alignment and oversized requests consumed no capacity.
The API uses local interrupt masking around the cursor update and no
cross-core allocator lock. Host tests separately checked rejection of
foreign owners, exact exhaustion, padding and guard corruption.

| Observation, either revision profile | Integer | Raw floating | Compiled FP |
| --- | ---: | ---: | ---: |
| Static reservation, including stacks and alignment | 91,776 B | 94,976 B | 95,104 B |
| Runtime heap span, guards included | 39,296 B | 36,096 B | 35,968 B |
| Allocatable capacity per owner | 19,520 B | 17,920 B | 17,856 B |
| Consumed per owner | 448 B | 448 B | 448 B |
| Remaining per owner | 19,072 B | 17,472 B | 17,408 B |
| App image | 65,616 B | 65,616 B | 65,616 B |

The compiled fixture retained 502 / 510 timer captures inside generated FP
task code on CPU0 / CPU1, with matching FP save/restore accounting and final
FS=Off. Integer tasks retained zero FP copies. Each compiled worker sampled
its allocated buffer more than 738,000 times; these counts establish
continued execution, not a hardware throughput benchmark.

## Verification boundary

All 59 host tests passed in Debug and ReleaseSafe. All 28 Python native
validator tests passed. ZLint and ShellCheck passed; architecture checks
linked and instruction-audited six native ELF variants. All six complete
Flash images were built and audited. The new heap audit requires writable
NOBITS storage, matching linker symbols, no overlap with static sections and
at least 16 KiB in the selected internal window.

The JSON binds these local results to changed source-file SHA256 values
and the preceding base commit. Image and log hashes identify the measured
artifacts. Remote CI is separate evidence. The preceding main commit
`5806eaee53e4758325e1506dbe7596b9493dd202` passed both ordinary CI and
[Native boot](https://github.com/masanork/nihos/actions/runs/40205704898);
that result does not qualify this change.

No physical device was accessed. No PSRAM was initialized, registered or
tested. These monotonic arenas do not provide reusable `malloc`/`free`,
task isolation, cache/DMA ownership qualification, real-time latency
measurements or Quake performance evidence. Native PSRAM controller timing,
capacity discovery and MMU/cache setup remain the next bring-up stage.

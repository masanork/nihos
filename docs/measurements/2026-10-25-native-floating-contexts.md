# Opt-in native floating-point owners on both ESP32-P4 harts

- Date: 2026-10-25
- Firmware implementation: `3a136330b42e4c1600988a20a808d487a50a46b5`
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU v0.50.0
- [Machine-readable modes, digests and negative checks](2026-10-25-native-floating-contexts.json)
- [ADR 0021](../adr/0021-native-opt-in-floating-contexts.md)
- Reproduce with `sh tools/run-native-smoke.sh` and `sh tools/run-native-smoke.sh floating`

## Result

Both integer and floating modes booted from the revision-3 emulated ROM with
no PSRAM. Each completed the 300-round preemption/lifecycle fixture and 64
ordered IPI/idle exchanges per direction, then reached its requested
`NIHOS_NATIVE_FP_PASS` marker. Both modes retained native stack, frame, MIE,
elapsed-time and no-periodic-wake-fallback checks.

Floating mode opted in two busy tasks and the lifecycle/protocol stack on
each hart. Their assembly wrappers checked all f0..f31 and fcsr across native
timer preemption, sleep/yield/exit and event waits. A self-IPI on each running
protocol task tested FP capture during execution. Integer bootstraps did not
own a floating bank, including during WFI.

| Floating-mode final observation | CPU0 | CPU1 |
| --- | ---: | ---: |
| FP timer captures | 600 | 600 |
| FP ECALL captures | 79 | 79 |
| FP IPI captures | 2 | 1 |
| FP trap saves / restores | 681 / 681 | 680 / 680 |
| New physical banks checked zero | 5 | 5 |
| Busy task A bank checks | 2,287,590 | 2,287,581 |
| Busy task B bank checks | 2,287,468 | 2,287,308 |
| Lifecycle/protocol bank checks | 138 | 138 |

For each owner, trap saves equalled restores and the sum of FP timer, ECALL
and IPI captures. Empty completion IPIs can interrupt a still-running FP
task, so the IPI counts need not match between harts. The five activations
per hart included two lifecycle generations and the later protocol task;
each observed 32 zero registers and fcsr=0 before seeding its signature.
These diagnostic activation snapshots are not included in trap-copy counts.

Signatures differed by hart, stack index, slot and generation, with RNE/RTZ
and the inexact flag checked. The owner verified the final saved bank before
reaping and reuse. Each bootstrap confirmed FS=Off and null current/selected
FP pointers after all opted-in tasks retired, then published final counters.
No peer read live non-atomic probe data or an unfinished FP epilogue.

The integer run reported zero FP checks, initial snapshots, timer/call/IPI
captures and saves/restores on both harts. It did not link the F helper
object. This verifies zero FP bank-copy overhead for integer tasks; it does
not assert zero bookkeeping overhead or a measured application speedup.

## Resources and validation

| Resource, each revision profile | Integer | Floating |
| --- | ---: | ---: |
| Native text | 27,502 bytes | 29,692 bytes |
| SRAM reservation, all fixed stacks included | 87,296 bytes | 90,496 bytes |
| App image | 65,616 bytes | 65,616 bytes |
| Explicit per-task FP bank storage | 0 bytes | 792 bytes |

Floating mode reserves 88.375 KiB, leaving 39.625 KiB in the chosen 128 KiB
SRAM region. Its total increase over this integer fixture is 3,200 bytes,
including code, banks, probes and lifecycle state. No task stack or heap was
added. Stock-loader Flash alignment still dominates the application binary.

All 53 host tests passed in Debug and ReleaseSafe, including saved-bank
corruption checks. Eighteen log-validator tests passed. ZLint reported zero
errors/warnings over 35 files; ShellCheck and the hosted RV32 contract plus
four native ELF links passed. All four device/emulator, integer/floating
images passed structural/mode/ABI audits. Deliberate wrong-ABI, missing
restore-symbol and wrong-mode cases were rejected.

The shared F assembly was split into per-function sections without changing
its instructions. The hosted ESP-IDF emulator regression also reached
`nihos: core smoke complete`, including its existing FP scenarios. The
native link discarded the hosted watchdog probe and its platform dependency.

The initial F assembly object used a different FP ABI from the integer Zig
kernel and was rejected by the linker; explicit ILP32 resolved it. During
local bring-up, parallel device-mode builds raced on their common stock
loader directory; final builds were run sequentially. Neither failed attempt
was treated as qualified evidence.

## Remaining qualification

No physical device was accessed; rev1 qualification remains deferred. These
are raw-bank task probes with integer-only callbacks. Compiler-generated FP
tasks and floating-point C call ABIs are not yet qualified. There is no
claim of same-cycle overlap, Quake FPS, power savings, migration, nested
traps, lazy/dirty-only transfer, PSRAM/display or protection domains. Remote
CI and emulator workflow results remain separate from the local observations.

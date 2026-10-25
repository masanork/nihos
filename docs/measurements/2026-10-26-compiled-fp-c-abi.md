# Compiler-generated Zig/C FP tasks and ILP32F boundary

- Date: 2026-10-26
- Firmware implementation: `bd48e0f56cd2415472510aa56f02a50564757200`
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU v0.50.0
- [Mode results, instruction counts and artifact digests](2026-10-26-compiled-fp-c-abi.json)
- [ADR 0022](../adr/0022-compiled-fp-and-c-boundary.md)
- Reproduce with `sh tools/run-native-smoke.sh compiled`

## Result

Integer, raw floating and compiled floating modes each booted from the
revision-3 emulated ROM with PSRAM absent and completed their 300-round
task/lifecycle fixture and 64 IPI/idle exchanges per direction. The compiled
mode additionally exercised actual Zig-generated FP tasks and ILP32F C
functions under the permanent native scheduler.

Each checkpoint compared three float arguments and a float result from
Zig-to-C, Zig-local, and C-to-Zig callback calculations against independent
integer-derived IEEE bits. A pointer adapter checked both members of a
two-float structure. Task-specific RNE/RTZ modes produced distinct halfway
addition results and the expected NX flag. Lifecycle/protocol tasks held
compiler-managed FP values across sleep, yield and event-wait calls; emitted
task code used callee-saved FP registers.

| Compiled-mode final observation | CPU0 | CPU1 |
| --- | ---: | ---: |
| Timer captures with PC in generated task region | 600 | 600 |
| FP timer / ECALL / IPI captures | 600 / 79 / 2 | 600 / 79 / 1 |
| FP trap saves / restores | 681 / 681 | 680 / 680 |
| Busy task A calculation checkpoints | 892,251 | 892,247 |
| Busy task B calculation checkpoints | 892,193 | 892,132 |
| Lifecycle/protocol checkpoints | 137 | 137 |
| Initial physical banks checked zero | 5 | 5 |

Copy counts matched the sum of opted-in trap captures, and both integer
bootstraps confirmed final FS=Off and retired FP ownership. The earlier
integer and raw signature modes passed independently; the integer mode
retained zero FP bank copies. Periodic alarm counts remained unchanged in
the IPI interval, including the forced pending-before-WFI and running-task
self-IPI cases.

## ABI finding

The initial direct by-value C pair call failed with x bits `0x3e800000`
(0.25) instead of `0x3f000000` (0.5). Layout assertions agreed on size 8,
alignment 4 and y offset 4. This exploratory precursor was not counted as
a passing run. The final fixture uses `nih_fp_c_pair_into`, keeping the
by-value call entirely inside C and crossing the Zig boundary with pointers
plus a scalar delta. That path passed the checks above. Direct aggregate
ABI support remains unqualified with this pinned toolchain.

## Instruction and resource evidence

The ELF audit found 120 FP instructions in `.fp_app`: 14 in C functions and
106 in generated Zig code. It found 66 in the approved raw transfer helpers
and rejected any such instruction elsewhere. This includes FP CSR accesses
and compressed RV32 FP loads/stores. A deliberate FP instruction in kernel
text, wrong ILP32 flags, and a renamed/unapproved app section were rejected.
Kernel dispatch also continued to check FS=Off and MIE=0 at runtime.

| Resource, either revision profile | Integer | Raw floating | Compiled |
| --- | ---: | ---: | ---: |
| Kernel/helper text | 28,176 B | 30,366 B | 28,736 B |
| Compiled FP task region | 0 B | 0 B | 1,936 B |
| SRAM reservation, fixed stacks included | 88,064 B | 91,264 B | 91,648 B |
| App image | 65,616 B | 65,616 B | 65,616 B |

Compiled mode reserves 89.5 KiB, leaving 38.5 KiB in the chosen 128 KiB
region. No stack or heap was added. These are fixture sizes rather than a
language-performance comparison or production stack sizing.

## Validation and remaining gates

All 54 host tests passed in Debug/ReleaseSafe. Twenty log-validator and
three instruction-classifier tests passed. ZLint reported zero errors and
warnings over 37 files; ShellCheck passed. Normal architecture checks built
and instruction/ABI-audited all six profile/mode ELFs without IDF; all six
full Flash images were also audited. The compiled mode uses ILP32F and the
two previous modes retain ILP32. Remote CI is separate evidence.

No physical device was accessed. Qualification is limited to the tested f32
scalar, callback and pointer-aggregate interfaces; it does not cover direct
aggregate values, varargs, f64, every numerical case or general libc. It
does not claim power savings, Quake FPS, migration, nested traps, PSRAM,
display or protection domains.

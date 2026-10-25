# ADR 0021: Opt-in eager FP ownership in the permanent native backend

- Status: accepted; emulator qualified, physical qualification deferred
- Date: 2026-10-25

## Decision

Attach the existing 132-byte `FloatingContext`, raw transfer routines and
full-bank task probes to permanent native traps. Keep an integer build as a
separate regression mode. An opted-in task gets a preallocated bank holding
f0 through f31 and fcsr. Bootstrap/idle contexts remain integer with FS=Off.
No task migration, lazy ownership or dirty-only transfer is introduced.

Assembly captures the integer frame and incoming status, switches to the
owner's IRQ stack, and saves the current opted-in physical bank before any
Zig dispatch. It then clears FS. The dispatcher and policy remain compiled
without the F feature and check live MIE=0 and FS=Off. After selecting a
frame, assembly restores its opted-in bank, updates the hart's current bank
pointer, and restores the selected status with the active CLIC cause. FP
tasks return with FS=Clean; integer contexts return with FS=Off. Even a trap
that selects the same FP task performs an eager save/restore.

The app's scalar ABI is ILP32. The FP assembly is compiled with F instructions
and explicitly `-mabi=ilp32`; kernel Zig modules exclude F. The linker rejects
incompatible FP ABI objects. This fixture passes scalar/pointer arguments
between integer Zig and assembly; it does not qualify a compiler-generated
floating-point function ABI or an arbitrary prebuilt IDF library. Future C
game ports must be compiled for a compatible ABI or use an explicit adapter.

## Bank lifecycle and diagnostic checks

Each hart reuses the existing three task stacks and has three possible FP
banks. Allocation zeroes the complete bank before first selection. Every new
FP task snapshots its initial physical bank and requires all 32 registers
and fcsr to be zero before seeding a signature. The five activations per hart
are two busy workers, two lifecycle generations and one IPI protocol task.
The diagnostic activation snapshots are separate from trap-copy accounting.

The existing assembly wrapper owns the entire physical bank, seeds distinct
raw words, performs an inexact f31 addition and invokes an explicitly
integer-only callback. Patterns incorporate hart, stack index, policy slot
and generation. RNE/RTZ and NX signatures differ between tasks. Busy workers
check the complete bank without yielding; lifecycle callbacks check around
sleep/yield; protocol callbacks check around each event wait. The wrapper
checks again before task exit.

Before reaping, the owner also checks the final saved bank against the
expected register/fcsr signature. This catches an incorrect final store even
when the task will not resume. A host test rejects register, sum and flag
corruption. Only a retired bank can be initialized for a replacement; the
generation and saved-frame lifecycle remain owned by the same hart.

Live probe counters are read only by their owner while task execution is
stopped. Only 32-bit release/acquire publications cross hart boundaries. After
both protocol tasks finish, each integer bootstrap verifies its own FS=Off,
null current/selected bank pointers, retired banks and balanced trap copies,
then publishes quiescence. CPU0 waits for CPU1's publication before reporting.
It does not read a peer's mutable probe or half-finished trap epilogue.

## Trap coverage and the integer regression

The first stage keeps two non-yielding FP workers per hart under native
timer preemption, while the lifecycle task sleeps, exits and is replaced.
The existing 64-message IPI/WFI stage follows with periodic alarms disarmed.
Each running protocol task now asserts one empty self-IPI before the message
loop, proving an IPI can capture an executing task as well as an idle
bootstrap. FP state must survive that interrupt and subsequent ECALL waits.
Empty completion IPIs may provide additional running-task captures.

At quiescence on each hart:

```text
FP trap saves = FP trap restores
              = FP timer captures + FP ECALL captures + FP IPI captures
```

Floating mode requires positive checks for all three stack indices, at least
eight FP timer captures, twelve FP ECALLs, one FP IPI capture and five zeroed
initial banks per hart. Integer mode requires every FP check/copy/capture
counter to remain zero. Its assembly excludes the FP transfer paths and does
not link the F helper object. This is zero FP bank-copy overhead, not a claim
of identical instruction count or memory footprint to an earlier fixture.

## Builds and evidence

Both device and emulator profiles support `integer` and `floating` modes.
Native CI runs both smokes and builds both physical images. Normal
architecture CI links all four ELFs without IDF. Shared F helpers now have
individual input sections so the native link can discard the hosted watchdog
probe; the hosted image still exercises those probes as a regression.

Image auditing checks ILP32 flags, the complete requested F helper set, and
absence of the hosted preemption watchdog. The log validator binds the mode
to the requested build and rejects missing FP evidence, unbalanced copies,
integer-mode copies and incomplete activation/trap coverage. The final
marker is `NIHOS_NATIVE_FP_PASS`; the earlier IPI marker is no longer enough.

Physical rev1 behavior, compiler-generated FP tasks, migration, nested
traps, lazy/dirty-only schemes, protection domains, PSRAM and display remain
separate qualification work. This step establishes native register ownership
and raw context correctness; it does not measure Quake performance.

## References

- [ADR 0008: Eager RV32F context](0008-opt-in-eager-rv32f-context.md)
- [ADR 0017: Hosted simultaneous FP owners](0017-simultaneous-floating-owners.md)
- [ADR 0020: Native IPI/WFI](0020-native-ipi-and-interrupt-wait.md)
- [Shared frame and FP layouts](../../src/arch/riscv32/context.zig)
- [Native FP lifecycle](../../src/arch/riscv32/native_floating.zig)
- [Raw transfers and full-bank probes](../../src/arch/riscv32/fpu.S)

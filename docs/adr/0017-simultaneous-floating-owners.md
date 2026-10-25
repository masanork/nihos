# ADR 0017: Qualify simultaneous floating-point task ownership on both harts

- Status: accepted
- Date: 2026-10-25

## Decision

Add a distinct `smp_floating` fixture for testing opted-in FP task contexts on
CPU0 and CPU1 at the same time. Preserve the existing CPU1-only `floating_tasks`
mode and integer modes as independent regression cases. Each task owns a
preallocated 132-byte bank for `f0` through `f31` and `fcsr`; the bootstrap on
each hart also preserves its physical bank for that hart's bounded native
window.

Four distinct task signatures make cross-task or cross-core bank mixups
visible:

| Hart and task | Register pattern | Expected `fcsr` |
| --- | --- | ---: |
| CPU0 client | `0x3fc00000` | 33 |
| CPU0 observer | `0x3fc01000` | 1 |
| CPU1 service | `0x3fa00000` | 1 |
| CPU1 observer | `0x3fa01000` | 33 |

Each assembly-owned task wrapper seeds all registers, computes the expected
inexact `f31` result, and invokes an explicitly integer-only Zig entry. The
entry checks its bank through the read-only checker around ECALLs and during
the observer's busy phase. The wrapper verifies the bank after the entry and
exits through the normal task-exit ECALL. The Zig callbacks do not use
compiler-generated floating-point operations; the assembly probe owns the
bank contents.

## Cross-hart overlap handshake

CPU1's observer publishes that it has entered its checked FP loop and stays
there behind a hold gate, including after CPU1's timer-woken service is ready
to continue. CPU0's observer marks the overlap active and waits for CPU1 to
acknowledge the hold. It then snapshots its own tick, timer-capture, and FP
check baselines. While the hold remains closed, CPU0 also runs a no-ECALL FP
check loop. The first client remains blocked awaiting its service response,
so the observer can run while CPU1's observer remains held in its own loop.

CPU0 publishes its owner tick through a 32-bit atomic on every successful
clock refresh, including refreshes from timer, IPI, and task-call paths. Each
hart publishes observer timer captures from its serialized timer tail; CPU1
also publishes successful observer FP checks. Cross-hart readers sample only
these atomic counters, not another hart's scheduler policy or mutable task
image.

After the CPU0 observer sees at least eight additional CPU0 owner ticks and
eight CPU0 timer captures of itself, it requires positive CPU1 observer FP
check and timer-capture deltas from the post-ack baselines. It performs a final
FP check, records the interval counters, then releases the CPU1 hold. The
normal 64-message duplex protocol, task exits, join, and reaping follow. The
report retains both interval deltas and full-run per-task FP check counts.

Timeout and task-failure paths release the hold before exiting. The CPU1
stop-and-join path also releases it before sending the stop IPI, so failure
cleanup does not depend on either owner's timer making progress.

## Per-hart ESP-IDF boundary and accounting

With MIE clear, each hart snapshots its incoming 132-byte physical FP bank and
FS bits before entering the native window. The bootstrap is made the current
FP owner before the first native trap, even when IDF entered with FS=Off, so
the trap assembly saves the raw bank before dispatcher or guard code. At
window finish, after tasks have exited and the bootstrap bank is selected,
each hart snapshots again and compares all 132 bytes and the original FS
bits. This preserves the physical IDF lazy-owner state without editing its
TCB.

For each hart, save and restore counts must match the total handled native
traps: task-call ECALLs, timer interrupts, and IPIs. CPU0 and CPU1 maintain
separate counters and ownership pointers. The integer CPU0/CPU1 modes continue
to require zero FP copies; the existing CPU1-only FP mode remains intact.

## Boundaries

This fixture tests overlapping FP register ownership in bounded native task
windows. Its tick and capture counters define a scheduler-scale overlap
interval; it does not measure same-cycle execution or application throughput.
It does not add nested traps, task migration, lazy or dirty-only transfer,
cold-power behavior, or a compiler-generated floating-point task ABI. Emulator
and physical results belong in measurement records and are not asserted by
this design decision.

## Primary references

- [ADR 0005: RV32 context and trap contract](0005-riscv-context-and-trap-contract.md)
- [ADR 0008: Opt-in eager RV32F context](0008-opt-in-eager-rv32f-context.md)
- [ADR 0015: CPU1 timer and preemption](0015-cpu1-timer-and-preemption.md)
- [ADR 0016: CPU1 floating contexts](0016-cpu1-floating-contexts.md)
- [RISC-V F extension, register state and fcsr](https://docs.riscv.org/reference/isa/v20260120/unpriv/f-st-ext.html)
- [RISC-V machine ISA, FS context status](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- Pinned ESP-IDF v5.4.4 RISC-V port and saved-frame definitions, used as the
  P4 hardware oracle; nihOS's raw transfers and probe are independently
  written.

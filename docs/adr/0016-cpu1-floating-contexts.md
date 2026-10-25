# ADR 0016: Extend opt-in eager RV32F contexts to CPU1 tasks

- Status: accepted
- Date: 2026-10-25

## Decision

Extend ADR 0008's explicit, eager 132-byte floating-point context to the
owner-local CPU1 task runtime. Each opted-in task image points to its own
preallocated bank containing `f0` through `f31` and `fcsr`. The CPU1 bootstrap
also opts in for the duration of the bounded native window. Integer tasks keep
a null context pointer and FS off.

The native trap entry saves the outgoing bank before any C or Zig dispatcher
code, keeps FS off while the kernel handles the trap, and restores the selected
bank after dispatch. CPU1 timer, IPI, and task-call traps use this same eager
path. The selected task's saved `mstatus` controls its FP state; the active
trap's cause metadata continues to control CLIC return.

## ESP-IDF boundary

After installing the temporary native vector, before starting its timer or
entering any native task, CPU1 records the incoming FS bits and snapshots the
complete physical FP bank with MIE masked. The snapshot
temporarily enables FP register access and restores the original `mstatus`, so
it also works when the IDF bootstrap has FS=Off while its physical bank still
contains state owned by ESP-IDF's lazy FP mechanism.

During a floating window, the bootstrap context is the current FP owner before
the first trap. The first trap therefore saves the raw IDF bank before entering
any trap-dispatch or stack-guard helper. On the masked finish path, the implementation stops the
timer, verifies the bootstrap bank is selected again, snapshots the physical
bank, and compares all 132 bytes and the original FS bits. It then clears the
temporary CPU1 ownership pointers before returning to IDF. Integer mode
requires zero floating saves and restores and a null CPU1 owner pointer.

## Probe and trap-path evidence

Each CPU1 floating task enters a private non-returning assembly wrapper. It
seeds every register with a task-specific raw pattern, computes `f31` with an
inexact addition under the requested dynamic rounding mode, and calls the
task's explicitly integer-only Zig entry. The wrapper checks the whole bank
after that entry returns and exits through the normal task-exit ECALL with its
result, or `-193` on a bank mismatch. The leaf checker reads `f0` through
`f31` and `fcsr` without changing FP state or callee-saved integer registers;
each successful check increments that task's check count.

The existing timed duplex fixture provides the scheduling proof. The service
task sleeps for five CPU1 ticks while its peer spins without yielding, making
task calls, or querying time. The service resumes only after the CPU1 timer
advances its clock and marks the peer's probe complete. A deterministic
handshake holds the observer in its FP loop until an IPI has also captured it.
The duplex phase then exercises each task's FP bank around task-call ECALLs.
Reports distinguish FP task captures by timer, IPI, and task-call source, and
require checks and task calls for both tasks.

In this scenario CPU0 remains an integer-only client and observer. CPU0's
floating preemption test runs earlier in a separate native window. This
qualifies per-hart FP context support across separate windows; it does not test
simultaneous FP workloads on both harts.

ADR 0017 adds a separate overlapping-owner fixture for that next gate while
retaining this CPU1-only scenario unchanged in purpose. Its results are in
the [simultaneous FP record](../measurements/2026-10-25-tab5-simultaneous-floating.md).

The floating window also requires save and restore totals to match the number
of handled CPU1 traps:

`floating_saves == floating_restores == task_calls + timer_interrupts + ipi_interrupts`

This accounts for the bootstrap transitions as well as task-to-task switches.
The existing integer CPU1 scenarios remain regression cases and require zero
FP save/restore operations.

## Boundaries and status

This is an implementation and test-contract decision; emulator and physical
measurement results are recorded separately when available. It does not add
lazy allocation, dirty-only transfer, nested traps, task migration, general
cross-core FP ownership, or a compiled floating-point application ABI. The
probe exercises the hardware context boundary with assembly-managed FP state,
not compiler-generated FP code in Zig tasks.

## Primary references

- [ADR 0005: RV32 context and trap contract](0005-riscv-context-and-trap-contract.md)
- [ADR 0008: Opt-in eager RV32F context](0008-opt-in-eager-rv32f-context.md)
- [RISC-V F extension, register state and fcsr](https://docs.riscv.org/reference/isa/v20260120/unpriv/f-st-ext.html)
- [RISC-V machine ISA, FS context status](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- Pinned ESP-IDF v5.4.4 RISC-V port and saved-frame definitions, used as the
  P4 hardware oracle; nihOS's raw transfers and probe are independently
  written.

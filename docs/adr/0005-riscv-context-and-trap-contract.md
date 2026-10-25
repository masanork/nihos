# ADR 0005: Fix the RV32 context ABI before writing trap assembly

- Status: accepted
- Date: 2026-10-25

## Decision

Define and host-test the native ESP32-P4 saved-context layout before adding a
nihOS trap entry. The normal switch frame is 128 bytes: `mepc` followed by all
31 non-zero RV32 integer registers. The diagnostic exception frame extends it
with `mstatus`, `mtvec`, `mcause`, `mtval`, and `mhartid`, and reserves 160
bytes to retain 16-byte stack alignment.

Keep RV32F state in a separate 132-byte area containing f0 through f31 and
`fcsr`. Integer-only tasks need no floating-point allocation or save. A task
that first executes floating-point code will eventually acquire that area and
become FPU-affine until the native SMP ownership protocol is implemented.

Decode the ESP32-P4 CLIC `mcause` without destroying its metadata. The low 12
bits identify the cause, while the interrupt flag, MINHV, previous privilege,
and previous interrupt level remain available to entry and return code.

## Basis

The layout is derived from the pinned ESP-IDF v5.4.4 public interfaces and
implementation in `riscv/rvruntime-frames.h`, `riscv/vectors.S`, and the
FreeRTOS RISC-V port. Those Apache-2.0 files are reference material for the
hardware ABI; nihOS owns its independently written Zig types and tests.

ESP-IDF's normal interrupt path allocates 128 bytes and saves the same integer
slots. Its exception structure is 148 bytes and its initial task frame rounds
that reservation to 160 bytes. Matching those observed boundaries makes
side-by-side traces and early bring-up failures easier to compare.

## Consequences

- Assembly offsets are compile-time assertions rather than duplicated magic
  numbers with no executable specification.
- Initial tasks enter a kernel trampoline with the task entry in `a0` and its
  argument in `a1`; returning is therefore a defined kernel event.
- FPU policy is explicit and can later be measured as eager, lazy, or
  task-class-specific without changing the integer frame.
- The types alone do not install `mtvec`, take over CLIC, switch a live stack,
  or prove preemption. Those remain separate native-target milestones.

## Next native step

The assembly path now saves the 128-byte integer frame, changes to a private
per-core interrupt stack, preserves CLIC return state across a C-ABI Zig
dispatcher, and restores the selected frame. It stops safely if the dispatcher
returns null. A task trampoline defines both first entry and task return.

ESP-EMU and a physical revision-1.3 Tab5 have run a bounded
bootstrap-to-task-to-bootstrap switch on separate stacks. The test temporarily
installs the vector only for two synchronous machine-mode `ecall` operations
with maskable interrupts disabled, then restores ESP-IDF's vector and
interrupt state.

ESP32-P4 hardware stack bounds are independent of `mstatus.MIE`. The bounded
test therefore stops the monitor only while changing stacks, programs bounds
for the private interrupt stack or selected task, and restarts monitoring on
that stack. On return it also verifies that the original FreeRTOS task bounds
were restored. Arbitrary Zig task and dispatcher code now runs with hardware
stack monitoring active.

The bounded Timer Group test in ADR 0006 now delivers native asynchronous
interrupts through this entry in ESP-EMU. ADR 0007 now connects task selection
and elapsed-time accounting and preserves return CSRs per task. Normal CLIC ownership,
nested interrupts, FPU save/restore, CPU1 switching, and physical preemption
remain later gates.

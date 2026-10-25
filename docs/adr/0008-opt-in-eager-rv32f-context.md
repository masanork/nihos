# ADR 0008: Opt in to explicit RV32F save/restore before adding lazy ownership

- Status: accepted
- Date: 2026-10-25

## Decision

Preserve `f0` through `f31` and all of `fcsr` in the separate 132-byte context
defined in ADR 0005. A task opts in with a context address; integer-only tasks
use a null address and keep FS off. The first implementation saves and
restores every opted-in context at each native trap, regardless of dirty
state. This gives a visible baseline before measuring lazy save/restore.

Save the outgoing physical FP bank before calling any C/Zig dispatcher or
stack-guard helper. Keep FS off during kernel dispatch and guard operations,
then restore the selected bank after the last C/Zig call and apply the
selected task's `mstatus`. The active trap's complete `mcause` is used for the
return so `mret` unwinds CLIC priority even when switching to a task last
captured at an ECALL. No FP instructions are allowed in the dispatcher.
Cross-core FP ownership and first-use allocation are separate future policies.

## ESP-IDF boundary

The physical bank may belong to an IDF lazy owner even when the bootstrap's
FS is off. The floating test therefore opts the bootstrap into raw bank
preservation regardless of its incoming FS value. Temporary FS access permits
the transfer; selected task status and active-trap cause metadata are restored
before `mret`.

Take a raw bank snapshot after masking other CPU0 sources, and compare all
132 bytes again before restoring the host's interrupt state. Both snapshots
preserve `mstatus`, so boundary verification does not change FP enable/dirty
state. Kernel policy never infers that an FS-off host bank can be discarded.

## Target test

Reuse the delayed-first-interrupt and two-worker scheduler test from ADR 0007
in both integer and floating modes. Integer mode must perform zero FP context
saves and restores. Floating mode must perform one save and one restore per
delivered timer interrupt, including the bootstrap transitions.

Each floating worker enters a non-returning assembly probe from its Zig task
entry. The probe owns the entire FP bank, seeds distinct finite bit patterns,
executes an inexact addition with dynamic rounding, and continuously compares
all 32 registers and `fcsr`. One worker uses RNE with `fcsr=1`, the other RTZ
with `fcsr=33`. Stack canaries and progress checks remain active. A 132-byte
stack scratch preserves the bank around the independent test-watchdog call;
that scratch is unrelated to the scheduler's per-task saved context.

Using a non-returning probe avoids treating a helper that clobbers callee-saved
FP registers as an ordinary C-ABI function. These probes test machine state;
compiled floating-point application workloads remain a later integration
step.

## Consequences

- Integer tasks skip the 33 FP stores and loads; the trap still has an opt-in
  branch and FS handling, so this is not a claim of zero total overhead.
- Floating-task state is preallocated and has no allocation on the trap path.
- The integer frame and stable platform ABI remain unchanged.
- Eager transfer makes debugging straightforward but is not a physical
  performance result. Benchmark before choosing dirty-only or lazy transfer.
- ADR 0016 extends the same eager mechanism to CPU1, including physical-bank
  preservation at the IDF boundary. Nested traps, migration, cache-off
  execution, and loaded application performance remain separate work.

## Primary references

- [RISC-V F extension, register state and fcsr](https://docs.riscv.org/reference/isa/v20260120/unpriv/f-st-ext.html).
- [RISC-V machine ISA, FS context status](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html).
- Pinned ESP-IDF v5.4.4 RISC-V port and saved-frame definitions, used as the P4
  hardware oracle. nihOS's raw register-order transfers and test probes are
  independently written.

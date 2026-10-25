# ADR 0019: Attach the existing task runtime to permanent native trap owners

- Status: accepted; physical qualification remains separate
- Date: 2026-10-25

## Decision

Use the existing `task_runtime.zig`, scheduler policy, task-call dispatcher,
task-side wrappers and 128-byte integer context ABI in the independent SRAM
application. Each hart owns a `Runtime(4, 1)` instance; no other hart reads or
mutates its live policy or saved task images. Native assembly supplies the
permanent trap entry and task-call/trampoline symbols. Hosted fixtures keep
their existing assembly and remain regression/comparison backends.

The native trap saves all integer registers before calling Zig on that
hart's dedicated 8 KiB interrupt stack. The dispatcher returns the selected
frame, and the epilogue restores the selected mstatus with the active trap's
mcause before mret. New integer tasks start with MPP=M, MPIE=1 and FS=Off.
Task frame pointers are checked against their owning stack by the shared
runtime. Dispatch verifies that live MIE is clear, SP is in the interrupt
stack, and the interrupt stack's bottom sentinel remains intact. These are
diagnostic checks; they are not hardware memory isolation or a guarantee
against an already-overflowed stack.

## Elapsed time and ownership

Each owner uses its existing 1 MHz Timer Group channel as a free-running
counter with absolute one-shot deadlines. `TickClock` translates captured
microseconds into elapsed 10 ms scheduler ticks. Timer and ECALL paths both
refresh elapsed time before a policy decision, avoiding elapsed time based
solely on interrupt counts. A pending timer is acknowledged only by its owner.
The clock retains the original alarm phase and accounts for delayed delivery.

After each decision, live task runtimes plus the completed runtimes retained
at reaping must equal the owner's elapsed ticks. The owner publishes only
32-bit release/acquire counters for CPU0 to report. These publications are
monotonic observations, not a coherent simultaneous snapshot of both harts.

## Execution fixture

Each hart has a bootstrap task, two busy tasks, and a lifecycle task. All
have equal priority; busy tasks run round robin under timer preemption and
never issue ECALL/yield/sleep. Each busy task checks a private stack canary
and its stack address. All three task stacks reserve bottom sentinels that
are checked at each dispatch. Each is 4 KiB, separate from the bootstrap and
interrupt stacks.

The lifecycle task uses the shared scalar ABI to query its identity/time,
sleep three ticks, verify that it resumed after the deadline, yield and
return an exit code through the trampoline. On the interrupt stack, the
owner verifies the completion and reaps it. It creates a replacement in the
same slot and stack with a different generation; the replacement sleeps one
tick, yields and returns a distinct code. Both stale handles are rejected by
the shared wake-call dispatcher, including after reuse. No completed stack
is reused while selected or executing.

Every 100 progress rounds, both owners must show busy-task progress, timer
captures of both busy tasks, switches, task calls, two sleep completions and
two reaped completions. The 300-round validator requires three per-owner
records, with increasing busy-task, capture, switch and elapsed counters.
Timer-only heartbeats cannot qualify the scheduler. Ten log-validator tests
cover these distinctions and interrupted/incomplete runs.

## Build and qualification boundaries

`build-native-elf.sh` compiles and links the app with Zig alone. Normal
architecture CI links both revision profiles without installing IDF. The
manual native workflow additionally builds the stock loader, audits the
ESP image and boots the emulator without PSRAM. A failed rerun removes the
previous smoke report before attempting a new build.

The original boot fixture's 45-second emulator limit was reached just before
round 300 after adding dispatch checks. Progress sampling now uses a smaller
cycle interval and the wall-clock emulator limit is 60 seconds. Neither
interval is an application throughput or real-time scheduling guarantee.

This milestone does not add task migration, native IPI routing, WFI idle,
FPU task contexts, PSRAM, protection domains or display. The existing hosted
implementations of several of those features are not implied to be wired to
the native backend. Next, add native owner inbox/IPI and idle, then FP context
ownership and external-memory/display drivers. Physical rev1 qualification
remains pending while emulator work continues at the user's request.

## References

- [ADR 0018: Independent native boot](0018-independent-native-boot.md)
- [ADR 0005: Integer frame and trap ABI](0005-riscv-context-and-trap-contract.md)
- [ADR 0007: Elapsed time and preemption](0007-native-preemption-and-elapsed-time.md)
- [ADR 0009: Task lifecycle](0009-native-task-lifecycle.md)
- [Shared runtime](../../src/arch/riscv32/task_runtime.zig)
- [Native owner integration](../../src/arch/riscv32/native_tasks.zig)

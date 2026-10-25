# ADR 0007: Account elapsed counter time before choosing a return context

- Status: accepted
- Date: 2026-10-25

## Decision

Use a free-running 54-bit Timer Group counter with absolute one-shot alarm
deadlines. `TickClock` derives elapsed scheduler ticks and the next deadline
from the counter's original phase. A late interrupt advances time once by all
elapsed periods; it does not replay one interrupt or context switch per missed
tick. Backwards counters, arithmetic overflow, and out-of-range deadlines fail
without silently wrapping time.

Capture polls have a fixed bound. If arming crosses another deadline, capture
and account again, with at most four attempts. A normal event acknowledges
only the leased channel's W1C bit. The driver neither resets the counter each
period nor modifies shared clock, interrupt-enable, or watchdog registers.

At the outermost native trap tail, with MIE cleared and the private interrupt
stack active, save the outgoing task's integer frame, `mstatus`, and complete
CLIC `mcause`; apply elapsed ticks to the fixed-capacity scheduler and select
one return context. Restore the selected task's hardware stack bounds and
CSR state before `mret`. The 128-byte integer frame stays unchanged; return
state is an independently checked 8-byte structure.

## Bounded integration test

The bootstrap leases resources as in ADR 0006 and initializes two separate
4 KiB worker stacks. It intentionally holds MIE cleared until 3,500 us after
starting a 1,000 us alarm, requiring catch-up on the first interrupt.

The first interrupt saves and blocks the bootstrap task and enters a worker.
Two equal-priority integer-only workers then execute loops without ordinary
yield or syscall operations. Each timer trap applies accounting and performs
one round-robin selection. At 32 elapsed ticks, block both workers, wake the
bootstrap, and restore its saved frame and original FreeRTOS stack bounds.
Run the IDF callback timer afterwards to verify restored interrupt delivery.

Workers retain and check stack canaries across preemptions. Progress must be
nonzero, each worker must have been selected at least twice, and each reported
stack address must belong to its own stack. If timer delivery disappears,
bounded counter checks in the workers trigger an emergency ecall back to the
bootstrap after 100 ms; an independent IDF SYSTIMER read supplies this test
watchdog so a stalled Timer Group cannot stall the recovery check. That
path fails the test rather than counting as a
voluntary yield. Initial worker CSR state comes from the first real interrupt,
with floating-point access disabled. Normal worker execution stays entirely
in integer Zig code and never calls FreeRTOS services. Accounted bootstrap
and worker runtime ticks must sum to total elapsed scheduler ticks.

## Ownership and qualification

Only CPU0 owns this test's scheduler and context table. Other CPU0 external
interrupts remain pending during the short test window; CPU1 continues under
FreeRTOS. Scheduler policy runs only at the serialized outermost trap tail.
It performs no allocation, logging, locking, or unbounded work.

This is a native timer-driven task-switching milestone hosted by IDF. General
application scheduling still requires permanent CLIC ownership, defined
kernel critical sections, task lifecycle/syscall contracts, nesting, FPU
ownership, CPU1 integration, and Flash-cache-off qualification. A production
clock needs an explicit long-uptime wrap/rebase policy; this bounded test fails
on wrap/reset. Physical timing, hardware stack guards, and loaded audio/frame
latency require physical Tab5 evidence.

## Primary references

The pinned ESP-IDF v5.4.4 `hal/esp32p4/include/hal/timer_ll.h` and Timer Group
register headers specify capture synchronization, 54-bit values, and alarm
behavior. `riscv/vectors.S` specifies the observed CLIC return-state handling;
the FreeRTOS RISC-V port provides the stack-bound transition oracle. nihOS's
Zig implementations and host tests are independently written.

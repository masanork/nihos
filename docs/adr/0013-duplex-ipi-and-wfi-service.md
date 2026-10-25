# ADR 0013: Duplex IPI wakeup and a CPU1 service that parks with WFI

- Status: accepted
- Date: 2026-10-25

## Decision

Extend ADR 0012 with a bounded native window on CPU1. CPU0 continues owning
the task scheduler. CPU1 has one integer service and an idle foreground on
the stack supplied by IDF task creation. It handles only its leased IPI,
using the existing per-core interrupt stack, then parks with WFI again.
This proves reverse wakeup without first introducing a second scheduler.

The client publishes requests through an SPSC ring before asserting CPU1's
doorbell. CPU1's native IPI tail acknowledges that level, consumes a bounded
number of requests, publishes responses, and submits owner notifications to
CPU0 through the existing inbox. CPU0's native tail validates generations and
completes task waits. No payload-progress loop polls a queue or a test gate.
Both cores' vectors are native during this exchange.

The echo transformation is deliberately small and bounded in interrupt
context. General graphics, filesystem, audio mixing, or SQLite work needs a
scheduled task context and separate budgets. This fixture is not a general
permission to execute application service code in an interrupt tail.

## Check-to-WFI ordering

An exit check with interrupts enabled followed by WFI can lose its final
wakeup: the handler could set exit between the check and the instruction,
then return to a WFI with no pending interrupt left.

`park.once` masks global interrupt handling, checks the acquire exit flag,
executes the architecture wait only if exit is false, and restores the exact
previous mask state. On RV32 this uses `csrrci mstatus, 8`, WFI, and a final
`csrw mstatus`, with compiler memory barriers. The individual IPI enable and
threshold remain configured so a pending IPI can resume WFI while MIE is
clear; handling occurs after the previous MIE state is restored.

The RISC-V WFI contract permits spurious returns, including an implementation
that treats WFI as a NOP. The foreground therefore rechecks exit each time.
An executed-WFI count proves instruction-path use, not time asleep, power
savings, or physical wake latency. ESP32-P4 CLIC behavior still requires
physical qualification in addition to the emulator result.

Host tests model stop arriving before the final masked check and between that
check and wait. They also verify restoration when the caller already masked
handling. They validate the ordering protocol, not RISC-V hardware behavior.

## Resource ownership, readiness, and shutdown

CPU1's shim borrows its existing IDF source-1 route without reallocating or
remapping it. It saves the enabled mask, threshold, and vectored flag, enables
only that line during the native window, and preserves IDF's private reason
array. Assembly restores IDF's vector with MIE clear; the shim then restores
the saved interrupt state and reasserts the hardware level for retained IDF
reasons. Route, mask, vectored state, and stack bounds are checked on return.
CPU0's source-0 borrowing remains as in ADR 0012. IPC ISR sources 2/3 are
unchanged.

CPU1 publishes `ready` only after installing its native vector. CPU0 acquires
that flag before using the reverse doorbell, so an IDF handler cannot consume
the first request's doorbell before the service owns its vector. Payload
processing starts only after CPU0 has installed its own vector and publishes
`active`.

Shutdown publishes a stop request and asserts CPU1's IPI. The native service
tail acknowledges it and sets the exit flag; only then does the foreground
leave WFI and restore IDF. The CPU0 bootstrap joins the producer before its
own window ends. Timeout or partial-preparation paths also request stop and
join, and they use the reverse route only after acquiring `ready`. A CPU0
deadline controls this bounded test; CPU1 does not have an independent native
timer deadline yet.

`done` establishes that the native entry is quiescent and its borrowed state
has been restored. IDF still owns task deletion and eventual stack reclamation.
It is not a native task-reaping or stack-pool protocol for CPU1.

## Scenario and restoration checks

The existing one-way test remains a regression scenario. The new duplex test
exchanges 64 ordered requests and completions. Even-numbered requests notify
CPU1 and sleep for one CPU0 tick before waiting, exercising preposted replies.
Odd requests are held in one CPU1-owned pending slot until CPU0 records a
registered wait and asserts another IPI. That test gate advances through an
interrupt rather than a polling loop. This fixture qualifies both orderings;
it is not a latency benchmark.

The scenario checks response order/payloads, native task stack canaries, one
stale generation, a real stop IPI, terminal completion/reaping on CPU0, and
restoration of both hosts. CPU0 posts a real IDF yield reason to CPU1 during
bootstrap preparation; native handling leaves it intact for replay. After
both windows return, an ordinary CPU0 IDF task executes and
`esp_ipc_call_blocking` runs a callback to completion in CPU1's normal IDF IPC
task. The IDF periodic timer is then reused. These demonstrate resumed task
execution, not direct instrumentation of every retained IDF reason branch.

## Boundaries

Boot and initial CPU1 task creation still come from IDF. The native scheduler
still has one owner on CPU0. CPU1 native task switching, preemption, opt-in FP
contexts, per-core ready queues, permanent IPI allocation, cancellation,
buffer leases, and cross-core Flash pause/resume remain separate work.
No Flash/cache-off operation occurs inside either native window. Physical
IRQ timing and frame/audio-load interference remain hardware gates.

## Primary references

- [RISC-V privileged ISA v1.13, Wait for Interrupt](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- [ESP-IDF v5.4.4 RISC-V WFI helper](https://github.com/espressif/esp-idf/blob/v5.4.4/components/riscv/include/riscv/rv_utils.h)
- [ESP-IDF cross-core reason handling](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/crosscore_int.c)
- [ESP-IDF IPC callback completion and acknowledgement](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/esp_ipc.c)

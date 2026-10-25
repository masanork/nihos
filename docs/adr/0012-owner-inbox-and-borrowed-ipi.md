# ADR 0012: CPU1 posts events through an owner inbox and a borrowed IPI

- Status: accepted
- Date: 2026-10-25

## Decision

Keep CPU0 as the sole owner of its native scheduler and saved task frames.
A CPU1 producer publishes fixed-size notifications containing a task slot,
generation, and event bits through a bounded SPSC inbox. Only the CPU0 native
IPI tail resolves the target and applies the ordinary latched-event policy.
There are no task-supplied pointers, allocation, or scheduler locks on this
path. One inbox has one producer; multiple tasks or nested IRQ producers must
not concurrently enter that producer endpoint.

`queued` means the record was published and the doorbell asserted. It does
not mean the target accepted it. Stale/dead targets are rejected when the
owner drains the inbox; a service requiring per-request acknowledgement must
provide that in its completion protocol. Full and malformed posts leave the
inbox unchanged and do not assert the doorbell.

## Queue and interrupt ordering

The producer publishes a record with release ordering, then performs an I/O
fence, writes one to the leased level-doorbell register, reads it back, and
completes another fence. Queue data and notification metadata are visible
before the interrupt can be serviced. CPU1 never accesses the scheduler.

The owner clears the hardware level, reads back and fences, then consumes
records with acquire ordering. A post before acknowledgement is already in
the inbox when it is drained; a post after acknowledgement raises the level
again. Each tail has a fixed record budget. If records remain after that
budget, it reasserts the doorbell itself. Otherwise an acknowledged batch
could strand records without another producer post. A producer posting after
the final empty observation raises its own doorbell.

The trap captures the interrupted CPU0 frame, drains events, accounts for
elapsed time, and selects a resumable task. Deferred wait replies use the
existing ADR 0010 path. An IPI may be the first native trap, so initial integer
return states are seeded from the first timer **or** IPI capture. Timer tails
and ECALLs do not poll or drain the remote inbox.

## ESP-IDF resource boundary

All four HP FROM_CPU sources are already owned in the pinned IDF setup:
sources 0/1 implement IDF cross-core requests; sources 2/3 implement its IPC
ISR. Allocating one as an independent native source would conflict with IDF.

The bring-up shim therefore borrows CPU0's existing source-0 line only during
the bounded native window. It reads the existing matrix route and verifies a
distinct, enabled, level-triggered CLIC line. It neither reallocates that
interrupt nor changes its handler, priority, or matrix route. The timer and
this line are enabled together through the native non-vectored trap entry;
the other CPU0 sources remain deferred as in earlier bounded windows.

Native handling acknowledges only the hardware level. It never reads or
clears IDF's private cross-core reason array. On exit, assembly restores the
IDF vector before the shim restores the line's vectored flag, threshold, and
enabled mask. With MIE still clear, the shim unconditionally reasserts source
0 so the normal IDF handler can consume its retained reasons. An empty reason
set is harmless in the pinned implementation. Sources 1/2/3 remain untouched.
The route and vectored flag are checked again when returning ownership.

This is a version-pinned bring-up adapter, not the permanent native SMP IPI
allocation policy. Deferral is bounded and no Flash/cache-off operations are
allowed in this scenario. Retaining a watchdog/debug reason is not a claim
that delaying it would be acceptable in a permanent kernel.

## Scenario and cleanup

Run two native integer tasks on CPU0 and one IDF-created task pinned to CPU1.
The client publishes 64 ordered requests. For each reply, CPU1 waits for a
test-only acquire flag proving that the native client registered its wait,
then publishes the response and posts the owner notification. An observer
task waits for the final completion bit. CPU1 also posts one stale generation
to verify rejection in the owner tail and submits a real IDF yield request
while the native vector owns the line.

The client copies each response after its event wait, checks order, payload,
and a stack canary, and exits. The observer checks its own canary and exits.
The native bootstrap joins the CPU1 producer before leaving the window; failed
preparation and timeout paths also request stop and join. Queue storage stays
allocated for the firmware lifetime. After restoring IDF, launch an ordinary
CPU0 IDF task and verify that it actually executes, then reuse the IDF timer.
This checks scheduler resumption, not instrumentation of every IDF reason
branch.

Host tests cover publication before ringing, invalid/full rejection, both
notification/wait orderings, bit 31, retained replies, bounded-drain rearming,
and old/dead targets at delivery. MMIO behavior and trap restoration are
target-execution tests, not host-test conclusions.

## Boundaries

CPU1 still runs under IDF and polls its request queue and test gate. Native
CPU1 boot, task switching, CPU0-to-CPU1 event forwarding, bidirectional native
blocking channels, cancellation, and permanent service lifetimes remain open.
The current proof is remote delivery **to** CPU0's native owner. It does not
turn the scheduler into a multi-owner SMP scheduler or establish physical
timing, cache-off safety, Flash pause/resume, or game-load performance.

## Primary references

- [IDF v5.4.4 cross-core reason publication, acknowledgement, and handlers](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/crosscore_int.c)
- [IDF v5.4.4 RISC-V IPC ISR source allocation](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/port/arch/riscv/esp_ipc_isr_port.c)
- [ESP32-P4 FROM_CPU register operations](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/crosscore_int_ll.h)
- [ESP32-P4 CLIC register layout](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/include/soc/clic_reg.h)
- [ESP-IDF interrupt allocation and multicore ownership](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/system/intr_alloc.html)

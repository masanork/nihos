# ADR 0006: Lease a Timer Group channel for native interrupt bring-up

- Status: accepted
- Date: 2026-10-25

## Decision

Implement Timer Group channel configuration, start, acknowledge/rearm, and
stop in Zig. Use an exclusively leased, clocked 1 MHz channel. Keep shared
clock-tree, watchdog, and interrupt-enable registers under the resource
owner's control. Clear a pending alarm with exactly its W1C mask, and rearm
the alarm-enable bit that hardware clears on every match.

During ESP-IDF bring-up, `compat/espidf/native_timer.c` obtains the channel
through the GPTimer allocator and obtains a dedicated CPU0 interrupt through
`esp_intr_alloc`. It reads the allocated group/channel map through the pinned
IDF v5.4.4 private GPTimer header. This dependency stays in the compatibility
adapter; Zig receives only the register base, channel index, and CLIC cause
number. C and Zig compile-time assertions check the register layout.

This avoids stealing SYSTIMER resources from the running host. IDF's
`freertos/port_systick.c` assigns SYSTIMER alarms 0 and 1 to the two cores;
`esp_timer_impl_systimer.c` assigns alarm 2 to `esp_timer`. The future native
backend must explicitly acquire those resources when it replaces the host.

## Bounded vector window

With `mstatus.MIE` cleared, save CPU0's external interrupt-enable mask and
threshold, mask the other external sources, and mark the leased interrupt as
non-vectored. IDF's threshold helpers account for the revision-1 MMIO and
revision-3 CSR interfaces. Install the nihOS `mtvec` and enable interrupts.
The timer alone then enters nihOS's existing save/dispatch/restore assembly.

The Zig dispatcher checks the interrupt flag, hart, cause number, and channel
status, acknowledges/rearms the timer, and increments a bounded-test tick
counter. It returns the interrupted frame with `mepc` unchanged. The assembly
uses its private interrupt stack and updates hardware stack bounds as in
ADR 0005. The interrupt path performs no allocation, logging, or device I/O
beyond timer acknowledgement.

After 32 ticks or a 100 ms timeout, stop the timer and clear its event. Clear
MIE and fence the MMIO writes before restoring ESP-IDF's vector, threshold,
vector mode, and interrupt-enable mask. Check the restored mask, threshold,
vector mode, and task stack bounds, then free the interrupt and channel on
CPU0. Run the lease twice and subsequently exercise the IDF timer callback
again to test resource reuse and restored interrupt delivery.

## Evidence and limits

Host tests cover register placement, rejected ranges, preserved divider bits,
alarm rearming, and channel-specific W1C writes. ESP-EMU executes the native
asynchronous interrupt and return path. Physical revision-1 qualification is
a separate gate.

Other CPU0 interrupts are deferred for the test window; CPU1 continues under
FreeRTOS. This is a bootstrap test, not an application scheduling mode. Flash
operations and power-management transitions are excluded. The dispatcher
and its callees have not been qualified for cache-off execution. Periodic
alarm delivery can coalesce when servicing is delayed; scheduler timekeeping
must account for elapsed counter time before this drives preemption. Native
task selection, FPU state, nesting, CPU1 preemption, and permanent CLIC
ownership remain separate steps.

## Primary references

- Pinned ESP-IDF v5.4.4 `hal/esp32p4/include/hal/timer_ll.h`, Timer Group
  register headers, `riscv/vectors_clic.S`, and `interrupt_clic.h`.
- [GPTimer resource lifecycle](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/peripherals/gptimer.html).
- [Interrupt allocation and core affinity](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/system/intr_alloc.html).

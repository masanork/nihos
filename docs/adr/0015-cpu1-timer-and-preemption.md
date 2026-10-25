# ADR 0015: CPU1 owns a timer clock and can preempt non-yielding tasks

- Status: accepted
- Date: 2026-10-25

## Decision

Add a timed CPU1 scenario alongside the existing untimed owner runtime.
CPU1 leases a separate stopped 1 MHz Timer Group channel and a priority-3
interrupt through pinned ESP-IDF. It enables that line alongside its borrowed
IPI only during the native window. The timer never mutates CPU0 policy or
publishes service responses. The CPU1 timer tail captures the current frame,
acknowledges only its channel, advances its own clock, and selects a task.

Both cores now have independent native timer ownership in the same bounded
window. IDF still provides boot, initial task placement, and resource leasing;
this does not establish permanent native interrupt allocation or CPU boot.

## Time and task accounting

The CPU1 timer tail is the sole owner of elapsed-time updates. It feeds the
free-running counter to the existing `TickClock`, applies all newly elapsed
ticks once, and rearms the next absolute deadline with a bounded retry if
that deadline was crossed. IPI and task-call tails can deliver/select tasks
but do not consume clock advancement. Time queries therefore return CPU1's
last interrupt-accounted tick count. CPU0 retains its existing clock behavior;
the two owners have separate phases and their tick values are not a shared
wall clock.

The timed runtime enables SLEEP. A task resumes once its owner clock reaches
the accepted kernel tick deadline. Duration is expressed in scheduler ticks,
not a guaranteed minimum microsecond delay from an arbitrary counter phase.
The older untimed mode still returns `not_supported` for SLEEP and retains
its zero tick count as a regression case.

Before reaping, add the retained runtime counts for idle and both workers
with checked arithmetic and compare the sum to the owner's elapsed ticks.
This verifies the scheduler's tick-accounting invariant, not sub-tick CPU
profiling or attribution of time spent inside interrupt helpers.

## Preemption proof

Configure a 1 ms first alarm, then intentionally hold MIE clear until the
counter reaches 3.5 ms before publishing CPU1 readiness. No native task can
query or consume time during that interval. The first pending timer delivery
must account for three elapsed ticks and preserve the original deadline phase.

The service task then sleeps for five CPU1 ticks. Its peer enters a loop
containing no ECALL, yield, or clock query and keeps a progress counter and
stack canary. The sleeping service marks that loop complete only after
resuming. Record the accepted sleep start/deadline, resumed tick, timer
captures of executing tasks, missed ticks, and the fact that the timer tail
performed the sleeping-to-ready transition. This proves preemption of one
non-cooperative task to run its sleeping peer; it is not a two-busy-worker
throughput benchmark.

After that probe, run the existing 64-message duplex protocol and normal task
exit/reaping. Preposted and registered replies must both still work, but the
initial sleep probe can make the first even request block as well. The two
native stacks, observer handshake, and payload stack checks are reused.

## Resource transitions and rollback

Allocate/free the timer interrupt on CPU1. Shared Timer Group interrupt-enable
updates use the vendor group lock; counter/alarm operations remain per-channel
MMIO. The driver retains channel/group references, so releasing CPU1's channel
does not own or release CPU0's channel.

The native finish hook always stops the counter/alarm and clears its pending
status with MIE clear before restoring IDF's vector. It runs even if prepare
started the timer and later declined entry. Only after returning to IDF does
CPU1 verify stopped/no-pending state, disable the peripheral event, release
the interrupt/channel, and return its IPI lease.

There are two distinct enabled-mask snapshots: window entry while the timer
line is owned, and the CPU state before timer interrupt allocation. The window
restores/verifies the first. Before releasing the allocated line, restore only
its CPU enable bit to the second snapshot; after release verify that original
mask. Failure rollback also restores a same-core allocated line before free.

The pinned SDK's disabled-allocation flag disconnects a peripheral in the
interrupt matrix, and its interrupt-free path also disconnects the matrix
without clearing that CPU enable bit. Merely toggling a CLIC mask would
therefore neither reconnect a disabled allocation nor undo the allocation's
enable side effect. The lease allocates a connected line while the counter is
stopped, and explicitly restores its owned enable bit before SDK free. Other
CPU lines and IDF's retained IPI reasons remain untouched.

## Boundaries

Tasks in this scenario remain integer-only. FP contexts, permanent timer/IPI ownership,
migration, general cancellation, dynamic stacks, shared global time, buffer
leases, and cross-core Flash pause/resume remain separate contracts. The
test retains a CPU0 watchdog deadline and performs no cache-off operation.
Physical timing and frame/audio interference require hardware qualification.

ADR 0016 adds a separate floating-task mode while retaining this integer
scenario as a zero-FP-copy regression. Its qualification is recorded in the
[CPU1 floating measurement](../measurements/2026-10-25-tab5-cpu1-floating.md).

## Primary references

- [IDF v5.4.4 GPTimer channel registration, shared-register locking, and deletion](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_driver_gptimer/src/gptimer.c)
- [IDF v5.4.4 interrupt allocation, disable, and free implementation](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_hw_support/intr_alloc.c)
- [ESP32-P4 interrupt allocation and core ownership](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/system/intr_alloc.html)

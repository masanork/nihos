# ADR 0004: Timer interrupts publish ticks, scheduler code consumes them

- Status: accepted
- Date: 2026-10-25

## Decision

Keep timer delivery and scheduler policy separate and bounded. The ESP-IDF
callback increments a saturating atomic tick counter and returns; safe kernel
code drains it and makes an explicit scheduling decision.

The native CPU0 path introduced in ADR 0007 has two phases at the outermost
trap: acknowledge/capture/rearm the device, then apply elapsed time and select
the return frame on the private interrupt stack with MIE cleared. Policy is
serialized at this trap tail, with no nested scheduler entry, allocation,
logging, blocking operations, or shared driver locks. Kernel/task execution
outside this test must define the same ownership rules before it may mutate
the task table.

The initial single-core policy uses fixed priorities and round-robin ordering
within a priority. Its task table has compile-time capacity, performs no
allocation, and identifies slots with generation-checked handles so a stale
handle cannot act on a replacement task.

The ESP-IDF bring-up backend exposes one periodic GPTimer through the platform
ABI. Its callback runs in ISR context and is an oracle for the interrupt-to-Zig
boundary. It is not the native nihOS timer driver or a nihOS context switch.

## Rationale

Keeping arbitrary device work, logging, allocation, and unbounded queue work
out of interrupts limits latency and makes SMP ownership easier to teach and
test. The native fixed-capacity scheduler has bounded selection cost. Native
elapsed time comes from the free-running counter, so delayed or coalesced
interrupts do not lose elapsed ticks. The IDF callback's saturating counter
makes overload observable instead of silently wrapping.

Fixed priorities are sufficient for early display/audio service experiments;
round robin prevents equal-priority starvation. Deadline scheduling and
priority inheritance require measured workloads and explicit blocking
contracts before they are added.

## Remaining native work

- program the ESP32-P4 timer and CLIC without ESP-IDF ownership;
- qualify native timer-driven switching on physical silicon;
- add floating-point context, address/protection state, and safe nesting;
- request rescheduling from syscalls, wakeups, and cross-core IPIs; and
- measure preemption latency and frame/audio interference on a physical Tab5.

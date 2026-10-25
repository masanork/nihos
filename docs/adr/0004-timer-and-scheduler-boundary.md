# ADR 0004: Timer interrupts publish ticks, scheduler code consumes them

- Status: accepted
- Date: 2026-10-25

## Decision

Keep the timer interrupt path bounded: it increments a saturating atomic tick
counter and returns. Scheduler policy drains accumulated ticks outside
interrupt context, updates runtime accounting and sleepers, then makes one
explicit scheduling decision.

The initial single-core policy uses fixed priorities and round-robin ordering
within a priority. Its task table has compile-time capacity, performs no
allocation, and identifies slots with generation-checked handles so a stale
handle cannot act on a replacement task.

The ESP-IDF bring-up backend exposes one periodic GPTimer through the platform
ABI. Its callback runs in ISR context and is an oracle for the interrupt-to-Zig
boundary. It is not the native nihOS timer driver or a nihOS context switch.

## Rationale

Running queue mutation, logging, allocation, or device work in an interrupt
would enlarge latency and make SMP races harder to teach and test. Accumulated
ticks also preserve elapsed scheduler time if safe kernel work is briefly
delayed. Saturation makes overload observable instead of wrapping the counter
and silently moving time backwards.

Fixed priorities are sufficient for early display/audio service experiments;
round robin prevents equal-priority starvation. Deadline scheduling and
priority inheritance require measured workloads and explicit blocking
contracts before they are added.

## Remaining native work

- program the ESP32-P4 timer and CLIC without ESP-IDF ownership;
- enter a RISC-V trap frame on a dedicated interrupt stack;
- save and restore integer, status, and optional floating-point context;
- switch stacks and address/protection state;
- request rescheduling from syscalls, wakeups, and cross-core IPIs; and
- measure preemption latency and frame/audio interference on a physical Tab5.

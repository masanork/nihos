# ESP-EMU latched task events smoke

- Date: 2026-10-25
- Firmware commit: `9e39bdc8c2762c1ae693e7810a1fdce3f2704815`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; task events extend the experimental native ECALL ABI

## Result

Two integer Zig tasks exercised latched event notification and masked waits
through the reusable native runtime. The receiver slept for two ticks before
consuming preposted events. A duplicated bit coalesced, so consuming it once
made the next wait block. Bits outside the requested mask remained pending;
bit 31 was successfully returned as data rather than an error.

While the receiver waited for bit 0, its peer posted bit 2 and slept for one
tick. The receiver remained waiting. A later matching post resumed it with
the deferred reply in its saved ECALL return registers. It then consumed the
retained bit 2 immediately. Both tasks checked their stack canaries and
returned through the normal EXIT trampoline, with completion codes 41/43.

```text
event_immediate_receives=3
event_blocked_waits=1
event_deferred_deliveries=1
event_syscalls=21
event_timer_interrupts=4
event_idle_runtime_ticks=4
event_exit_code_0=41
event_exit_code_1=43
event_reaped=2
event_replacement_generation=2
event_stale_handle_rejected=1
native_events=ok
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

Zero masks and zero notification payloads were rejected through real
ECALLs. Notification to the completed receiver returned invalid-state.
After execution stopped, both tasks were reaped and a replacement was
registered with generation 2 without running it. A notification addressed
to the old generation-1 handle returned not-found and left the replacement
ready with an empty pending set.

The same boot also passed the existing SMP mailbox, synchronous context
switch, repeated native periodic-timer lease, integer preemption, RV32F
register preservation and host-bank restoration, sleep/block/wake lifecycle,
and final IDF callback-timer restoration scenarios.

## Other checks and resource boundary

Debug and ReleaseSafe host runs each passed all 35 tests. Coverage includes
the two notification/wait orderings, coalescing and masks, keeping a deferred
reply separate from later posts including the same bit, sleeping/blocked
task semantics, terminal cleanup, stale handles, and invalid ABI arguments.
ZLint reported zero errors and warnings across 20 files; formatting,
ShellCheck, RV32 architecture compilation, and the C/Zig/Rust ABI probe passed.

Both the physical revision-1 target and emulator revision-3 ESP-IDF builds
passed. The physical-target application is 395,376 bytes (`0x60870`), leaving
62 percent of the 1 MiB application partition free. This is 3,552 bytes more
than the prior lifecycle image; it includes the new test tasks and diagnostic
strings, so it is not a standalone production cost for event notification.

The event scenario reuses the lifecycle harness and its two fixed 4 KiB
stacks. Live wait/notify uses no heap allocation, locks, or variable-length
queues; each task gains three `u32` fields before target-specific structure
padding. No IRQ-latency, throughput, power, or Quake performance claim is
derived from this functional smoke.

## Boundary

No physical Tab5 was flashed during this step. This qualifies CPU0 event
semantics under target execution in the emulator. It does not qualify
physical interrupt timing or device completion, and the existing mailbox
test does not make the native scheduler an SMP scheduler.

The scheduler has one serialized owner. CPU1 notification via owner mailbox
and IPI, direct device-IRQ integration, timed event waits/cancellation,
capability rights, and permanent native task scheduling remain later work.
Repeated event bits coalesce: queue data belongs in a separate transport such
as the existing SPSC ring. See [ADR 0010](../adr/0010-latched-task-events.md).

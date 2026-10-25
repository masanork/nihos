# ESP-EMU native preemption and delayed-tick accounting

- Date: 2026-10-25
- Firmware commit: `65bff8c8c9ab68a05d2c6dcb26750ef646173d73`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5

## Result

The exact committed firmware ran two integer-only Zig workers on independent
4 KiB stacks using timer-driven round-robin selection. Neither worker issued
a normal yield. Every switch used the native integer-frame save/restore,
selected-task `mstatus`, and hardware stack-bound updates. This exact
historical emulator run predates the physical-test clarification that `mret`
must use the active trap's complete `mcause` to unwind CLIC priority when a
different task is selected. See [ADR 0007](../adr/0007-native-preemption-and-elapsed-time.md)
and the [physical Tab5 native SMP preemption record](2026-10-25-tab5-native-smp-preemption.md)
for that correction's hardware qualification; this record's measurements
remain unchanged.

The test deliberately masked interrupts for the first 3,500 us of a 1,000 us
absolute-deadline timer. Its first interrupt therefore accounted for three
elapsed ticks. Subsequent interrupts retained the original counter phase.
Thirty delivered interrupts advanced scheduler time by 32 ticks, including
two caught-up ticks, in 32,001 emulated us.

```text
preemption_elapsed_ticks=32
preemption_interrupts=30
preemption_caught_up_ticks=2
preemption_elapsed_us=32001
preemption_bootstrap_runtime_ticks=3
preemption_worker=0
preemption_iterations=472709
preemption_selections=15
preemption_runtime_ticks=15
preemption_worker=1
preemption_iterations=456440
preemption_selections=14
preemption_runtime_ticks=14
native_preemption=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128044
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

Bootstrap and worker runtime accounting summed to exactly `3 + 15 + 14 = 32`
ticks. Both workers made progress, retained their volatile stack canaries,
and reported stack addresses within their own stack regions. Worker loop
counts are functional progress checks, not physical performance estimates.
The bootstrap resumed at its original saved frame after both workers were
blocked. The final IDF timer callback run verifies restored interrupt
delivery after native resource release.

The preceding 100,000-message CPU0/CPU1 mailbox, synchronous context switch,
and two native periodic-timer lease/release tests also passed in the same
boot.

## Other checks

ZLint reported zero errors and warnings across 15 Zig files. Debug and
ReleaseSafe host runs passed all 24 tests. These include delayed elapsed-time
accounting, phase retention, backwards/overflow rejection, one-shot 54-bit
deadline placement, bounded capture timeout, and integer-task CSR metadata
preservation. ShellCheck, RV32 architecture compilation, and both revision-1
physical-target and revision-3 emulator-target ESP-IDF builds passed.

The physical-target application is 379,376 bytes (`0x5c9f0`), leaving 64 percent
of its 1 MiB application partition free. Worker stacks add a fixed 8 KiB of
internal-RAM storage; this test allocates no task memory at switch time.

## Qualification boundary

A separate MeOS Wi-Fi/SD coexistence test occupied the physical serial port
during qualification. This firmware was not flashed, and physical native
timer/preemption qualification remains pending. Emulator results do not
qualify the physical P4 hardware stack monitor, latency, or timing under
display/audio load.

The emergency 100 ms recovery path uses the independent IDF SYSTIMER as a
test watchdog; the normal successful path never takes that ecall. Deliberate
loss of timer delivery has not yet been qualified as a target fault test.
Scheduler accounting itself uses only the free-running native Timer Group
counter. CPU1 and the rest of the firmware remain hosted by FreeRTOS; FPU,
nesting, permanent CLIC ownership, and application syscall/lifecycle
contracts remain open. See [ADR 0007](../adr/0007-native-preemption-and-elapsed-time.md).

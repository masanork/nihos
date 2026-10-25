# ESP-EMU native Timer Group interrupt smoke

- Date: 2026-10-25
- Firmware commit: `3166c1d4767cd02682311bbadc3e14583ed991ab`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; the temporary resource lease is private to the bring-up
  adapter and does not extend the stable platform ABI

## Result

The exact committed firmware ran two native timer windows in a single boot.
Each acquired and released a GPTimer channel and dedicated CPU0 interrupt,
configured the 1 MHz channel from Zig for a 1,000 us auto-reload period, and
received 32 asynchronous interrupts in 32,001 us.

CLIC non-vectored cause 20 entered nihOS's trap assembly, saved the integer
frame, moved to the guarded 2 KiB interrupt stack, and called the Zig
dispatcher. The dispatcher validated and cleared the channel event, rearmed
the alarm, and returned the same frame with the interrupted `mepc` unchanged.
The raw CLIC cause was `3087007764` (`0xb8000014`).

```text
native_timer_run=1
native_timer_ticks=32
native_timer_elapsed_us=32001
native_timer_interrupt_id=20
native_timer_mcause=3087007764
native_timer_run=2
native_timer_ticks=32
native_timer_elapsed_us=32001
native_timer_interrupt_id=20
native_timer_mcause=3087007764
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128042
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The final IDF callback run reused the timer resource and passed after both
native windows restored the vector, interrupt-enable mask, threshold, vector
mode, and bootstrap stack bounds. The earlier SMP mailbox and synchronous
separate-stack context-switch tests passed in the same boot.

## Additional checks

ZLint reported zero errors and warnings across 13 Zig files. Debug and
ReleaseSafe host tests, ShellCheck, RV32 architecture compilation, and both
revision-1 physical-target and revision-3 emulator-target ESP-IDF builds
passed. The physical-target application is 371,056 bytes (`0x5a970`), leaving
65 percent of its 1 MiB application partition free.

## Qualification boundary

The physical serial port was occupied by a separate MeOS SD-root endurance
test, so this firmware was not flashed to Tab5. There is no physical native
timer result in this record. The earlier physical context-switch result
remains specific to its recorded firmware commit.

These emulator times establish functional timer delivery, not physical
latency or jitter. The test defers other CPU0 external interrupts for each
bounded window and leaves CPU1 under FreeRTOS. It resumes the interrupted
bootstrap task and does not select another task on a timer tick. See
[ADR 0006](../adr/0006-bounded-native-timer.md) for the resource, cache, elapsed
time, and preemption gates.

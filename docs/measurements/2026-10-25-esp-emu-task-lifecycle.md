# ESP-EMU native task lifecycle smoke

- Date: 2026-10-25
- Firmware commit: `405ef75df0ba5a26425b7f9dd31d5930c6bba798`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; native task calls use the separate experimental ECALL ABI

## Result

The exact committed firmware ran two integer Zig task entries through the
reusable RV32 runtime. The sleeper requested five ticks at scheduler tick 1
and resumed at its accepted kernel deadline, tick 6. Its peer slept for two
ticks as well, exercising bootstrap execution while both workers were asleep,
then made progress while the sleeper waited.

The sleeper subsequently blocked, resumed after one explicit wake by its peer,
and returned 17. The task trampoline converted that normal function return
into EXIT(17). The peer verified that waking the exited task was rejected and
returned 37, producing a second terminal completion. Both retained their stack
canaries across syscall suspension/resumption and timer interrupts.

```text
task_sleep_started=1
task_sleep_deadline=6
task_sleep_resumed=6
task_explicit_wakes=1
task_exit_code_0=17
task_exit_code_1=37
task_syscalls=16
task_timer_interrupts=6
task_idle_runtime_ticks=3
task_reaped=2
task_old_generation=1
task_replacement_generation=2
task_stale_handle_rejected=ok
native_lifecycle=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128043
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The runtime completed 16 real ECALLs, including current-handle/tick queries,
yield, unknown-call rejection, rejected zero-duration sleep, sleep, block,
wake, terminal-wake rejection, and both exits. Six native timer interrupts
provided deadline wakeup. Bootstrap runtime was three ticks, including the
interval when both workers were sleeping. This is a functional idle context,
not a WFI/power measurement.

After native execution stopped, both completion records were reaped. A
replacement was registered in the old slot with generation 2, without being
executed. The old generation-1 wake request returned not-found and left the
replacement ready. This qualifies handle invalidation and slot registration,
not dynamic stack allocation or a newly executed replacement task.

The same boot also passed the existing SMP mailbox, synchronous context
switch, native periodic-timer reuse, integer preemption, full RV32F register
preemption, physical FP-bank restoration, and final IDF callback-timer tests.

## Other checks

ZLint reported zero errors and warnings across 20 Zig files. Debug and
ReleaseSafe host runs passed all 29 tests. New host coverage includes scalar
call errors, sleep/block/wake transitions, terminal exit records, stale-handle
rejection after reuse, full 64-bit tick replies, and generation-exhaustion
retirement. Compile-time checks verify Zig/assembly call numbers.

ShellCheck, RV32 architecture compilation, and both physical-target revision-1
and emulator-target revision-3 ESP-IDF builds passed. The physical-target
application is 391,824 bytes (`0x5fa90`), leaving 63 percent of its 1 MiB
partition free. The lifecycle scenario uses two additional fixed 4 KiB test
stacks and no allocation in the trap path.

## Boundary

No physical board was flashed during this emulator-first development step.
Physical stack-bound behavior, interrupt latency, and loaded display/audio
timing remain unqualified for this firmware.

The task calls run in a shared trusted machine-mode domain on CPU0. Runtime
mutation is serialized; cross-core wake/IPI, join/cancellation, concurrent
reaping, user-mode/PMP rights, stack pools, and full application scheduling
remain later steps. See [ADR 0009](../adr/0009-native-task-lifecycle.md).

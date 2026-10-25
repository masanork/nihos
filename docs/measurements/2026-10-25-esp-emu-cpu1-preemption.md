# ESP-EMU CPU1 timer ownership and non-yielding-task preemption

- Date: 2026-10-25
- Firmware commit: `2715c95eee92fc7c9f2436c7c35831eed5fd2d07`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5

## Result

CPU0 and CPU1 ran separate native runtimes with independent Timer Group
channels. CPU1's new timed mode retained the two fixed 4 KiB integer-task
stacks and WFI bootstrap from the previous untimed mode. Its timer interrupt
captured the interrupted task, accounted elapsed ticks, woke eligible
sleepers, and selected the next context. IPI and ECALL paths still select
tasks but do not advance CPU1 time.

A 1 ms first alarm was deliberately held pending with MIE clear until the
CPU1 counter reached 3.5 ms, before native tasks or readiness publication.
The first timer delivery accounted three ticks, including two caught-up
ticks. The service then slept for five accepted scheduler ticks. Its peer
ran a loop containing no ECALL, yield, or clock query. CPU1's timer tail
changed the service from sleeping to ready, interrupted the executing peer,
and resumed the service at tick 8. The service checked its deadline and
canary before releasing the peer's loop.

```text
cpu1_timer_interrupts=36
cpu1_timer_task_captures=5
cpu1_timer_caught_up_ticks=2
cpu1_elapsed_ticks=38
cpu1_runtime_ticks=38
cpu1_sleep_started=3
cpu1_sleep_deadline=8
cpu1_sleep_resumed=8
cpu1_non_yield_iterations=223296
cpu1_probe_timer_wake=1
cpu1_timed_messages=64
cpu1_timed_payloads=64
cpu1_timed_switches=263
cpu1_timed_reaped=2
cpu1_timed_cpu0_timer_interrupts=35
cpu1_timed_both_hosts_restored=1
native_cpu1_timer_preemption=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128043
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The sum of retained runtime ticks for idle and both workers was 38, matching
the owner's elapsed count before reaping. This checks scheduler accounting;
it does not measure sub-tick execution time or interrupt-helper overhead.
Sleep is expressed in scheduler ticks, so this result does not promise a
minimum 5 ms delay from an arbitrary counter phase. CPU0 and CPU1 have
independent phases, and their tick values are not a shared wall clock.

The subsequent 64 request/completion pairs and payload stack checks passed.
Both CPU1 tasks returned their expected completion codes, were reaped, and
the stale-handle/replacement checks passed. Response publication remains in
the service task; adding the timer did not introduce another SPSC producer.
CPU0's own timer delivered 35 interrupts during this scenario. These counts
prove functional progress, not throughput or game-frame performance.

## Lease restoration and regressions

CPU1 acquired and released its timer channel and interrupt on CPU1. Shared
Timer Group interrupt-enable changes used IDF's group lock; per-channel
MMIO and driver channel references preserved CPU0's timer ownership. Before
restoring IDF's vector, the native finish hook stopped the counter/alarm and
cleared pending status with MIE clear, including a declined-entry path.
After returning, release checked stopped/no-pending state and restored the
allocated CPU line's enable bit before freeing its interrupt handle.

The first exploratory attempts exposed two pinned-SDK behaviors: disabled
allocation disconnects the interrupt matrix route, and freeing an interrupt
leaves its CPU CLIC enable bit unchanged. The final implementation uses a
connected allocation with a stopped timer and verifies both the native
window-entry mask and the pre-allocation mask at their respective ownership
boundaries. See [ADR 0015](../adr/0015-cpu1-timer-and-preemption.md).

Both hosts restored their stack/interrupt state. An ordinary CPU0 IDF task
and a blocking CPU1 IDF IPC callback executed afterward, followed by all 128
IDF timer callbacks. The same boot passed the previous untimed CPU1 scenario
(including unsupported SLEEP), duplex IPI/WFI, owner-event, channel,
lifecycle, integer/FP preemption, context, timer, and mailbox regressions.

## Host checks and resources

Debug and ReleaseSafe host test suites passed (51 tests each). ZLint reported
zero errors and warnings across 31 Zig files. Formatting, ShellCheck, RV32
architecture compilation, the C/Zig/Rust ABI probe, and both physical
revision-1 and emulator revision-3 ESP-IDF builds passed.

The physical-target application is 423,728 bytes (`0x67730`), 5,040 bytes more
than the previous image, with 60 percent of the 1 MiB app partition free.
The timed fixture reuses the previous 8 KiB of fixed CPU1 task stacks and
existing per-core interrupt stack. IDF allocates the timer object/interrupt
before native entry; native timer selection and accounting do not allocate
heap storage or take a run-queue lock.

## Boundary

No physical Tab5 was flashed. CPU1 tasks remain integer-only; CPU1 FP context
switching and physical timer behavior still require qualification. This is
preemption of a non-cooperative worker to run a sleeping peer, not a
two-busy-worker benchmark. Drawing/audio interference and Quake performance
have not been measured here.

IDF still owns boot and initial CPU1 launch. Permanent native ownership,
migration, general cancellation, dynamic stacks, buffer leases, rights
checks, shared global time, and cross-core Flash pause/resume remain open.
The stop path releases this fixture's loop gate and wakes an aborted sleeper
without depending on further timer progress; that is not a general task
cancellation interface or fault-injection qualification.

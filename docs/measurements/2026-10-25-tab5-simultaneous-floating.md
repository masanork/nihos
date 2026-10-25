# Overlapping floating-point owners on both ESP32-P4 cores

- Date: 2026-10-25
- Firmware commit: `52432446eacff75240e94419b75a6b182d0ae64c`
- Physical board: M5Stack Tab5, ESP32-P4 revision 1.3
- ESP-IDF v5.4.4; platform ABI 5
- Emulator: ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- Physical image: 435,328 bytes (`0x6a480`)
- Application SHA-256: `666d28d17fba463befdabbf9e8fdb1bb11613f9c2203badda4b8f75487f8a114`
- [Machine-readable emulator and physical results](2026-10-25-tab5-simultaneous-floating.json)

## Result

The exact committed implementation passed the emulator core smoke and three
consecutive recorded physical boots. The application write was verified by
esptool. All three USB RTS-reset boots reached `nihos: bootstrap complete`
after the native tests, DMA, display/vsync, and idle touch sampling. Power
remained connected; these were not cold-power tests. The serial port was
released after capture.

The new scenario ran two FP contexts per core, with four distinct register
signatures and per-task RNE/RTZ rounding state. CPU0's client and CPU1's
service exchanged the usual 64 request/completion pairs, while their observer
tasks established an explicit overlapping busy interval. This extends the
earlier CPU1-only FP test, which still runs separately as a regression.

## Interval-local evidence

CPU1's checked observer stayed behind a hold gate. CPU0 marked the interval
active, waited for CPU1's acknowledgement, and then sampled the counter
baselines. CPU0 required both eight more owner ticks and eight actual timer
captures of its observer, plus positive CPU1 observer FP-check and timer
capture deltas. It checked its own bank again and recorded the endpoints
before releasing CPU1. Both observers used FP checks without ECALL or
voluntary yield inside the interval; CPU0's integer-only watchdog was
independent of scheduler time.

| Overlap observation | ESP-EMU | Physical boot 1 | Boot 2 | Boot 3 |
| --- | ---: | ---: | ---: | ---: |
| CPU0 owner start / end tick | 1 / 9 | 1 / 9 | 1 / 9 | 1 / 9 |
| CPU0 successful FP-check delta | 26,316 | 16,182 | 16,189 | 16,273 |
| CPU1 successful FP-check delta | 286 | 159 | 159 | 159 |
| CPU0 observer timer-capture delta | 8 | 8 | 8 | 8 |
| CPU1 observer timer-capture delta | 8 | 8 | 8 | 8 |
| Peer acknowledgement | 1 | 1 | 1 | 1 |

The gate and increasing counters establish an overlap at scheduler/test-tick
granularity. They do not measure same-cycle instruction execution, a minimum
wall-clock duration, or application throughput. Check rates differ by probe
structure, and emulator versus physical counts are not a speed comparison.

Live cross-core evidence used release/acquire atomic publications. CPU0's
published tick was updated on every successful clock refresh, including
ECALL and IPI paths. Timer-capture counters were updated only by the relevant
core's timer tail. No task sampled another core's mutable scheduler policy
or non-atomic register-probe counters during execution.

## Full-window state and accounting

All four runs had the same per-owner trap totals:

| Owner | FP saves / restores | ECALLs | Timer IRQs | IPIs | Elapsed / runtime ticks |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU0 | 205 / 205 | 101 | 40 | 64 | 40 / 40 |
| CPU1 | 501 / 501 | 392 | 41 | 68 | 43 / 43 |

Each owner's eager save/restore count equalled its handled traps:
`205 = 101 + 40 + 64` and `501 = 392 + 41 + 68`. Owner clocks have independent
phases; their elapsed values are not shared wall time. Tick-accounted idle
and worker runtimes summed to each owner's elapsed count before reaping.

Full-window per-task bank checks were:

| Task | ESP-EMU | Physical boots |
| --- | ---: | ---: |
| CPU0 client | 99 | 99 each |
| CPU0 observer | 26,322 | 16,188 / 16,195 / 16,279 |
| CPU1 service | 389 | 389 each |
| CPU1 observer | 524 | 380 each |

Checks covered all `f0` through `f31` and `fcsr`, including the seeded inexact
addition's NX flag and each task's rounding mode. The wrappers checked again
after the integer-only callbacks returned and exited through the normal
task-exit ABI. CPU0 observer timer captures totalled eight; CPU1 observer
captures totalled nine, eight of them inside the recorded interval. Both
clients/services had zero timer captures in these runs. CPU0 IPIs captured
the bootstrap; CPU1 task IPI captures were service=1 and observer=3 on the
physical boots (observer=4 in the emulator). Thus the test does not claim
every task/source combination was observed.

Both owners entered and returned to IDF with FS=Off. Each finish path verified
its bootstrap owner pointers, compared the original 132-byte physical bank
and FS bits, and cleared native pointers before returning to IDF. Each core
reaped two completions, retained expected exit codes, and passed stale-handle
replacement checks. All 64 payloads passed, both hosts restored, and the final
IDF timer delivered 128 callbacks in 128,086 us on each physical boot.

## Regressions and resources

The untimed and timed integer CPU1 scenarios still performed zero FP saves
and restores. The separate CPU1-only floating scenario passed with 496 saves
and restores and its raw-bank boundary restored. Earlier CPU0 integer/FP,
lifecycle, event/channel, remote-wakeup, and duplex scenarios also passed.

Debug and ReleaseSafe each passed the existing 51 host tests. ZLint reported
zero errors and warnings across 31 Zig files. Formatting, ShellCheck, RV32
architecture compilation, the C/Zig/Rust ABI probe, and both IDF target builds
passed.

The physical image increased by 6,592 bytes over the CPU1-only FP image,
including the new scenario, counters, and console fields; 58 percent of the
1 MiB app partition remains free. CPU0 adds three 132-byte banks plus two
boundary snapshots (660 bytes) and two probe records (40 bytes), along with
scalar bookkeeping. It reuses the existing CPU0 and CPU1 native task stacks.
No FP trap allocation or global run-queue lock was introduced.

## Boundary

This is a bounded overlapping-owner qualification hosted by IDF. The FP bank
is managed by assembly while the probe callbacks intentionally remain
integer-only. Compiler-generated FP applications, task migration, nested
traps, lazy/dirty-only transfer, cache-off/Flash coordination, long-duration
stability, and permanent native boot/interrupt ownership remain separate
work. Display and touch checks ran after the FP windows; rendering/audio
interference and Quake FPS were not measured. See
[ADR 0017](../adr/0017-simultaneous-floating-owners.md).

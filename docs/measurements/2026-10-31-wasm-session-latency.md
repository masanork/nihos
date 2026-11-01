# Wasm session request latency

The headless normal-profile RV32 emulator now measures the elapsed timer time
inside the synchronous Session-to-worker request, from request submission
through reply collection. The timer uses the existing 1 MHz timer-group
counter. This interval includes scheduling and waiting for the worker; it
excludes frame allocation, presentation, worker reap and lease release.

The same image passed the six existing normal, no-input, early-quit, cancel,
metered-trap and presenter-failure cases, with a partial-open failure and a
successful synthetic-input restart after each case. Both hart timer counters
advanced and all existing recovery, generation and pixel checks passed.

Across the twelve successful starts the observed open request took
2,165,704–2,166,111 microseconds of emulated timer time. The maximum render
request in each normal or restarted session was 817–818 microseconds; the
injected metering trap took 2,661 microseconds. Close requests took
1,443–1,444 microseconds. These are observations for this emulator and
candidate, not physical-device latency or a worst-case guarantee.

The foreground loop does not service camera or network while any synchronous
request is waiting. The measured open interval therefore makes connecting this
backend directly to normal interactive UI premature. The next integration
must make startup nonblocking, retain the pin and frame ownership until the
worker has actually stopped, and verify foreground progress plus cancel/failure
cleanup before enabling a camera/display profile.

Unit tests and static analysis, including the six audited RV32 links, passed.
The [retained report](evidence/2026-10-31-wasm-session-latency/report.json)
contains all request timings and exact emulator image hashes. No device was
flashed or tested, and remote CI has not been run.

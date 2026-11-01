# Scheduled Wasm nonblocking open

The headless normal-profile RV32 fixture now submits WAMR's signed-package
open to its registered worker and polls for completion. The foreground may
perform another turn while the worker initializes. A cancelled open retains
the pinned engine lease, waits for the open response, sends close, and releases
the pin only after the matching task has actually been reaped. A damaged
arena is left pinned and reported as an error.

The fixture tests a successful asynchronous open, cancellation while opening,
an injected partial-open failure, frame allocation failure after successful
open, and a second start attempted while open is in progress. Every path checks
task reap and exact reusable-heap recovery. The six original input and failure
cases still run after these checks. Both hart timer counters advance while the
worker initializes. The counted foreground turns execute the polling fixture:
they do not establish camera or network service progress.

The initial submission still synchronously allocates and initializes the pinned
extent. On this emulator candidate the submission and immediate cancellation
together take 4,291 microseconds of emulated timer time, with 112 foreground
polling turns while cancellation completes. A 100 ms emulator-only threshold
guards against a return to the seconds-long synchronous open; it is not a
device acceptance limit. The final ready
poll executes the first Session frame synchronously, and ordinary active-session
close remains synchronous. This is not a whole-application latency bound or a
physical-device measurement.

The common session's normal shell selector and display-owner presenter do not
yet use the asynchronous API. Integrate and test actual foreground
camera/network service, input routing, cancellation, and repaint before a
device profile. WAMR alignment adoption, exact-candidate Tab5 qualification,
remote CI and main reconciliation also remain open.

Run `sh probes/wamr-native/run-session-emulator.sh` for the retained six-case
fixture. [Candidate evidence](evidence/2026-10-31-wasm-async-open/identity.json)
binds its logs and report to the source and image hashes.
The compiled candidate was tested before the threshold was added to the runner;
all six retained measurements were checked against that threshold afterward.
Debug and ReleaseSafe unit tests, static analysis, 491 Python regressions and
the existing native-session emulator matrix passed. The current main head has
advanced beyond the integration base and remains to be reconciled.

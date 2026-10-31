# Wasm asynchronous close failure

The integration branch now includes main through
`1c7935aa2e50e28ba1d484d700957fa1782bdc13`, including continuous-camera
failure and soak changes. The original main checkout's concurrent edits are
kept separate.

The asynchronous Wasm startup controller now also checks whether its worker
has exited while waiting for a close acknowledgement. After actual task reap it
returns an error, rather than polling an acknowledgement that will never
arrive. An unrecovered engine arena remains pinned. A startup failure from
partial initialization or frame allocation now returns the same error on
subsequent polls.

The headless RV32 fixture injects a missing close acknowledgement after
cooperative engine teardown and verifies task reap, recovered arena, exact
heap recovery and repeated error reporting. It additionally checks repeated
partial-open and frame-allocation errors, then runs the existing six
input/failure and restart cases. This injection models an exited worker; it
does not establish arbitrary engine crash recovery or forced termination.

The merged camera changes initially caused the optional native session device
image to fail the unchanged 48 KiB SRAM floor. Foreground input action dispatch
now resides in its audited Flash extent while the interrupt and cache-control
paths remain in SRAM. The enabled and disabled native device images pass their
audits with 49,344 and 50,368 bytes of SRAM heap reservation respectively.
These are static image spans, not physical free-memory measurements.

Debug/ReleaseSafe unit tests, static analysis, 501 Python regressions and the
headless six-case Wasm matrix pass. Candidate hashes and logs are retained in
the [identity record](evidence/2026-11-01-wasm-async-close/identity.json).
The Wasm fixture is still headless: the normal UI backend selector, camera and
network foreground coexistence, physical scanout, WAMR alignment decision,
remote CI and exact-candidate Tab5 validation remain open.

# Foreground UI service with the Wasm emulator fixture

The headless repeat profile now enters `diagnostic_ui.service` from the normal
`normalReady` foreground loop. The test-only branch uses ROM UART and the
substitute shell storage and pixel presenter, calls the ordinary UI input poll
and Wasm controller, and returns without hardware scanout. The fixture observes
its states after that service returns rather than calling input polling itself.
The normal loop also passes the network and storage service call sites; those
services are disabled in this headless profile, and the compiler may remove
their no-op calls. This does not establish network, storage or camera progress.

The [repeat runner](../../probes/wamr-native/run-repeat-emulator.sh) exercises
active, startup cancellation, and active again in one RV32 boot. It checks the
pixel oracle, per-round prompt return and resource recovery as before. A probe
at the foreground-loop position immediately before the UI service counts turns
by Wasm controller phase. It also records the maximum observed elapsed time
between probe turns or from the probe to the return of UI service. For the
retained candidate, measured emulated time was:

| Round | Scenario | Opening turns | Cancelling turns | Active turns | Maximum observed gap |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | active then quit | 109 | 0 | 2 | 20,054 us |
| 2 | immediate opening cancellation | 1 | 110 | 0 | 20,001 us |
| 3 | active then quit | 109 | 0 | 2 | 20,003 us |

The runner checks that relevant phases progress and that each observed maximum
is below a test-only 200,000 us regression bound. These numbers are emulator
observations for this input sequence, including timer scheduling and synchronous
render/close; they are neither physical latency nor a worst-case guarantee.
The initial test incorrectly required more than one opening turn even when the
runner immediately cancelled; the corrected assertion requires at least one
opening turn and repeated cancellation progress. Both runs are retained.

Debug and ReleaseSafe tests, static analysis, 501 Python regressions, the prior
UART cases, three native Rust session cases and six existing Wasm session cases were run. Exact candidate hashes
and logs are in the [evidence record](evidence/2026-11-01-wasm-foreground-ui-service/identity.json).

Actual display service beyond this headless branch, USB Serial/JTAG, hardware
scanout/cache, camera, network and storage service work remain unverified.
Resolving WAMR alignment and exact-candidate Tab5 qualification are still gates
before a device Wasm profile.

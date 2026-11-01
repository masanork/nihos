# Wasm UI polling with emulator UART input

The emulator-only `NIHOS_NATIVE_WASM_INTERACTIVE=1` fixture now routes UART
bytes through the normal diagnostic UI's foreground `poll`, session serial
decoder and `sessionKey`, then through the same asynchronous Wasm UI controller
and scheduled WAMR worker. This uses ROM UART RX as an explicit test transport;
the normal physical UI continues to use USB Serial/JTAG. The fixture begins a
real session model, but its model storage and pixel presenter are substitutes.
It ends after one checked session and is a test fixture, not a reusable live UI.

The [runner](../../probes/wamr-native/run-interactive-emulator.sh) injects
Escape after session readiness, waits for the shell view, sends `rust-app` and
Enter, and then runs two separate boots:

* After the application becomes active, `0 → 1 → 0 → q` produces four frames.
  The substitute presenter checks the ready, ready, pressed, ready state sequence
  and every one of the 12,800 pixels in each frame;
  termination checks shell dirty state, worker reap, and exact heap recovery.
* While the asynchronous open is still in progress, `q` cancels it. The
  fixture checks no frame was presented, shell dirty state, worker reap, and
  exact heap recovery.

The runner checks output markers and exact ELF and flash hashes across runs.
The build guard requires the existing headless emulator Wasm session profile;
a device/integer request with only the interactive flag was rejected. Debug
and ReleaseSafe unit tests, static analysis, all 501 Python regressions, and
the existing six-case Wasm session emulator matrix passed. The first Python run
found three stale `main.zig` hashes in UI asset manifests; refreshing those source
identities, without changing the asset payloads, made the rerun pass. See the retained
[identity and evidence](evidence/2026-11-01-wasm-ui-uart-poll/identity.json).

This does not exercise physical USB serial, keyboard, the normal display service
loop, real camera/network service, DMA, scanout, cache maintenance or Tab5.
The startup and first active-session close/render limitations described in the
[previous report](2026-11-01-wasm-ui-dispatch.md) remain. WAMR alignment and
physical qualification remain gates before a device profile.

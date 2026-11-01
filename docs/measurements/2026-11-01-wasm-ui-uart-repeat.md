# Repeated Wasm sessions over emulator UART

The emulator-only `NIHOS_NATIVE_WASM_INTERACTIVE_REPEAT=1` mode retains the
headless session across application exits and returns its shell text to ROM
UART. Input goes through the diagnostic UI's ordinary foreground poll, serial
decoder, shell and Wasm controller. The process keeps running after each stop;
its shell model storage and RGB565 presenter remain test substitutes. The UART
stream includes diagnostic markers, and this mode is not a graphical display.

[The runner](../../probes/wamr-native/run-repeat-emulator.sh) drives one RV32
emulator boot through launcher Escape, `rust-app`, `0 → 1 → 0 → q`, a second
`rust-app` cancelled by `q` during open, and a third `rust-app` with the same
three inputs and quit. It verifies the shell returns on each termination,
12,800 pixels per frame, ready/ready/pressed/ready frame order, shell dirty
state, increasing task generation, task reap, guarded stack, detached surface,
worker memory recovery, exact free heap and progress of both hart timers.
Active sessions also verify frame lease wiping. In the startup-cancelled case,
the frame lease has not been allocated, so no frame wipe is expected.
An initial run incorrectly required that wipe even after cancellation; the
fixture assertion was corrected and the successful run is recorded separately.

This is a bounded three-round automated run, not a long-duration endurance
result. The interactive mode itself is not capped to three sessions. Its
substitute presenter checks each rendered frame against the sample's expected
pixels, and events are printed to UART rather than shown on a framebuffer.
It is restricted to the headless emulator Wasm session profile.

Debug/ReleaseSafe tests, static analysis, 501 Python regressions, the previous
UART fixture cases and the six existing Wasm session cases were rerun. Exact
image identities and logs are retained in the [evidence record](evidence/2026-11-01-wasm-ui-uart-repeat/identity.json).

The normal hardware display service, USB Serial/JTAG, physical keyboard,
scanout and cache behavior, actual camera/network progress, WAMR alignment
adoption, remote CI and Tab5 qualification remain open. Frame rendering and
active-session close remain synchronous.

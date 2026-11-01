# Foreground controller for scheduled Wasm sessions

The headless RV32 fixture now routes its real scheduled Wasm backend through
`src/app/wasm_ui_controller.zig`. The launcher/shell model produces the
synthetic `rust-app` request. The controller takes camera-idle and
display-available decisions from its caller, rejects busy starts, and reserves
the display while opening, cancelling and active.

During open, `q` or Escape requests cancellation; other keys are rejected.
The display remains reserved while the worker finishes open, handles close,
and is reaped. Active `0 → 1 → 0` input and Escape pass through the same
controller. The fixture checks every logical frame pixel and full memory
recovery. Host tests also exercise a contradictory active-backend response:
the controller reports failure while keeping display reserved.

The camera/display availability values in this fixture are synthetic; no
camera driver, actual UI event dispatcher, network service or physical display
is exercised. The production diagnostic UI does not yet call this controller.
Its foreground owner must connect and serialize the real camera/display state,
poll startup, route input, and repaint on stop. First frame and ordinary
active-session cancellation are still synchronous. WAMR device enablement,
alignment decision, physical qualification and remote CI remain open.

Run `sh probes/wamr-native/run-session-emulator.sh` for the six-case
headless matrix. The [evidence identity](evidence/2026-11-01-wasm-ui-controller/identity.json)
binds the exact source and emulator images to the retained logs. Host Debug and
ReleaseSafe tests and the static-analysis RV32 link audits are separate checks.

# Launcher and Wasm worker: headless model integration

The normal launcher/shell input model is now exercised with the scheduled
Wasm worker in the RV32 headless emulator. The fixture initializes the real
`console.session.Model`, feeds synthetic Escape and `rust-app` plus Enter,
and verifies that the resulting command is `rust_app`.

It then starts WAMR asynchronously, decodes synthetic `q` through the
normal serial key decoder, and cancels the opening worker. It waits for close
and task reap before verifying arena and pinned-lease recovery. A later
successful open exercises `0 → 1 → 0`, comparing every presented logical
pixel to the fixture oracle, before cancellation and exact heap recovery.
Existing partial-open, allocation-failure, missing-close-acknowledgement and
six external-input/failure cases continue to run.

This is a test harness that explicitly connects the shell model to the Wasm
API. The production `diagnostic_ui` command dispatcher does not yet select
this backend; there is no real UART shell session, physical display scanout,
or concurrent camera/network service in this test. The Wasm device profile
remains disabled pending the runtime alignment decision and physical work.

Run `sh probes/wamr-native/run-session-emulator.sh` after preparing the pinned
toolchains and emulator bootloader. The [identity record](evidence/2026-11-01-wasm-shell-model/identity.json)
binds the source, logs and candidate hashes. Debug and ReleaseSafe unit tests,
static analysis and six RV32 native ELF audits are separate checks. Remote CI
and Tab5 execution were not performed.

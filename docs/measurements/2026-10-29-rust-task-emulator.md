# Rust application call on a native task: emulator fixture

Date: 2026-10-29. The source is the uncommitted Rust SDK worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. Run
`sh probes/rust-app/run-emulator.sh` with the pinned native toolchain installed.
The ESP32-P4 revision 3 emulator used no PSRAM. The ELF SHA-256 is
`29e4bc0af535583bdf2c0617f0ad49b6fd319f1bb4dbac90f3feeaa40be3c54a`;
the merged image SHA-256 is
`bc5b80673fbb5e4414fe058428c7ba21409131ad8b6923b6501e04cc1811c879`.

CPU0's existing initial lifecycle task checks its task stack and current handle,
then invokes the Rust app and its C ABI drawing adapter on that task's stack.
The task continues through the existing sleep, yield, normal exit and reaping
path. Three progress reports contain `NIHOS_NATIVE_RUST_TASK ran=00000001
reaped=00000003`; the existing full native smoke and image audit also passed.
[Serial log](evidence/2026-10-29-rust-task-emulator/serial.log) and
[image audit](evidence/2026-10-29-rust-task-emulator/image-audit.json) are
retained.

This is a Rust call inside a pre-existing Zig lifecycle task, not a separately
registered Rust task entry, application loader, cancellation-safety proof,
concurrent display owner or physical-device task run. The CPU0 owner alone
uses the non-reentrant scratch fixture. Its output is offscreen.

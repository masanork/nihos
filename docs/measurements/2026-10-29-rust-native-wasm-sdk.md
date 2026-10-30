# Rust task entry and common native/Wasm app: host and emulator

Date: 2026-10-29. Source is the uncommitted SDK worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`.

## Rust native task entry

`sh probes/rust-app/run-emulator.sh` built the native ESP32-P4 revision-3
emulator image and ran it with no PSRAM. The scheduler registered the Rust
`nih_rust_task_entry` as CPU0's initial lifecycle task entry. On that task's
stack the application exercised the existing offscreen drawing fixture, then
used the Rust SDK task calls to reject `sleep(0)` with -2, sleep for at least
three ticks, yield, return 42 through the native trampoline, and be reaped.
The existing task and image-audit checks passed. This uses a fixed qualification
slot, not a general task creation API or a Rust process isolation boundary.

The ELF SHA-256 is `b1164911da08e32701244c6764d9fc5fc673d19d1934c78d2751a1461b7f6858`;
the merged image SHA-256 is `bd64c2ebe68b9138bb20750e4e6f9a06bf153dfe65e579da760bea1958746739`.
[Serial log](evidence/2026-10-29-rust-entry-emulator/serial.log) and
[image audit](evidence/2026-10-29-rust-entry-emulator/image-audit.json)
are retained. Rust and gateway symbols were also verified in the ELF.

## Same app via Wasm imports on host

`sh probes/rust-wasm/run-host.sh` compiles the exact same app source used by the
native fixture for `wasm32-unknown-unknown` and runs it in Node. The test
compares drawing calls for both input states, error propagation and invalid
state, and rejects out-of-range linear memory and invalid UTF-8 in the test
host import. The Wasm SHA-256 is
`86d70cc68709d5499c83b19cf4706452319e9ffb1b934ea14f29bf58d7720e12`.

Node is a host test runtime, not a runtime integrated into nihos. No claim is
made about embedded Wasm feature support, quotas, timeouts, security policy,
device performance or memory use. The Rust panic handler and forced termination
are not production lifecycle policy. Host, emulator and actual Tab5 results
remain distinct.

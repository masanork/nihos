# Rust native app fixture: ESP32-P4 emulator

- Date: 2026-10-29
- Source: worktree based on `c0ff17d5ea6802eed4769a5b588da1735dbfbd32`,
  with the uncommitted SDK and fixture changes accompanying this report.
- Command: `NIHOS_NATIVE_RUST_PROBE=1 sh tools/run-native-smoke.sh integer 0`
- Emulator: esp-emu 0.50.0, ESP32-P4 revision 3 model, PSRAM 0.
- Rust target: `riscv32imac-unknown-none-elf`, soft-float `ilp32`.
- ELF SHA-256: `78ce4c375fdbb50e7395f79ddb8000bfe31c9d868fa869e3a2c5f4e5c38aa1e2`.
- Merged flash image SHA-256: `a3e77b83e770eb6f9951fb3431261dd33ff5e389613ee3234c4a9eaabd6f6a77`.

The ROM and bootloader started the native image. CPU0 called a statically
linked Rust app through the SDK and Zig C ABI adapter into a private 64x16
RGB565 surface. The fixture checked the two state-dependent background colors
and that printable ASCII ink was drawn, and logged
`NIHOS_NATIVE_RUST_APP result=00000000`. The existing image audit and native
smoke checks passed. [Log](evidence/2026-10-29-rust-app-emulator/emulator.log)
and [audit](evidence/2026-10-29-rust-app-emulator/image-audit.json) are retained.
The repeated command with an additional marker assertion is
`sh probes/rust-app/run-emulator.sh`.

This is an offscreen synchronous boot fixture in a trusted address space, not
an application task, interactive input, physical display scanout, hardware
qualification, or proof of Wasm support. The image and ELF hashes identify the
executed build; binaries are in the local build directory, not this report.

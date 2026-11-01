# Rust display-owner candidate

- Date: 2026-10-29; experimental physical-device serial and scanout evidence.
- Base: `c0ff17d5ea6802eed4769a5b588da1735dbfbd32` plus the uncommitted
  worktree changes; build outputs are local and may be overwritten by a rebuild.
- Command: `NIHOS_NATIVE_RUST_DISPLAY=1 NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_CONSOLE=1 NIHOS_NATIVE_CONSOLE_LIVE=1 NIHOS_NATIVE_PSRAM_200=1 NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_DEVICES=0 sh tools/build-native.sh device integer`
- Image SHA-256: `98575b813fb23ae39fee61165d8cbe2f598cd834390e5014ba666c3a2e7762ad`.
- ELF SHA-256: `7bfede2cd5433c1e91a3584f3c2de22df5865e6a9c898b63ae3eb6be0f8a4802`.

The physical-device profile compiled and the native image audit passed. The
host owner test exercises serial-state mapping, the Rust app, RGB565 drawing,
landscape-to-physical rotation, bounds and alias rejection. This does not test
actual serial delivery, PSRAM, cache publication, panel scanout, latency, or
physical interaction. An existing Python process was observed holding the
serial port during this work; no firmware write or reset was performed.
Before any physical capture, coordinate all writers, retain and verify the
exact candidate and check the boot and screen/input evidence for that candidate.

## Physical capture

A subsequent capture used the shared Tab5 firmware-writer lock and an exclusive
serial lease. The device was ESP32-P4 revision 1.3. The existing Flash range
was read and verified before installation. The candidate bootloader, partition
table and application were verified against Flash before capture. The log
contains a single ROM boot, successful Rust boot fixture, display scanout with
backlight on and zero reported display faults, and the serial-driven sequence
`0 -> 1 -> 0`, each followed by `NIHOS_RUST_APP_PRESENT`. The candidate serial
log SHA-256 is `582501a76ad6c5d69f9ff9607edff1a6c29c9601c217eb880c44d3d4e96de4bb`.

After capture the saved Flash range was restored and `verify_flash` matched it.
The saved range also matched the pre-camera-work snapshot in a read-only check
before the test. The backup itself is kept private in the local build directory
and is not part of these repository artifacts.

[Serial log](evidence/2026-10-29-rust-display-physical/serial.log) and
[image audit](evidence/2026-10-29-rust-display-physical/image-audit.json)
are retained. This confirms physical execution and serial-driven publication,
not optical correctness: no user or camera observed the displayed pixels. It
also does not establish touch or keyboard support, application task lifecycle,
Wasm, endurance, or cold-power qualification.

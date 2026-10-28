# Canvas scanout fixture: build-only evidence

Candidate source commit `e598d06` (including the Canvas and native integration).
The opt-in command in [the fixture description](../canvas-native-display.md) built the device/integer qualification profile using Zig 0.17.0 and ESP-IDF 5.4.4.

- Application SHA-256: `7888bbd5ed0963037ddaace7be08322b8fec6791f0d2b971fb3242f1698ed1a5`.
- ELF SHA-256: `37dd78d20e1c07f942bd5ad64fe8af8ae64a031d3a374c44544a1614f44f8bb3`.
- The native image audit passed, including the SRAM runtime and approved ROM/Flash checks.
- The host fixture checked representative red/green pixels, invalid geometry without mutation, and row padding. The full host test suite and static checks passed. An incompatible console-enabled fixture was rejected.

These are build and host observations only. No candidate bytes were installed on the device and no scanout, timing, optical result or physical input is claimed. This fixture neither provides a general present API nor tests card scenes, editing or concurrent rendering. The app and ELF hashes identify the local build; the audit and build artifacts must be retained separately if used for future physical qualification.

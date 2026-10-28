# Canvas scanout fixture: build-only evidence

Candidate source commit `e598d06` (including the Canvas and native integration).
The opt-in command in [the fixture description](../canvas-native-display.md) built the device/integer qualification profile using Zig 0.17.0 and ESP-IDF 5.4.4.

- Application SHA-256: `7888bbd5ed0963037ddaace7be08322b8fec6791f0d2b971fb3242f1698ed1a5`.
- ELF SHA-256: `37dd78d20e1c07f942bd5ad64fe8af8ae64a031d3a374c44544a1614f44f8bb3`.
- The native image audit passed, including the SRAM runtime and approved ROM/Flash checks.
- The host fixture checked representative red/green pixels, invalid geometry without mutation, and row padding. The full host test suite and static checks passed. An incompatible console-enabled fixture was rejected.

These are build and host observations only. No candidate bytes were installed on the device and no scanout, timing, optical result or physical input is claimed. This fixture neither provides a general present API nor tests card scenes, editing or concurrent rendering. The app and ELF hashes identify the local build; the audit and build artifacts must be retained separately if used for future physical qualification.

The initial candidate above reported landscape geometry despite drawing in portrait. Candidate `0c8d290` corrects the diagnostic report to portrait; a fresh device/integer build and image audit passed. Its application SHA-256 is `c27f0865665fe0b558d259dd2ff4e78c3300e50e504db66520075f1a379f58a6` and ELF SHA-256 is `d06d305b1e9ae0a0e3d253b38d432fab6348bb99e32103f67d13ffdf278ef715`. Host Zig tests also passed in ReleaseSafe. This corrected candidate has no physical qualification.

Candidate `c65f597` additionally draws a stripe with the optimized RGB565 row-copy path. Its device/integer image audit passed; application SHA-256 `0848015f55e741eccff177d4b6bb5254dd3b9ef7646dd84023ff4528b47c4600`, ELF SHA-256 `c3dade8fa96e147d9549d049e9d5d6367f1ba9e6acc0849109c169e7c06ee253`. Host pattern checks passed; no physical result or target timing is claimed.

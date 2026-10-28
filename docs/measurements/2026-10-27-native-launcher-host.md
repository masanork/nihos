# Native launcher and shell — host/build checkpoint

Base: `8cd0076` (`codex/native-console`), isolated worktree/branch
`nihos-native-launcher` / `codex/native-launcher`.

[Behaviour, controls and build instructions](../native-session.md).
[Source stamp, toolchain, checks and artifact hashes](2026-10-27-native-launcher-host.json).

The live integer normal-boot path now queues a launcher after boot health/READY,
finishes the milestone-driven splash, and hands input/display ownership to the
session. Escape opens the shell; `exit` returns. The log viewer, CPU0 memory
counters and published per-hart runtime counters are reachable from both the
launcher and command dispatch. Boot diagnostics and fatal CPU0 fallback retain
their own journal; shell output uses a separate bounded ring in the display
reservation. Serial prompts are emitted after view-change telemetry.

Validation completed:

- 219 Zig tests in Debug and ReleaseSafe, including seven new session/input
  tests for real event sequences, bounded editing, history wrap and geometry.
- 157 Python tests.
- Formatting, ZLint and ShellCheck; six default device/emulator native ELF
  links and their image audits through the static-analysis script.
- Eight headless normal-boot emulator cases: READY/idle at four PSRAM sizes,
  a delayed peer, and three expected missing-health timeouts. The source stamp
  in the final emulator report matches the frozen source files.
- Live-console device ELF audits for the 78x43 basic-light face and the 80x22
  JetBrains face. The small-face candidate is also packaged as app/merged Flash
  binaries. SRAM heap reservations are 70,336 and 71,232 bytes respectively,
  both above the unchanged 48 KiB linker minimum.
- Launcher and shell/help previews through the production grid/raster,
  visually inspected on the host. The previews are not photographs of Tab5.

Two inherited static-analysis findings were corrected while running the gate:
the MPLL host model retains its eight-bit register index using a direct `u8`
annotation, and adjacent build-option appends use one ShellCheck-compliant
redirect block. Neither changes device clock configuration or build options.

Artifacts remain under `build/native-device/`, `build/launcher-device-large/`,
`build/normal-boot-smoke/` and `build/console-preview/` in this worktree.
Their digests are recorded in the JSON receipt. No device was opened, reset or
flashed. The display-backed session has not executed in the headless emulator.
Physical boot, real typing, repeated view changes, diagnostic fallback, display
errors and stack guards still need checking on this exact candidate.

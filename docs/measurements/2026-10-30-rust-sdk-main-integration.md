# Rust SDK consolidation on current main

This is local host and ESP32-P4 emulator evidence. No integrated image in this
report was run on Tab5. Remote CI and merge have not been performed.

The experiment from `c0ff17d5ea6802eed4769a5b588da1735dbfbd32` was copied into
an isolated worktree and ported onto main
`3d21dcb1b798c745c084cb9d1d74fddbd231747f`. All 427 original changed/added
source-file hashes still match the pre-copy inventory; its worktree remains
uncommitted and unchanged. The original main worktree was not edited. Concurrent
xy host files there were left untouched.

Review the [landing checklist](../planning/rust-sdk-landing.md) for the finite
remaining scope. SDK, admission/recovery and runtime are separate commits.
An additional isolated commit initializes main's new xy/font default buffers
and removes a redundant cast so the existing lint gate passes.

## Port and verification

The port retains main's optimized rectangle fill, PMP and memory/storage
profiles, camera overlay and xy changes. It places the Rust boot probe in the
current CRT path, keeps Rust display scratch exclusive of normal storage, and
uses main's `esptool --use_segments` image construction. The test module digest
is derived from the current build rather than copied from an old report.
WAMR source is pinned and unmodified; native output includes its license.

A no-input ROM console poll exposed CPU1's timer clock-refresh rejection while
CPU0 was still in the boot-only WAMR fixture. Temporary branch diagnostics
identified refresh rejection, rather than surface/arena corruption. The fixture
now keeps CPU1 before task admission until WAMR cleanup succeeds. The successful
path then releases CPU1 and completes the existing dual-hart/timer soak.
This establishes the boot fixture's ownership order; blocking ROM polling
alongside a running scheduler remains unqualified for normal application use.

The following checks passed:

- `zig build test` in Debug and ReleaseSafe, including the focused 20-test app
  admission suite. Incremental build summaries count only newly executed tests.
- `tools/run-static-analysis.sh`: formatting, zero lint errors/warnings,
  shellcheck, memory/checkpoint contracts and six audited RV32 native links.
- `tools/run-rust-sdk-host.sh`: native FFI/Wasm sample parity, pixel/rotation
  checks, RV32 soft-float link, WAMR bounds and allocation-fault recovery,
  signed-journal execution and 22-process recovery/rejection checks.
- Native Rust task emulator: execution, task calls, reaping, 300-round SMP/timer
  smoke. The unchanged default-off profile also completes its 300-round smoke.
- Signed WAMR emulator: Ready/Pressed/Ready, UART `0x10q`, all 12,800 pixels plus
  padding/guards, denied-import invariance, owner detach and arena recovery.
- The same Wasm candidate passes six UART failure cases: no input, partial
  input, early quit, overflow, wrong order and an extra frame. All show exact
  expected status/counters and cleanup before the expected fixture failure.
- WAMR ELF audit: zero undefined symbols, journal-only payload source, correct
  Flash spans. `actionlint` accepts the new workflow.

Runtime native code is commit `dbed2ddb19095e777b3950fe2ae7483c5f7b9b21`.
Host tests/static checks also include the isolated xy/font lint repair in
`e6a0b1f`. Tools are Zig 0.17.0, Rust 1.98.1, WAMR 2.4.5 at
`25bd7eb63e828e4bd242cc9b38d260b4b31c6605`, ESP-IDF 5.4.4 and ESP-EMU 0.50.0.

## Candidate identity and limits

The 1,211-byte Wasm SHA-256 is
`b790c66619c1061af10ea0aa9ae888feec397f4c5d99a4523f2c2031d244abe2`.
The stripped WAMR ELF is
`33cdd84918e38f07246d09b7881784ec6a75cbe5d15c60f90854614995cbe8ae`;
the merged Flash image is
`4a21e7f08f848d73e8312e186c4ce5101f570536c8d266ca11e78b0402edab0b`.
The requested owner lease remains 488 KiB and private-stack high-water 23,692
bytes. These are emulator measurements; they do not establish physical memory,
latency or scanout behavior.

[Retained evidence](evidence/2026-10-30-rust-sdk-main-integration/identity.json)
contains candidate identities, original experiment hashes, logs, smoke/audit
reports and the UART matrix. Historical reports retain their original bytes and
qualification limits. This candidate still has no normal app session/launcher,
physical Wasm presentation/input, protected counter, native persistent writer
or physical power-loss qualification. The WAMR alignment adoption decision
remains open. The experimental options remain disabled in ordinary builds.

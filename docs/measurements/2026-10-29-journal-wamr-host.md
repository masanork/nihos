# Rust application from journal recovery to WAMR

The later [2026-10-30 buffer path](2026-10-30-journal-wamr-buffer-host.md) adds
same-process admission and runtime loading without an exported payload file.
The file-handoff measurements below remain a separate runner regression.

Date: 2026-10-29. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. Host execution on macOS.

`probes/wamr-native/run-journal-wamr-host.sh` builds the real Rust application
through `sdk/rust/nihos-app`, fixes its Wasm memory at one page, and produces a
1,211-byte Wasm. The deterministic test packager signs a 1,419-byte sequence-1
package. The existing media builder installs it into an 8,480-byte package
journal and emits the root-signed trust journal, counter fixture and root key.
That builder process exits before the recovery command starts.

`boot-file-export.zig` shares the positional file adapter with the process/crash
probes. Its 4,096-byte package workspace is selected by the importing root;
the existing 512-byte process fixtures retain their original geometry. It
reopens all files, verifies root/trust, reconstructs package keys and rollback
state, and calls the same OS boot coordinator. Only a successful admission with
the expected sequence opens the runner-owned payload output path.

The runner compares the exported payload against the Rust build bytes, then
passes only that recovered file to the pinned WAMR 2.4.5 host runtime. WAMR
asserts the `Ready` and `Pressed` drawing states, host-error propagation,
invalid-state rejection, nested and wide-value calls, invalid guest range trap,
bad-text rejection, the 10,000-instruction spin limit, and failed memory growth
past the fixed page. Sixteen additional trap/destroy cycles restore the runtime
pool to its baseline.

Observed records:

```text
NIHOS_BOOT_EXPORT trust_epoch=1 sequence=1 package_bytes=1419 wasm_bytes=1211 pid=<recovery-pid>
WAMR fixed-memory growth rejection: ok
Wasm linear memory range=0..65536 bytes
WAMR pool total=261728 free=239240 highmark=22488 bytes
WAMR 16 trap/destroy cycles returned runtime pool to baseline: ok
WAMR classic interpreter Rust app and bounds: ok
```

The original and recovered Wasm SHA-256 both equal
`4b226889e627af9ce64ee0b5529d1418cd60afc80944d315ed2b64026dde1710`.
The package SHA-256 is
`5958b4dac8881c0ffd7cc3d820072d66afe0b99bb9ed6c535ccb6a1df7be2801`.
These match the native emulator's fixed Rust application and signed package.

Two negative controls run the recovery command again: a mutated package journal
fails with `ActivePackageInvalid`, and an all-zero root key fails with
`InvalidActiveSnapshot`. Neither creates its designated payload file, and the
runtime is invoked only on the positively admitted file. The runner checks the
specific errors as well as file absence. Existing 22-process crash, corruption,
revocation and recovery probes also pass after the adapter was shared.

Retained [admission log](evidence/2026-10-29-journal-wamr-host/admission.log),
[runtime log](evidence/2026-10-29-journal-wamr-host/runtime.log),
[package rejection](evidence/2026-10-29-journal-wamr-host/rejected-corrupt.log),
[root rejection](evidence/2026-10-29-journal-wamr-host/rejected-root.log), and
[artifact hashes](evidence/2026-10-29-journal-wamr-host/artifacts-sha256.txt)
bind the build inputs and recovered payload.
The shared-adapter regression logs are retained for the
[ten-phase flow](evidence/2026-10-29-journal-wamr-host/process-regression.log),
[kill matrix](evidence/2026-10-29-journal-wamr-host/kill-matrix-regression.log), and
[corruption controls](evidence/2026-10-29-journal-wamr-host/corruption-regression.log).

This composes journal recovery with execution of the actual Rust app on a host.
Media are build-generated test files, roots use public test material, and the
counter is an ordinary file. The exported-file handoff belongs exclusively to
this runner; it does not implement a production atomic admission-to-execution
interface or protect against another process replacing the handoff file.
The separate WAMR host alignment/sanitizer findings remain open for general
configurations. Native runtime service integration, qualified persistent media,
protected counters and physical Tab5 measurements retain their existing gates.

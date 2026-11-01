# Native Wasm owner dispatches bounded input and frames

The later [external UART probe](2026-10-30-wamr-native-uart.md) adds actual
emulated console RX, three more frames, quit processing and timeout cleanup.

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. Executed on RV32IMAC/ILP32 in the
ESP32-P4 emulator, using the existing private RGB565 offscreen surface.

The native WAMR owner now stores one selected state, a successful-frame counter
and a synchronous call-scope flag. Trusted owner input accepts only ASCII `0`
and `1`, matching the existing native Rust sample's two-state model. It changes
the next frame's scalar input without invoking the guest or drawing. The render
entry passes that state to the existing Rust `nih_rust_app_frame` export and
increments its frame counter only after successful completion.

All ordinary native fixture guest calls enter a synchronous owner call scope.
Graphics imports require this scope in addition to the previously implemented
instance identity, active state and admitted graphics rights. The scope clears
when the guest returns or traps. Diagnostic trap/text/spin exports use the same
entry/exit guard, while explicit negative tests deliberately bypass it to test
the import boundary. Before the four owner-denial probes, a diagnostic scope is
opened so missing rights, inactive owner, mismatched instance and detached owner
are tested independently of the closed-scope condition.

The second instance receives the synthetic input sequence `0 -> 1 -> 0`. Each
input is followed by one render call and a check of background and first-glyph
pixels, yielding `Ready -> Pressed -> Ready`. These three managed frames are
separate from the first instance's diagnostic frame/error tests.

The runner and native boot require:

```text
NIHOS_NATIVE_WAMR_OWNER checks=0000000f released=00000001 services=00000001
NIHOS_NATIVE_WAMR_SURFACE checks=0000007f
NIHOS_NATIVE_WAMR_EVENTS checks=0000001f frames=00000003
```

| Event-check bit | Verified behavior |
| ---: | --- |
| 1 | Three successful frames follow input `0`, `1`, `0` |
| 2 | `x` returns -1 without changing selected state, frame count, calls or checksum |
| 4 | Simulated open/busy scope rejects input and render with -3, retaining the open scope |
| 8 | Stopped owner rejects input and render with -5 without changing frame count, calls or checksum |
| 16 | A guest frame call outside the owner scope reaches the import and is denied before drawing |

The busy test sets the scope flag in the fixture; it does not create concurrent
or interrupt-driven re-entry. The stop test keeps the native instance and exec
environment alive while marking its owner inactive, then performs ordinary
destruction. It never dereferences a destroyed runtime object. Teardown clears
the scope and detaches each context before instance destruction.

The input sequence adds one successful frame to the earlier two-frame second
instance, bringing accepted host drawing calls from nine to eleven. The final
surface check now verifies Ready rather than Pressed. Existing permission,
surface padding/guard, invalid-range, bad-text and 10,000-instruction-limit tests
still pass. Both buddy arenas recover completely. Three 100-round SMP markers,
the 300-round soak and the final integer marker follow cleanup.

Private-stack high-water is 25,724 bytes inside the existing 64 KiB stack and
456 KiB total lease. Requested runtime/linear peaks remain 19,737/65,536 bytes.
The image audit reports 252,560 Flash text bytes, 35,963 read-only bytes, a
journal-only load source and zero undefined symbols.

Canonical ELF SHA-256:
`cd8bdc504cf3632505df5edc2bd2ba40526553a5f09a3a3f0644788bd323e3a1`.
Merged flash SHA-256:
`1d5fd036a835833d7e27df325de3429bf896387dd19982fa8244769ba76529ca`.
The Rust Wasm and signed-package hashes retain their previous values.

Retained [emulator log](evidence/2026-10-30-wamr-native-events/emulator.log),
[build log](evidence/2026-10-30-wamr-native-events/build.log),
[image audit](evidence/2026-10-30-wamr-native-events/image-audit-wamr.json),
[candidate hashes](evidence/2026-10-30-wamr-native-events/candidate-sha256.txt),
[media hashes](evidence/2026-10-30-wamr-native-events/boot-media-sha256.txt), and
[source hashes](evidence/2026-10-30-wamr-native-events/source-sha256.txt)
bind this candidate. `probes/wamr-native/run-emulator.sh` executes the checks.

This remains one synchronous CPU0 runtime owner with synthetic scalar events.
No guest input service or new SDK ABI is introduced. Serial/touch/keyboard event
drivers, queues/coalescing policy, live display presentation, cross-hart
serialization, asynchronous cancellation and physical Tab5 qualification remain
later integration work.

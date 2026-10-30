# Native UART failure matrix and resource cleanup

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`.

`probes/wamr-native/run-uart-matrix.py` runs six UART failure cases against the
unchanged native image from the preceding external-input fixture. The script
injects bytes after the firmware's anchored READY marker, checks exact received,
rendered and rejected counts, and requires the expected fixture status. Every
case must detach owners/surface, preserve surface guards, recover both buddy
arenas and stop before the normal completion marker.

| Case | Injected ASCII | Fixture status | Bytes received | UART frames | Unsupported bytes processed | Total drawing calls |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| No input | none | 42: timeout | 0 | 0 | 0 | 11 |
| Input stops mid-sequence | `0` | 42: timeout | 1 | 1 | 0 | 13 |
| Quit before frames | `q` | 44: sequence check | 1 | 0 | 0 | 11 |
| Receive limit exceeded | seventeen `x` bytes | 43: byte limit | 17 | 0 | 16 | 11 |
| Wrong first state | `1` | 44: sequence check | 1 | 0 | 0 | 11 |
| Fourth frame requested | `0x100q` | 44: sequence check | 5 | 3 | 1 | 17 |

The 17th received byte triggers the limit before dispatch, so at most 16 bytes
are processed. In the final case, the fourth state byte triggers the three-frame
limit before another render; the trailing `q` remains unread. Valid state bytes
can update the private selection before sequence validation fails, but they do
not invoke an extra guest frame. Unsupported `x` processing retains the earlier
state/checksum invariants. Timeout remains bounded by the existing 12,000,000
cycle delta, without a new wall-time claim.

Every negative run reports `cycle_recovered=1`, `recovered=1`, owner
`released=1`, and surface mask 0x5f. That surface mask includes successful adapter
detach and byte-checked guards; the final-success surface bit is deliberately
absent. `NIHOS_NATIVE_FAIL WAMR fixture` is the expected diagnostic after cleanup,
and no negative case emits `NIHOS_NATIVE_FP_PASS`. The successful input sequence
from the preceding run remains bound to the same ELF/flash hashes.

The matrix verifies both files' SHA-256 after each emulator process. Canonical
ELF SHA-256 remains
`06ca8d8b5c01e532f17cd08e7b405b59c66f9269bea936e88365e5edb8f8718e`;
merged flash SHA-256 remains
`b08977cc0e3c4cab03f8c406f7595f4b47805eaec6f39f6dbf4e6946fc72d107`.
No firmware change was needed for these additional failure paths.

Run independently after building the candidate:

```sh
python3 probes/wamr-native/run-uart-matrix.py /path/to/esp-emu build/native-emulator-wasm
```

The full `run-emulator.sh` now invokes this matrix in place of its earlier
single no-input check. Retained [matrix manifest](evidence/2026-10-30-wamr-native-uart-matrix/uart-matrix.json),
[no-input log](evidence/2026-10-30-wamr-native-uart-matrix/emulator-noinput.log),
[partial-sequence log](evidence/2026-10-30-wamr-native-uart-matrix/emulator-partial.log),
[early-quit log](evidence/2026-10-30-wamr-native-uart-matrix/emulator-early-quit.log),
[overflow log](evidence/2026-10-30-wamr-native-uart-matrix/emulator-overflow.log),
[wrong-order log](evidence/2026-10-30-wamr-native-uart-matrix/emulator-wrong-order.log),
[extra-frame log](evidence/2026-10-30-wamr-native-uart-matrix/emulator-extra-frame.log),
[successful-run log](evidence/2026-10-30-wamr-native-uart-matrix/emulator.log), and
[source hashes](evidence/2026-10-30-wamr-native-uart-matrix/source-sha256.txt)
identify inputs, observations and validation code. Each emulator's stderr is
retained alongside its UART log.

These are finite acceptance-probe failures on an emulated console. They do not
establish general event-queue semantics, hardware UART error handling, physical
input/output, asynchronous cancellation or persistent-storage qualification.

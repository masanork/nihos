# External UART input drives native Rust Wasm frames

The later [full-surface run](2026-10-30-wamr-native-full-surface.md) retains the
UART path while adding a separate 32 KiB surface segment and all-pixel checks.
It records the updated lease, cycle budget and candidate identity.

The [subsequent failure matrix](2026-10-30-wamr-native-uart-matrix.md) verifies
partial input, early quit, overflow, order and frame-limit failures against this
same candidate, with complete cleanup in every case.

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. ESP32-P4 RV32IMAC/ILP32 emulator
execution with the existing private RGB565 offscreen surface.

The native owner now emits `NIHOS_WAMR_UART_READY` after the earlier synthetic
event checks and polls the ROM console receive function. The pinned ESP-IDF
v5.4.4 P4 ROM table maps nonblocking `uart_rx_one_char` to `0x4fc00060`; its API
returns 0 for a received byte and 1 for no data/failure. The fixture links this
ROM ABI only in the opt-in Wasm profile. It does not initialize a new peripheral
or link an ESP-IDF driver. The live diagnostic UI's separate USB Serial/JTAG RX
path is unchanged.

The emulator runner injects the five bytes `0x10q` only after observing READY.
The bytes are ASCII `0`, `x`, `1`, `0`, `q`, not a hexadecimal integer. The
actual emulated console receive path feeds these bytes to the native owner:

| Byte | Owner action |
| --- | --- |
| `0` | Select Ready, call Rust Wasm, check background/R pixels |
| `x` | Reject without changing state, call count or frame checksum |
| `1` | Select Pressed, render, check background/P pixels |
| `0` | Select Ready, render, check pixels |
| `q` | Stop the owner without forwarding a guest event |

After `q`, both input and render calls must return -5 while the instance remains
alive, with unchanged frame checksum and call count. Ordinary teardown then
detaches the context and surface, destroys the instance/runtime, recovers both
buddy arenas and releases the lease. Normal execution reports:

```text
NIHOS_NATIVE_WAMR_OWNER checks=0000000f released=00000001 services=00000001
NIHOS_NATIVE_WAMR_SURFACE checks=0000007f
NIHOS_NATIVE_WAMR_EVENTS checks=0000001f frames=00000003
NIHOS_NATIVE_WAMR_UART status=00000001 bytes=00000005 frames=00000003 rejected=00000001
```

The EVENTS frame count remains the three earlier synthetic frames. The UART
record counts three additional externally driven frames, for six managed frames
on the second instance. Together with the first instance's diagnostic calls,
there are 17 accepted drawing imports. The ordinary SMP/timer tail still emits
three 100-round markers, a 300-round soak and the integer completion marker.

Receive is bounded by 16 bytes and a wrapping-safe 12,000,000-cycle delta from
READY transmission completion. This is a cycle bound, not a physical wall-time
claim. This finite acceptance probe requires the stated three-frame sequence
and one rejected byte before `q`; it is not a general console application.

The same candidate also runs without injection. The owner reaches the receive
limit, returns fixture status 42, and executes teardown. The runner requires:

```text
NIHOS_NATIVE_WAMR ... status=0000002a ... cycle_recovered=00000001 recovered=00000001 ...
NIHOS_NATIVE_WAMR_OWNER checks=0000000f released=00000001 services=00000001
NIHOS_NATIVE_WAMR_UART status=00000002 bytes=00000000 frames=00000000 rejected=00000000
NIHOS_NATIVE_FAIL WAMR fixture
```

This FAIL is the expected negative fixture outcome: cleanup has completed before
the boot diagnostic reports the timeout. The no-input run must not emit the
normal completion marker. Its partial surface/event masks do not count checks
that only execute after a successful UART sequence.

Private-stack high-water is 25,740 bytes, still inside the 64 KiB stack and
456 KiB lease. Requested runtime/linear peaks remain 19,737/65,536 bytes. The
audit reports 252,944 Flash text bytes, 35,995 read-only bytes and zero undefined
symbols. Wasm and both signed packages retain their previous hashes.

Canonical ELF SHA-256:
`06ca8d8b5c01e532f17cd08e7b405b59c66f9269bea936e88365e5edb8f8718e`.
Merged flash SHA-256:
`b08977cc0e3c4cab03f8c406f7595f4b47805eaec6f39f6dbf4e6946fc72d107`.

The first log-validator attempt counted the emulator's own trigger notification
as another READY marker. The runtime sequence itself completed; the validator
was corrected to count only an anchored firmware line. That attempt is retained
as [initial validator log](evidence/2026-10-30-wamr-native-uart/emulator-first-trigger-validation.log).
Current evidence includes [normal UART run](evidence/2026-10-30-wamr-native-uart/emulator.log),
[no-input timeout run](evidence/2026-10-30-wamr-native-uart/emulator-noinput.log),
[build log](evidence/2026-10-30-wamr-native-uart/build.log),
[image audit](evidence/2026-10-30-wamr-native-uart/image-audit-wamr.json),
[candidate hashes](evidence/2026-10-30-wamr-native-uart/candidate-sha256.txt), and
[source hashes](evidence/2026-10-30-wamr-native-uart/source-sha256.txt).
Run both paths with `probes/wamr-native/run-emulator.sh`.

This advances from an in-process event array to externally injected UART RX on
the emulator. Touch/keyboard hardware, USB-console integration, general input
queues, display scanout, asynchronous cancellation and physical Tab5 validation
retain their existing gates. The package journals and counter remain private
test fixtures without native persistent Flash qualification.

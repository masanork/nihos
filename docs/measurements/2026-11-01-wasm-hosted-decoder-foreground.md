# ESP-Hosted frame decoding alongside Wasm

The headless repeat fixture now runs the same `hosted.wire.Decoder` used by the
native network service, with synthetic bytes fed in eight-byte pieces from the
foreground loop. It alternates a valid 16-byte Hosted frame and a frame with a
corrupted payload but unchanged checksum. The first must produce the expected
interface and payload; the second must return `Checksum` and is followed by a
decoder reset. The runner independently checks expected frame counts, rejected
frames and zero unexpected errors. It also requires decoded events during an
active Wasm session. The prior bounded synthetic hash/sample workload and
pixel, cancellation, resource-recovery and prompt checks remain enabled.

One RV32 emulator boot produced the following results:

| Round | Scenario | Valid frames | Corrupt frames rejected | Events while active | Maximum foreground gap |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | active then quit | 29 | 29 | 4 | 20,054 us |
| 2 | cancel during open | 28 | 27 | 0 | 20,002 us |
| 3 | active then quit | 29 | 29 | 4 | 20,000 us |

The partially fed final frame in round 2 explains the unequal counts. Per-round
synchronous worker request measurements for active sessions were 820–821 us
for the maximum render/input request and 1,446–1,448 us for close. They cover
request submission through acknowledgement, not the entire UI service or
presentation. The maximum foreground gap is a separate measurement. All are
emulated-time observations for this input sequence, not physical timing or
worst-case guarantees. No foreground service runs while a synchronous UI
request is blocked.

The test uses the actual parser but does not run the complete network service,
C6, SDIO, Wi-Fi, DHCP, camera, or a remote peer. It does not establish network
interoperability or physical display/cache behavior. WAMR alignment and exact
Tab5 qualification remain device-profile gates.

Debug and ReleaseSafe tests, static analysis, 501 Python regressions, UART
fixture cases, the six Wasm session cases, and three native-session cases were
rerun. Stripped UI and session regression ELFs rebuilt from the final source
match the tested binaries byte for byte. The [runner](../../probes/wamr-native/run-repeat-emulator.sh) and
[evidence record](evidence/2026-11-01-wasm-hosted-decoder-foreground/identity.json)
retain logs and image identities.

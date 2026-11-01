# Hosted station state alongside a Wasm session

The headless repeat fixture now exercises the existing `hosted_station.Client`
from the foreground loop. A synthetic peer supplies the ESP-Hosted private
initialization event and version responses. The client runs in the disabled
join configuration: it emits the capability and version requests, ignores a
validly encoded response bearing a previous nonzero UID, accepts the matching
response with version `1.4.1`, and reaches `done` with no DHCP client, no
connection and no queued transmission. The fixture seeds the UID counter to
represent an earlier transaction; it does not reproduce a prior radio session.
The peer's reply envelope is built with the same in-tree wire encoder, so this
is not independent wire-interoperability evidence.

Each state-machine step occurs on a different foreground turn. The previous
synthetic fragmented Hosted decoder workload, corrupted-frame rejection,
pixel oracle and session recovery checks remain enabled. The repeat runner
checks completed exchanges, ignored stale replies, phase-specific progress,
zero fixture errors and a prompt after each session. In one RV32 emulator boot:

| Round | Scenario | Exchanges completed | Old UID responses ignored | Completed while opening | Completed while cancelling | Completed while active |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | active then quit | 23 | 23 | 21 | 0 | 2 |
| 2 | cancel during open | 22 | 22 | 0 | 22 | 0 |
| 3 | active then quit | 23 | 23 | 21 | 0 | 2 |

The first attempt accidentally used reserved UID zero for the stale response;
`wire.request` correctly rejected it before the client received it. The final
fixture instead uses two nonzero UIDs. The initial failed test log is retained.

The maximum measured foreground gap was 20,054 us, and active-session maximum
render/input worker request and close request times were 818 us and 1,445 us,
respectively. These are emulator observations for this bounded workload, not
physical timing or worst-case bounds. Frame rendering and active close remain
synchronous and block foreground service during those requests.

Debug/ReleaseSafe, static analysis, 501 Python regressions, prior UART and
Wasm session cases, and native Rust session cases were rerun. The stripped
UART and Wasm regression ELFs rebuilt from the final source match the tested
binaries. The [runner](../../probes/wamr-native/run-repeat-emulator.sh) and
[evidence record](evidence/2026-11-01-wasm-hosted-station-foreground/identity.json)
retain exact image identities and logs. The state-machine fixture sends no real
C6, SDIO or Wi-Fi traffic; it does not test association, DHCP, LAN/remote-peer
interoperability, scanout/cache, or Tab5. WAMR alignment remains open.

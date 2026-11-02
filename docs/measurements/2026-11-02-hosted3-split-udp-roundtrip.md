# Hosted 3 Network Split: single 1200-byte UDP round trip

On 2026-11-02 JST, one Tab5 with C6 reporting Hosted 3.0.10 ran the exclusive
CPU0 Network Split diagnostic. The exact P4 source was clean commit
`270e58763fdd16c3cab5c9b38137b926d2a4c2f3`; app SHA-256
`66c8652d5fb59e0d04ce72e908bd2769d127fa7329561d7d152206949be3a490`.
The SRAM image audit reported 16,960 bytes of unused primary heap, above the
16 KiB fixture floor. The fixture used the C6-owned DHCP snapshot and P4 UDP
source port 49152, inside the pinned C6's configured P4 range. It sent a
single 1,254-byte Hosted frame carrying a 1,200-byte UDP payload.

The independently bound Mac peer received one fully matching payload from the
P4-reported IP and port 49152, SHA-256
`159b51633f1b15bf03362c09e230dc0fab18819b624f445e279959e4452b688c`, and
reported echoing 1,200 bytes. The P4 reported one complete send and one
matching long echo, with zero error and Hosted version 3.0.10. The peer and P4
observations therefore establish one bounded round trip, not a loss rate,
reliable streaming, a generic UDP socket, QUIC, TLS, or iroh interoperability.
The C6 version is self-reported; C6 flash was not read back or rewritten.

The P4 writer lock and exclusive serial lease were held. Its complete 16 MiB
flash was backed up and verified before installation, then restored and
verified against SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The restored application boot was not captured. Mac Wi-Fi IP and MAC were
checked independently immediately before the test. The P4 raw capture and
peer capture hashes are in the [redacted evidence](evidence/2026-11-02-hosted3-split-udp-roundtrip.json);
raw files remain private in `/private/tmp/nihos-hosted3-split-udp-physical-20261102-v4/`.

The initial run used source port 44444, and showed peer receipt and an echo
send without P4 receipt; see [the first observation](2026-11-02-hosted3-split-udp-first.md).
The first host-port attempt stopped at power enable before any UDP; see
[the failure record](2026-11-02-hosted3-split-udp-host-port-first.md).
The successful run supports the port-routing explanation, but no independent
C6 packet-routing trace was captured. The diagnostic is isolated from normal
networking; multiple sends, backpressure, reconnect, long-duration use and
coexistence with UI/storage remain separate gates.

# Synthetic DHCP renewal and expiry alongside Wasm

The headless foreground fixture extends its synthetic Hosted/DHCP exchange to
cover a complete IPv4 lease lifecycle while the Wasm UI session starts, runs,
and cancels. After the independent Offer/ACK establishes a lease, the fixture
advances a synthetic client clock to just before T1, then to T1. It checks the
renewal request is unicast to the selected server with a new transaction ID.
The previous transaction's valid ACK must leave the lease in renewal; an ACK
with the new ID must return it to bound and restart the expiration clock.

The fixture then advances to just before the renewed lease expires. It requires
an unsent outbound request to be retained while the lease still exists. At
expiry, the real Hosted client must return `LeaseExpired`, discard the queued
request and revoke the IPv4 client. IPv6 is disabled in this fixture. Each operation takes
one foreground turn. The exchange also retains its old-UID RPC, corrupt DHCP
ACK, fragmented Hosted decoder, pixel oracle and task/memory recovery checks.

The synthetic renewal ACK is derived from the independently generated Scapy
ACK by changing its transaction ID and recomputing the UDP checksum. A Python
regression regenerates it in a temporary directory, checks it against the
committed bytes, verifies the checksum independently and verifies no unrelated
bytes changed. See the [fixture provenance](../../src/net/fixtures/README.md).
RPC replies still use the in-tree encoder, and the client receives synthetic
`Frame` values directly. No C6 or DHCP server participates.

| Round | Scenario | Renewals accepted | Old ACKs ignored | Expirations | Expirations while active |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | active then quit | 6 | 6 | 5 | 1 |
| 2 | cancel during open | 4 | 4 | 4 | 0 |
| 3 | active then quit | 6 | 6 | 5 | 1 |

The first and third rounds end after the sixth renewal but before its expiry;
the cancelled round completes four lifecycles. Maximum observed foreground gap
was 20,054 us, render/input request was 817 us and close request was 1,447 us
in this emulator. These are observations for this workload, not real-time or
physical latency guarantees. The client clock jumps across its 3,600-second
lease on successive loop turns; no actual hour-long wait is claimed. The UI's
render and close requests remain synchronous and block foreground service.

Debug/ReleaseSafe, static analysis, Python regression, previous UART, six Wasm
session cases and three native-session cases were rerun. See the
[runner](../../probes/wamr-native/run-repeat-emulator.sh) and
[evidence record](evidence/2026-11-01-wasm-dhcp-lease-lifetime/identity.json).
C6, SDIO, Wi-Fi, a real DHCP server, camera and display scanout remain
unverified; WAMR alignment and exact Tab5 qualification remain open.

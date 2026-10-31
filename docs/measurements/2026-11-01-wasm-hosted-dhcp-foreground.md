# Synthetic Hosted and DHCP exchange alongside Wasm

The headless repeat fixture drives the existing `hosted_station.Client` through
synthetic Hosted initialization, version negotiation, Wi-Fi setup RPCs,
association event, DHCP Discover/Offer/Request/ACK, and a bound IPv4 lease.
Each of the 17 fixture steps takes a separate foreground turn. The `.saved` join
mode is a state-machine input; no credential or real radio is involved.

The DHCP Offer and ACK are the independent Scapy-generated packets in
[`src/net/fixtures`](../../src/net/fixtures/README.md). They contain the
synthetic MAC `02:03:04:05:06:07`, transaction ID `0x12345678`, and address
`192.0.2.12`. The fixture uses a fixed synthetic timestamp to produce that
transaction ID. An intentionally corrupted ACK must leave the client unbound
and increment its malformed packet count; the original ACK must then produce
`192.0.2.12`, gateway `192.0.2.1` and a 3,600-second lease. Lease renewal,
expiry and real-time timeout behavior are not exercised here. RPC peer replies
are synthesized using the in-tree encoder, not an independent C6 peer. The
client receives synthetic `Frame` values directly; the concurrent fragmented
Hosted decoder fixture is a separate path.

One emulator boot ran active, startup-cancellation and active sessions. Every
round also checks mismatched UID handling, the prior pixel oracle, Hosted
checksum rejection, foreground work integrity, prompt return and memory/task
recovery:

| Round | Scenario | Leases acquired | Bad ACKs rejected | Old UID responses ignored | Leases completed while active |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | active then quit | 8 | 8 | 8 | 2 |
| 2 | cancel during open | 6 | 6 | 7 | 0 |
| 3 | active then quit | 8 | 8 | 8 | 2 |

Round 2 ended partway through its next exchange, after the stale UID response;
the synthetic network fixture is reset on the next round. The largest observed
foreground gap was 20,054 us. Active render/input requests took at most 820 us
and active close requests at most 1,447 us in emulator time. These are bounded
observations for the stated synthetic workload, not device measurements or
worst-case guarantees. The UI request remains synchronous, so no foreground
service runs while it waits.

Debug/ReleaseSafe tests, static analysis, 501 Python regressions, the previous
UART tests, six Wasm session cases and three native-session cases were rerun.
The [runner](../../probes/wamr-native/run-repeat-emulator.sh) and
[evidence](evidence/2026-11-01-wasm-hosted-dhcp-foreground/identity.json)
retain exact candidate hashes, logs and packet results.

There is no physical C6, SDIO, Wi-Fi association, DHCP server, LAN, scanout or
Tab5 in this test. It does not establish real transport interoperability or
camera/network/display coexistence. WAMR alignment and device qualification
remain open before a device Wasm profile.

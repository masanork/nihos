# Hosted 3 Network Split UDP diagnostic boundary

The C6 Network Split service owns DHCP and DNS. The factory long-UDP fixture
in `probes/hosted-long-send/` instead starts a P4 DHCP client and services ARP
using that lease; it must not be reused unchanged with the C6-owned address.
The existing bounded time exchange acquires the C6 snapshot and correlates it
to a generation, but is not a UDP transport.

`src/net/hosted_split_udp_probe.zig` is an isolated host-testable packet and
lease boundary for an explicit same-subnet peer. It captures a complete
`hosted_network_split.State` generation and snapshot, validates local/peer
addresses, and rejects preparation or echo processing after invalidation or a
changed snapshot. A caller must hold exclusive stream ownership and recheck
the lease immediately before starting each transmission. The packet codec is
the existing 1200-byte UDP diagnostic; it is not a general UDP socket.

The boundary does not acquire an address, drive SDIO, handle ARP, prevent a
reset racing an already submitted DMA transfer, or provide packet delivery.
For a physical fixture, use a single owner to process Hosted control events
before and during sending, stop on disconnect or generation change, retain
bounded credits and retire ambiguous DMA failures, and pair a C6-side run
with an independent peer's payload capture. No physical or interoperability
claim follows from these host tests; QUIC, TLS and iroh remain separate work.

## Single-owner diagnostic

`hosted_split_udp_owner.zig` takes exclusive ownership of a ready Hosted 3.0.10
exchange, its existing decoder, and the stream. It refuses a P4 DHCP client,
different peer/version, incomplete decoder, or unavailable address. It drains
incoming control data before each send, accepts a zero-credit retry only when
nothing was written, and fails closed on partial writes, stale address,
peer restart, decoder/transport errors, or deadline. Only the matching 1200-byte
numbered echo can complete the single attempt. The caller remains responsible
for providing an exclusive transport lease and for reset after a failed stream;
control data that arrives after a send has already begun cannot undo that send.

`tools/build-c6-split-udp-probe.sh` builds a separate CPU0 P4 fixture using the
existing long DMA backend. It never sends a C6 OTA request and does not alter
the normal network path. An initial diagnostic build passed the SRAM audit
with 18,368 bytes of unused heap. This is build and host-model evidence, not a
physical packet receipt; a real peer-configured rebuild and paired captures
are still required.

## Bounded burst experiment

An opt-in follow-up sends 16 distinct 1200-byte attempts at a nominal 250 ms
interval and waits eight seconds after the last complete send. The owner keeps
separate sent and echoed bitmasks, counts duplicate echoes, rejects responses
for attempts not yet sent, and never retries an ambiguous or partial write.
Completion of the observation window does not imply all echoes arrived.
The same address-generation, disconnect, reset and deadline rules apply.
A peer must independently record payloads and the run must preserve both
sent and received masks; a sample is not a general UDP loss-rate estimate.

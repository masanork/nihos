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

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

The host test in `hosted_udp_lease_test.zig` compares all 16 numbered burst
packets byte for byte with the generic UDP lease encoder, then checks that
both decoders accept corresponding synthetic replies. This connects the
fixture packet format to the generic implementation, but does not exercise
the generic sender, its DMA path, or the receiver on physical hardware.

The later [generic UDP diagnostic](../measurements/2026-11-03-hosted3-generic-udp.md)
does exercise the generic sender's `poll` and the lease receive decoder on
Tab5, with the fixture retaining exclusive control-event ownership. It uses
an explicitly configured same-subnet peer and does not provide an OS socket
or establish QUIC interoperability.

For a stage 5 failure the fixture reports `wifi_step`: 1 begins the address
exchange, 2 reads SDIO, 3 decodes/applies frames, 4 checks the clock/deadline,
5 checks ownership handoff, 6 produces a control request, 7 sends it, and 8
accounts for the send. This is the operation in progress, not an error name
or root cause. Step 3 includes the clock read while applying a frame. The
field is zeroed when handoff starts. Older images did not record these steps;
in particular they cannot retrospectively decode the first burst failure.

## madowi port and authentication boundary

A local source inspection on 2026-11-02 of madowi commit
`d4d63a4187801b2673fd6391f53140cc86d7cdcc` found that
`crates/madowi-p2p/src/lib.rs` prefers a stable sync UDP port in
40000–49999, derived from the node ID, and can fall back to an ephemeral
IPv4 socket. The pinned C6 3.0.10 candidate's
`ports/esp-hosted-c6-time-v3/sdkconfig.idf556` forwards incoming host UDP
ports 49152–61439 to P4 and defaults unmatched traffic to the C6 stack.
Only 848 of the 10,000 preferred madowi ports lie in the P4 range. This is a
configuration comparison, not a measurement of actual node IDs, an installed
C6 flash readback, or a failed iroh connection.

The CI host test `tools/hosted3_split_port_test.py` checks that the diagnostic
port remains within the checked-in candidate's host UDP range, that this range
does not overlap the coprocessor UDP range, and that the split/default-stack
and explicit UDP rule settings still match the assumptions above. This test
does not inspect a firmware image or prove packet routing on a device.

A future P4 endpoint must bind and advertise a port the running C6 routes to
P4, or use an explicitly verified alternative routing policy. Changing a
stable port affects saved endpoint addresses and requires the actual selected
address to be published through the chosen discovery mechanism; an ephemeral
fallback must also be constrained or validated against the C6 routing range.
Do not assume source-port rewriting or relay behavior without a capture.

The same madowi source uses iroh 1.2.0, `madowi-sync/1`, a bidirectional QUIC
stream with four-byte big-endian frame lengths, a 64 KiB pre-authentication
credential limit and a 4 MiB normal frame limit. `authz.rs` checks the
owner-signed credential, revocation, session and expiry. An address or port is
not authorization. This repository currently provides only the bounded UDP
diagnostic, not the UDP socket, QUIC/TLS endpoint, credential validation or
madowi sync. These layers and their resource/partial-I/O limits remain
separate implementation and physical interoperability gates.

## Opt-in ARP diagnostic

The split UDP fixture can first resolve its explicit same-subnet peer with
`NIHOS_C6_UDP_SPLIT_ARP=1`. It requires the configured peer IP and MAC and
compares the ARP result against that independently known MAC before sending.
The option defaults off. During resolution `wifi_step=9` means in progress;
`wifi_step=10` means the reply matched. A zero or partial ARP write aborts the
fixture and requires transport recovery. This is a bounded test, not a
runtime ARP service. Use `--require-arp` with
`tools/analyze-hosted3-split-udp-burst.py` to require the matching completion
marker along with the normal paired packet evidence. It does not authenticate
the peer. The [prior physical measurement](../measurements/2026-11-03-hosted-split-arp-udp.md)
belongs to the exact candidate recorded there, not this later fixture revision.

## Shared host prerequisite for a long native datagram

The normal network owner currently admits at most 458 UDP payload bytes and
intentionally denies long DMA. The 1,200-byte physical burst used an exclusive
fixture; it does not qualify the shared SDMMC provider used by the normal
network service.

The experimental long-DMA bus now snapshots the slot-1 lease for each prepared
transfer. When ownership or the lease identity changes during preparation or
completion, the bus rejects completion and quarantines its persistent DMA
buffer. Shared-controller DMA detachment can release the short provider only
with a live lease and no active or quarantined long transfer. The owner must retain that storage, stop the controller and establish
hardware quiescence independently; retirement alone proves neither. The
existing non-shared fixture keeps its original path. Host tests and both
shared/exclusive RV32 code generation cover this prerequisite; neither proves
a native shared-host DMA transfer on hardware.

Before enabling a 1,200-byte native socket, the provider still needs a
long-lived DMA-accessible aligned buffer, cache-engine serialization, the
running C6's long-buffer contract, shared host lease and reset integration,
and a bounded physical run with independently verified payload and recovery.
The short socket limit must remain in effect until those conditions are met.

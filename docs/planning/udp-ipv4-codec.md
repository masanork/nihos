# IPv4 UDP wire codec boundary

`src/net/udp_ipv4.zig` is a host-tested, caller-buffer Ethernet/IPv4/UDP codec
for datagrams up to 1472 payload bytes on an IPv4 MTU of 1500. It encodes
arbitrary byte payloads and validates lengths, IPv4 checksums and UDP
checksums when present. Ethernet padding is ignored. IPv4 packets with a zero
UDP checksum are accepted; a computed zero transmit checksum is encoded as
`0xffff`.

The returned payload borrows the input frame, and the encode output must not
overlap its payload. Ports must be nonzero. VLANs, IP options and IP fragments
are rejected. The caller owns address and MAC validation, routing, ARP, lease
generation, buffer lifetime, concurrency and I/O. This module is not wired to
the P4/C6 link, does not allocate sockets, and does not implement QUIC, TLS or
iroh. Host tests do not establish behavior on Tab5 or on a network.

The existing diagnostic retains its own packet path. Integrating a general
codec into a device transport requires separate ownership/backpressure design,
image-size audit and paired physical qualification.

The codec's 1472-byte limit is a conventional IPv4 MTU limit, not the
currently supported Hosted send limit. The existing Hosted framer caps its
entire Ethernet payload at 1500 bytes; after 14 Ethernet, 20 IPv4 and 8 UDP
header bytes, that permits at most 1458 UDP payload bytes. With the 12-byte
Hosted header, the resulting 1512-byte logical frame plans a 1536-byte padded
long transfer. The host test checks these existing code paths and their exact
boundary; it does not establish that a C6 accepts the transfer. Do not use
the codec limit as the link's negotiated path MTU or enlarge the Hosted limit
without separately qualifying the peer and transport.

`hosted_udp_frame.prepare` composes the two existing encoders and rejects a
payload beyond the Hosted limit or an insufficient output buffer before
writing. It constructs a frame only: the caller must hold the address and
transport lease, handle port routing and serialize all I/O. This helper is
not connected to the runtime network service or the physical diagnostic.
`hosted_udp_frame.receive` checks the station interface and local MAC, IP and
UDP port after decoding. It does not authenticate a source or acquire a lease;
the caller must check address generation before using the borrowed payload.

`hosted_udp_lease.Lease` is an experimental wrapper that captures a complete
C6 address snapshot and generation, and checks both before frame preparation
or receive matching. The local port must belong to an externally supplied
range: this is neither port allocation nor proof of the installed C6 routing
policy. The caller must prevent port collisions, serialize transport ownership,
recheck immediately before submission or consumption, and invalidate the
underlying state on disconnect or reset. It cannot cancel an already-submitted
transfer and does not authenticate the sender. No runtime network service
uses this wrapper yet.

Host integration tests combine the lease and `ProfileStream.sendLong` using a
mock SDIO host. A test-only owner rechecks before retrying zero-credit sends
and invalidates the address on transport failure; neither action happens
automatically across these separate objects. The tests check payload and
padding, stale retry and no replay after a failed write, not physical DMA or
C6 receipt.

`hosted_udp_sender.Sender` is an experimental, single-datagram owner. It owns
its queued packet and padding, uses short or long writes, retries only a zero
write, and retires on timeout, stale binding, partial write or transport
error. It invalidates a still-current address after ambiguous write failures,
but preserves a newer address generation. An unsent queued packet may be
canceled after a zero-credit result; explicit invalidation retires the owner
and stream on reset. Its caller must exclusively own the
stream and state and drain Hosted control events before every poll. Retirement
does not prove hardware DMA quiescence; in-flight storage must remain alive as
required by the backend. It is not connected to the native network service.

Every poll also requires the current Hosted decoder and an explicit assertion
that the caller read zero bytes after applying control events while holding the
same exclusive stream. A false assertion or incomplete frame defers sending;
a poisoned decoder retires the owner. The flag is supplied by the caller, not
an independent proof of an empty FIFO. An event arriving after the empty read
can still race the send. The current native network service
processes at most one 512-byte receive chunk per poll and can then send, so it
cannot pass this gate merely because one chunk was processed. Runtime
integration must preserve bounded fairness while draining and handling events.

`Sender.step` is an opt-in helper that performs one receive of at most 512
bytes, decodes and synchronously dispatches each complete borrowed frame,
then sends only after an empty read. The supplied handler must apply all
relevant control events to the same exclusively owned state and must not keep
borrowed frames. A peer INIT, receive error, decoder error or handler error
retires the sender and stream; the current address is invalidated when still
owned. Incomplete input continues to respect the send deadline. This helper
does not bind into the native service and does not eliminate arrivals racing
an empty read.

The host integration test also composes `Sender.step`, the existing SDIO
stream and controller, the long-DMA guard, bus adapter and buffer, and a mock
register/cache backend. It checks padded packet bytes and quarantine after
simulated DMA completion and stop failures. When stop fails, the model retains
the adapter's active long operation and retired buffer; it does not claim that
hardware has stopped. The guard forwards receive and short-write operations;
long-write errors retire its associated DMA buffer. This is not a target
driver or a measurement of silicon DMA completion. The native service's
current bus does not use the long-DMA fixture provider and must not be assumed
to support this path without an explicit integration and image audit.

`tools/check-udp-ipv4-rv32.sh` compiles both codec directions for the P4 RV32
ISA as part of static analysis. This checks compilation only; it does not link
or execute a firmware image.

`python3 tools/hosted-udp-layout.py` builds an RV32 object with layout markers
and reports the sizes of the sender, its lease, the existing decoder and the
long-DMA buffer in `build/hosted-udp-layout/report.json`. The lease is already
part of the sender and must not be counted twice; the native service already
has a decoder and receive buffer. The output includes the source commit and
dirty state, relevant source hashes, compiler version, and object/assembly
hashes. Inputs are checked before and after compilation; a changed input or
failed build leaves no success report. Concurrent writers are serialized;
readers must still verify artifact hashes against the report. The
accompanying `layout.s` permits inspection of initialization
into caller-provided storage. These are type and object-level measurements,
not evidence of a linked image's total SRAM, aggregate stack or device behavior.

`hosted_udp_route.Route` composes the split-address lease with the existing
ARP resolver for one explicit UDP destination. The caller sends its Hosted
station ARP request as a whole frame, queues incoming frames while TX is
borrowed, and supplies current control state and monotonic milliseconds on
each operation. Same-subnet destinations resolve directly; other destinations
resolve the configured gateway but retain the original IP in the UDP endpoint.
A changed address snapshot, link reset, deadline, or ambiguous transport write
invalidates the route. The bounded result is not an authenticated peer or a
MAC cache, and must be passed to the existing sender under exclusive ownership.
One [bounded Tab5 diagnostic](../measurements/2026-11-03-hosted-split-arp-udp.md)
resolved a same-subnet Mac and used it for a 16-packet UDP round trip. Gateway
resolution remains host-tested only, and application socket integration is
not implemented.

`hosted_udp_socket.Socket` is a host-tested, single-owner experiment that
combines a lease-bound UDP sender with one copied receive slot. It accepts an
externally resolved endpoint, admits one queued transmit, reports a full
receive slot instead of overwriting it, and distinguishes no datagram from a
zero-length datagram. An undersized read leaves the datagram queued. Handles
carry the address generation and a monotonically allocated local ID; close,
lease changes, and send errors retire them. A stale handle must not retire a
new socket's transport. The caller owns exclusive polling, control events,
port allocation, ARP and the bounded policy for a full receive slot.
The owner must invalidate transport and establish DMA quiescence after reset
or ambiguous I/O. This experiment is not connected to normal boot or exposed
to applications, and is not physical socket, QUIC or iroh evidence.

`hosted_udp_owner.Owner` is a further host-tested exclusive-stream experiment
stacked on the UDP socket. It consumes at most one 512-byte Hosted RX chunk
per turn, calls the supplied control/station handler before UDP demultiplexing,
checks the binding again after every callback, and submits queued UDP only
after an empty RX read and a complete decoder. A full receive slot preserves
the older datagram and reports the number of new datagrams dropped in that
turn. Framing errors, new peer INIT, control callback failures and ambiguous
writes retire the socket and stream; callers must reset the transport and
establish DMA quiescence. Retirement revokes the bound address only if that
snapshot remains current, leaving any newer address untouched. A stale old
handle must not disrupt a new one.
The handler must apply control events synchronously and not retain borrowed
frames or reenter the owner. ARP resolution, arbitration with other network
producers, and native service integration remain the caller's responsibility.
These host-model observations do not establish device socket behavior.
An RV32 freestanding size-only object built with ReleaseSafe reports 9,280
bytes for `Owner`, including its socket and decoder. It is not a linked-image
measurement or a memory reservation for normal boot.

`hosted_udp_shared.Shared` is a separate host-tested adapter for a network
owner that already owns its decoder and processes control/station frames. It
receives only frames already processed by that owner, accounts a full UDP slot
as a drop without overwriting it, and takes an explicit station/other-producer
priority and RX-drained state before submitting UDP. A zero-credit UDP attempt
starts no transfer, so another producer may run. Timeouts still expire while
another producer has priority and cancel only the unsent UDP socket. Ambiguous
writes retire the stream and revoke only the still-current address snapshot.
A stale lease during RX retires the
adapter, and the caller must invalidate/recover the shared transport. The
caller must enforce exclusive stream ownership, ensure priority flags reflect
all staged/in-flight transfers, invalidate state on reset, and quiesce DMA.
It is not wired to `network_service.zig`, and these are host-model results.
An RV32 ReleaseSafe size-only object reports 4,648 bytes for `Shared`, which
excludes the already-owned decoder and transport. This is not a linked-image
measurement or an allocation in the normal boot profile.

## Opt-in native short-transfer integration

`NIHOS_NATIVE_EXPERIMENTAL_UDP=1` selects the CPU0 shared UDP adapter in the
normal network service. It requires network enabled, C6 time offload enabled,
the sqld PSRAM reservation, and the TCP experiment disabled. The adapter uses
that reserved backing, handles UDP receive only after the C6 time exchange has
processed the frame, and gives station/time/BLE work priority. Its CPU0-only
experimental bind/send/read/close entry points are not exposed to applications.
The caller supplies a resolved next-hop MAC and a port inside the pinned C6
candidate's host UDP range. The runtime checks the reported C6 protocol and
version, but does not read back its routing configuration or authenticate peers.

The normal SDIO provider accepts only a 512-byte Hosted frame. Therefore the
shared socket's default transmit limit is **458 UDP payload bytes** (512 minus
12 Hosted, 14 Ethernet, 20 IPv4 and 8 UDP bytes). A larger send fails before
submission; a separate short-stream wrapper also rejects any long-DMA call.
Long DMA remains a distinct, explicitly selected diagnostic profile; callers
must not infer that the normal runtime supports it. In particular, this short
path cannot send a QUIC Initial requiring at least 1,200 bytes of UDP payload.
The opt-in profile and its codegen/link audit do not establish physical socket
operation, ARP in normal boot, general P2P, QUIC or iroh interoperability.

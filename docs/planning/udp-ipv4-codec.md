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
failed build leaves no success report. The accompanying `layout.s` permits inspection of initialization
into caller-provided storage. These are type and object-level measurements,
not evidence of a linked image's total SRAM, aggregate stack or device behavior.

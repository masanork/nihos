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

`tools/check-udp-ipv4-rv32.sh` compiles both codec directions for the P4 RV32
ISA as part of static analysis. This checks compilation only; it does not link
or execute a firmware image.

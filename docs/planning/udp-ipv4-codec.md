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

`tools/check-udp-ipv4-rv32.sh` compiles both codec directions for the P4 RV32
ISA as part of static analysis. This checks compilation only; it does not link
or execute a firmware image.

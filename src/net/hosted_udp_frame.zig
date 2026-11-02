//! Compose a UDP/IPv4 frame with an ESP-Hosted header, without doing I/O.
//! Address ownership, C6 port routing and stream serialization are external.
const wire = @import("udp_ipv4.zig");
const hosted = @import("hosted.zig");
const std = @import("std");

/// The current Hosted framer limits the entire Ethernet frame to 1500 bytes.
pub const max_payload: usize = 1500 - wire.frame_header;
pub const Error = wire.Error || hosted.Error;

/// Caller retains the output buffer until the transport has finished with it.
/// Input and output must not overlap. No bytes are submitted to the transport.
pub fn prepare(out: []u8, source: wire.Endpoint, destination: wire.Endpoint, payload: []const u8, sequence: u16) Error![]const u8 {
    if (payload.len > max_payload) return error.TooLarge;
    if (out.len < 12 + wire.frame_header + payload.len) return error.NoSpace;
    const ethernet = try wire.encode(out[12..], source, destination, payload);
    return hosted.frameInPlace(out, hosted.station_interface, sequence, ethernet.len);
}

/// Match a local endpoint after decoding. A null result is for a different
/// interface or destination; malformed packets return an error. The returned
/// payload borrows the Hosted frame. This does not authenticate the sender.
pub fn receive(frame: hosted.Frame, local: wire.Endpoint) wire.Error!?wire.Datagram {
    if (frame.interface != hosted.station_interface) return null;
    const packet = try wire.decode(frame.payload);
    if (packet.destination.port != local.port or
        !std.mem.eql(u8, &packet.destination.ip, &local.ip) or
        !std.mem.eql(u8, &packet.destination.mac, &local.mac)) return null;
    return packet;
}

//! Compile-only RV32 harness; this is not a device driver or runtime API.
const wire = @import("udp_ipv4.zig");

export fn udp_ipv4_probe_encode(out: [*]u8, capacity: usize, data: [*]const u8, length: usize) usize {
    const source = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 1 }, .ip = .{ 192, 0, 2, 1 }, .port = 49152 };
    const destination = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
    const frame = wire.encode(out[0..capacity], source, destination, data[0..length]) catch return 0;
    return frame.len;
}

export fn udp_ipv4_probe_decode(data: [*]const u8, length: usize) usize {
    const datagram = wire.decode(data[0..length]) catch return 0;
    return datagram.payload.len + 1; // Distinguish an empty datagram from failure.
}

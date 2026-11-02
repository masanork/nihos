//! Compile-only RV32 harness; this is not a device driver or runtime API.
const wire = @import("udp_ipv4.zig");
const hosted_udp = @import("hosted_udp_frame.zig");
const split = @import("hosted_network_split.zig");
const lease = @import("hosted_udp_lease.zig");
const sender = @import("hosted_udp_sender.zig");

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

export fn udp_ipv4_probe_hosted(out: [*]u8, capacity: usize, data: [*]const u8, length: usize) usize {
    const source = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 1 }, .ip = .{ 192, 0, 2, 1 }, .port = 49152 };
    const destination = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
    const frame = hosted_udp.prepare(out[0..capacity], source, destination, data[0..length], 1) catch return 0;
    return frame.len;
}

export fn udp_ipv4_probe_match(data: [*]const u8, length: usize) usize {
    const local = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
    const frame = @import("hosted.zig").Frame{ .interface = 1, .payload = data[0..length] };
    const packet = (hosted_udp.receive(frame, local) catch return 0) orelse return 0;
    return packet.payload.len + 1;
}

export fn udp_ipv4_probe_lease(state: *const split.State, data: [*]const u8, length: usize) usize {
    const binding = lease.Lease.open(state, .{ 2, 0, 0, 0, 0, 2 }, 49152, .{ .first = 49152, .last = 61439 }) catch return 0;
    const frame = @import("hosted.zig").Frame{ .interface = 1, .payload = data[0..length] };
    const packet = (binding.receive(state, frame) catch return 0) orelse return 0;
    return packet.payload.len + 1;
}

const CompileStream = struct {
    pub fn send(_: *@This(), _: []const u8) error{Fault}!usize {
        return 0;
    }
    pub fn sendLong(_: *@This(), _: []const u8, _: *[1536]u8) error{Fault}!usize {
        return 0;
    }
    pub fn invalidate(_: *@This()) void {}
};

export fn udp_ipv4_probe_sender(state: *split.State, data: [*]const u8, length: usize) usize {
    const binding = lease.Lease.open(state, .{ 2, 0, 0, 0, 0, 2 }, 49152, .{ .first = 49152, .last = 61439 }) catch return 0;
    var tx = sender.Sender.init(state, binding) catch return 0;
    const peer = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 1 }, .ip = .{ 192, 0, 2, 1 }, .port = 443 };
    tx.enqueue(peer, data[0..length], 1, 1, 3) catch return 0;
    var stream: CompileStream = .{};
    const decoder: @import("hosted.zig").Decoder = .{};
    const result = tx.poll(&stream, 2, &decoder, true) catch return 0;
    if (result == .pending) tx.cancel() catch return 0;
    tx.invalidate(&stream);
    return if (result == .pending) 1 else 2;
}

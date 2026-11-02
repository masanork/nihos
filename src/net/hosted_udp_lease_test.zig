const std = @import("std");
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const udp = @import("hosted_udp_frame.zig");
const guard = @import("hosted_udp_lease.zig");
const testing = std.testing;

const mac = [6]u8{ 2, 0, 0, 0, 0, 1 };
const range = guard.PortRange{ .first = 49152, .last = 61439 };
const peer = @import("udp_ipv4.zig").Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
}

test "binding uses the current address and the externally supplied port range" {
    var state = ready();
    const lease = try guard.Lease.open(&state, mac, 49152, range);
    try testing.expectEqualSlices(u8, &.{ 192, 0, 2, 1 }, &lease.local.ip);
    try testing.expectError(error.InvalidBinding, guard.Lease.open(&state, mac, 49151, range));
    try testing.expectError(error.InvalidBinding, guard.Lease.open(&state, mac, 61440, range));
    try testing.expectError(error.InvalidBinding, guard.Lease.open(&state, mac, 1, .{ .first = 0, .last = 10 }));
    try testing.expectError(error.InvalidBinding, guard.Lease.open(&state, mac, 1, .{ .first = 2, .last = 1 }));
    try testing.expectError(error.InvalidBinding, guard.Lease.open(&state, .{ 1, 0, 0, 0, 0, 0 }, 49152, range));
    try testing.expectError(error.InvalidBinding, guard.Lease.open(&state, @splat(0), 49152, range));
    state.address = null;
    try testing.expectError(error.NoAddress, guard.Lease.open(&state, mac, 49152, range));
}

test "lease guards transmit and receipt without authenticating peer" {
    var state = ready();
    const lease = try guard.Lease.open(&state, mac, 49152, range);
    var outbound: [1536]u8 = undefined;
    const frame = try lease.prepare(&state, &outbound, peer, "hello", 8);
    var decoder: hosted.Decoder = .{};
    var received: ?hosted.Frame = null;
    for (frame) |byte| if (try decoder.push(byte)) |f| {
        received = f;
    };
    try testing.expect((try lease.receive(&state, received.?)) == null); // Outbound destination is not local.
    var inbound: [1536]u8 = undefined;
    const reply = try udp.prepare(&inbound, peer, lease.local, "hello", 9);
    decoder = .{};
    received = null;
    for (reply) |byte| if (try decoder.push(byte)) |f| {
        received = f;
    };
    const data = (try lease.receive(&state, received.?)).?;
    try testing.expectEqualStrings("hello", data.payload);
    try testing.expectEqualDeep(peer, data.source);
    try testing.expect(state.invalidate());
    @memset(&outbound, 0xa5);
    try testing.expectError(error.Stale, lease.prepare(&state, &outbound, peer, "hello", 10));
    try testing.expect(std.mem.allEqual(u8, &outbound, 0xa5));
    try testing.expectError(error.Stale, lease.receive(&state, received.?));
    state.address = ready().address;
    try testing.expectError(error.Stale, lease.check(&state));
}

test "even a changed snapshot under the same generation is stale" {
    var state = ready();
    const lease = try guard.Lease.open(&state, mac, 61439, range);
    state.address.?.dns = 0x08080808;
    try testing.expectError(error.Stale, lease.check(&state));
}

const std = @import("std");
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const udp = @import("hosted_udp_frame.zig");
const guard = @import("hosted_udp_lease.zig");
const testing = std.testing;
const sdio = @import("c6_sdio.zig");

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

const MockHost = struct {
    pub const TransportError = error{WriteFailed};
    credits: u32 = 0,
    writes: usize = 0,
    fail_write: bool = false,
    captured: [1536]u8 = @splat(0),

    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        return self.credits << 16;
    }
    pub fn writeBlocks(self: *@This(), _: u32, bytes: []const u8) TransportError!void {
        self.writes += 1;
        if (self.fail_write) return error.WriteFailed;
        @memcpy(self.captured[0..bytes.len], bytes);
    }
};

// This test caller models the required exclusive-owner discipline; the lease
// and stream do not enforce serialization or revoke each other automatically.
fn checkedSend(binding: *const guard.Lease, state: *split.State, stream: *sdio.ProfileStream(MockHost, 64), packet: []const u8, padding: *[1536]u8) !usize {
    binding.check(state) catch |err| {
        stream.invalidate();
        return err;
    };
    return stream.sendLong(packet, padding) catch |err| {
        _ = state.invalidate();
        return err;
    };
}

test "prepared 1200-byte UDP uses real long stream credit and padding" {
    var state = ready();
    const lease = try guard.Lease.open(&state, mac, 49152, range);
    var output: [1536]u8 = undefined;
    var padding: [1536]u8 = undefined;
    const payload: [1200]u8 = @splat(0x5a);
    const frame = try lease.prepare(&state, &output, peer, &payload, 8);
    var host: MockHost = .{};
    var stream: sdio.ProfileStream(MockHost, 64) = .{ .host = &host };
    try testing.expectEqual(@as(usize, 0), try checkedSend(&lease, &state, &stream, frame, &padding));
    try testing.expectEqual(@as(usize, 0), host.writes);
    host.credits = 1;
    try testing.expectEqual(frame.len, try checkedSend(&lease, &state, &stream, frame, &padding));
    try testing.expectEqual(@as(usize, 1), host.writes);
    try testing.expectEqualSlices(u8, frame, host.captured[0..frame.len]);
    try testing.expect(std.mem.allEqual(u8, host.captured[frame.len..], 0));
    try testing.expectEqualSlices(u8, &payload, (try @import("udp_ipv4.zig").decode(host.captured[12..frame.len])).payload);
}

test "stale lease blocks retry and failed long write revokes lease" {
    var state = ready();
    var lease = try guard.Lease.open(&state, mac, 49152, range);
    var output: [1536]u8 = undefined;
    var padding: [1536]u8 = undefined;
    const payload: [1200]u8 = @splat(0x5a);
    var frame = try lease.prepare(&state, &output, peer, &payload, 8);
    var host: MockHost = .{};
    var stream: sdio.ProfileStream(MockHost, 64) = .{ .host = &host };
    try testing.expectEqual(@as(usize, 0), try checkedSend(&lease, &state, &stream, frame, &padding));
    try testing.expect(state.invalidate());
    host.credits = 1;
    try testing.expectError(error.Stale, checkedSend(&lease, &state, &stream, frame, &padding));
    try testing.expectEqual(@as(usize, 0), host.writes);
    try testing.expect(stream.faulted);

    state = ready();
    lease = try guard.Lease.open(&state, mac, 49152, range);
    frame = try lease.prepare(&state, &output, peer, &payload, 9);
    host = .{ .credits = 1, .fail_write = true };
    stream = .{ .host = &host };
    try testing.expectError(error.WriteFailed, checkedSend(&lease, &state, &stream, frame, &padding));
    try testing.expect(stream.faulted and state.address == null);
    try testing.expectError(error.Stale, checkedSend(&lease, &state, &stream, frame, &padding));
    try testing.expectEqual(@as(usize, 1), host.writes);
}

const std = @import("std");
const split = @import("hosted_network_split.zig");
const guard = @import("hosted_udp_lease.zig");
const mod = @import("hosted_udp_sender.zig");
const testing = std.testing;

const peer = @import("udp_ipv4.zig").Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
}
fn sender(state: *split.State) !mod.Sender {
    const lease = try guard.Lease.open(state, .{ 2, 0, 0, 0, 0, 1 }, 49152, .{ .first = 49152, .last = 61439 });
    return mod.Sender.init(state, lease);
}
const Mock = struct {
    result: usize = 0,
    failure: bool = false,
    replace_state: ?*split.State = null,
    short_calls: u32 = 0,
    long_calls: u32 = 0,
    retired: bool = false,
    pub fn send(self: *@This(), packet: []const u8) !usize {
        self.short_calls += 1;
        return self.write(packet);
    }
    pub fn sendLong(self: *@This(), packet: []const u8, _: *[1536]u8) !usize {
        self.long_calls += 1;
        return self.write(packet);
    }
    fn write(self: *@This(), packet: []const u8) !usize {
        if (self.replace_state) |state| {
            state.generation += 1;
            state.address.?.ip = 0xc0000203;
        }
        if (self.failure) return error.WriteFailed;
        return if (self.result == 1) packet.len else self.result;
    }
    pub fn invalidate(self: *@This()) void {
        self.retired = true;
    }
};

test "one queued packet survives zero credit and chooses short or long transport" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{};
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.Busy, tx.enqueue(peer, "other", 2, 2, 50));
    try testing.expectEqual(mod.Outcome.pending, try tx.poll(&stream, 2));
    stream.result = 1;
    try testing.expectEqual(mod.Outcome.sent, try tx.poll(&stream, 3));
    try testing.expectEqual(@as(u32, 2), stream.short_calls);
    const payload: [1200]u8 = @splat(0x5a);
    try tx.enqueue(peer, &payload, 2, 4, 50);
    try testing.expectEqual(mod.Outcome.sent, try tx.poll(&stream, 5));
    try testing.expectEqual(@as(u32, 1), stream.long_calls);
    try testing.expectEqual(mod.Phase.idle, tx.phase);
}

test "stale or timed-out pending send never touches transport" {
    for (0..2) |case| {
        var state = ready();
        var tx = try sender(&state);
        var stream: Mock = .{};
        try tx.enqueue(peer, "abc", 1, 1, 10);
        if (case == 0) try testing.expect(state.invalidate());
        try testing.expectError(if (case == 0) error.Stale else error.Deadline, tx.poll(&stream, if (case == 0) 2 else 10));
        try testing.expectEqual(@as(u32, 0), stream.short_calls);
        try testing.expect(stream.retired);
        try testing.expectError(error.Retired, tx.poll(&stream, 11));
    }
}

test "ambiguous failure retires stream and current address without replay" {
    for (0..2) |case| {
        var state = ready();
        var tx = try sender(&state);
        var stream: Mock = .{ .failure = case == 0, .result = 17 };
        try tx.enqueue(peer, "abc", 1, 1, 50);
        try testing.expectError(if (case == 0) error.WriteFailed else error.PartialPacket, tx.poll(&stream, 2));
        try testing.expect(stream.retired and state.address == null);
        try testing.expectError(error.Retired, tx.poll(&stream, 3));
        try testing.expectEqual(@as(u32, 1), stream.short_calls);
    }
}

test "a concurrent newer address is not invalidated by an old failure" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{ .failure = true, .replace_state = &state };
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.WriteFailed, tx.poll(&stream, 2));
    try testing.expectEqual(@as(u64, 8), state.generation);
    try testing.expectEqual(@as(u32, 0xc0000203), state.address.?.ip);
    try testing.expect(stream.retired);
}

test "cancel removes an unsent packet and permits a later packet" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{};
    try testing.expectError(error.Busy, tx.cancel());
    try tx.enqueue(peer, "first", 1, 1, 50);
    try testing.expectEqual(mod.Outcome.pending, try tx.poll(&stream, 2));
    try tx.cancel();
    try testing.expectEqual(mod.Phase.idle, tx.phase);
    try testing.expectError(error.Busy, tx.poll(&stream, 3));
    try tx.enqueue(peer, "next", 2, 3, 50);
    stream.result = 1;
    try testing.expectEqual(mod.Outcome.sent, try tx.poll(&stream, 4));
    try testing.expectEqual(@as(u32, 2), stream.short_calls);
    try testing.expect(state.address != null and !stream.retired);
}

test "reset retires once and does not invalidate a newer generation" {
    for (0..2) |case| {
        var state = ready();
        var tx = try sender(&state);
        var stream: Mock = .{};
        try tx.enqueue(peer, "first", 1, 1, 50);
        if (case == 1) {
            state.generation += 1;
            state.address.?.ip = 0xc0000203;
        }
        tx.invalidate(&stream);
        tx.invalidate(&stream);
        try testing.expect(stream.retired);
        try testing.expectError(error.Retired, tx.cancel());
        try testing.expectError(error.Retired, tx.poll(&stream, 2));
        if (case == 0) {
            try testing.expect(state.address == null);
        } else {
            try testing.expectEqual(@as(u64, 8), state.generation);
            try testing.expectEqual(@as(u32, 0xc0000203), state.address.?.ip);
        }
    }
}

const Host = struct {
    pub const TransportError = error{WriteFailed};
    credits: u32 = 0,
    writes: u32 = 0,
    fail: bool = false,
    data: [1536]u8 = @splat(0),
    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        return self.credits << 16;
    }
    pub fn writeBytes(self: *@This(), _: u32, bytes: []const u8) TransportError!void {
        try self.record(bytes);
    }
    pub fn writeBlocks(self: *@This(), _: u32, bytes: []const u8) TransportError!void {
        try self.record(bytes);
    }
    fn record(self: *@This(), bytes: []const u8) TransportError!void {
        self.writes += 1;
        if (self.fail) return error.WriteFailed;
        @memcpy(self.data[0..bytes.len], bytes);
    }
};

test "owner composes real SDIO stream credit, packet and padding" {
    var state = ready();
    var tx = try sender(&state);
    var host: Host = .{};
    var stream: @import("c6_sdio.zig").ProfileStream(Host, 64) = .{ .host = &host };
    const payload: [1200]u8 = @splat(0x5a);
    try tx.enqueue(peer, &payload, 1, 1, 50);
    try testing.expectEqual(mod.Outcome.pending, try tx.poll(&stream, 2));
    try testing.expectEqual(@as(u32, 0), host.writes);
    host.credits = 1;
    try testing.expectEqual(mod.Outcome.sent, try tx.poll(&stream, 3));
    try testing.expectEqual(@as(u32, 1), host.writes);
    const packet = try @import("udp_ipv4.zig").decode(host.data[12..1254]);
    try testing.expectEqualSlices(u8, &payload, packet.payload);
    try testing.expect(std.mem.allEqual(u8, host.data[1254..], 0));

    try tx.enqueue(peer, &payload, 2, 4, 50);
    host.credits = 2;
    host.fail = true;
    try testing.expectError(error.WriteFailed, tx.poll(&stream, 5));
    try testing.expect(stream.faulted and state.address == null);
    try testing.expectError(error.Retired, tx.poll(&stream, 6));
    try testing.expectEqual(@as(u32, 2), host.writes);
}

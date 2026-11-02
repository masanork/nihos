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
fn poll(tx: *mod.Sender, stream: anytype, now: u64) !mod.Outcome {
    const decoder: @import("hosted.zig").Decoder = .{};
    return tx.poll(stream, now, &decoder, true);
}
const Mock = struct {
    result: usize = 0,
    failure: bool = false,
    replace_state: ?*split.State = null,
    short_calls: u32 = 0,
    long_calls: u32 = 0,
    retired: bool = false,
    input: []const u8 = &.{},
    position: usize = 0,
    max_read: usize = 512,
    reads: u32 = 0,
    receive_fail: bool = false,
    pub fn receive(self: *@This(), out: []u8) !usize {
        self.reads += 1;
        if (self.receive_fail) return error.ReadFailed;
        const count = @min(self.max_read, @min(out.len, self.input.len - self.position));
        @memcpy(out[0..count], self.input[self.position..][0..count]);
        self.position += count;
        return count;
    }
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

const Handler = struct {
    state: *split.State,
    frames: u32 = 0,
    disconnect: bool = false,
    fail: bool = false,
    pub fn receive(self: *@This(), _: @import("hosted.zig").Frame, _: u64) !void {
        self.frames += 1;
        if (self.fail) return error.DispatchFailed;
        if (self.disconnect) _ = self.state.invalidate();
    }
};

test "one queued packet survives zero credit and chooses short or long transport" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{};
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.Busy, tx.enqueue(peer, "other", 2, 2, 50));
    try testing.expectEqual(mod.Outcome.pending, try poll(&tx, &stream, 2));
    stream.result = 1;
    try testing.expectEqual(mod.Outcome.sent, try poll(&tx, &stream, 3));
    try testing.expectEqual(@as(u32, 2), stream.short_calls);
    const payload: [1200]u8 = @splat(0x5a);
    try tx.enqueue(peer, &payload, 2, 4, 50);
    try testing.expectEqual(mod.Outcome.sent, try poll(&tx, &stream, 5));
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
        try testing.expectError(if (case == 0) error.Stale else error.Deadline, poll(&tx, &stream, if (case == 0) 2 else 10));
        try testing.expectEqual(@as(u32, 0), stream.short_calls);
        try testing.expect(stream.retired);
        try testing.expectError(error.Retired, poll(&tx, &stream, 11));
    }
}

test "pending input and incomplete control frames block transmission" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{ .result = 1 };
    var decoder: @import("hosted.zig").Decoder = .{};
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectEqual(mod.Outcome.pending, try tx.poll(&stream, 2, &decoder, false));
    decoder.used = 1;
    try testing.expectEqual(mod.Outcome.pending, try tx.poll(&stream, 3, &decoder, true));
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    decoder.used = 0;
    try testing.expect(state.invalidate()); // The completed control event was link-down.
    try testing.expectError(error.Stale, tx.poll(&stream, 4, &decoder, true));
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    try testing.expect(stream.retired);
}

test "poisoned Hosted decoder retires current address and stream" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{ .result = 1 };
    const decoder: @import("hosted.zig").Decoder = .{ .poisoned = true };
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.Malformed, tx.poll(&stream, 2, &decoder, true));
    try testing.expect(stream.retired and state.address == null);
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
}

test "bounded receive dispatches fragmented control before any send" {
    var state = ready();
    var tx = try sender(&state);
    const hosted = @import("hosted.zig");
    var encoded: [40]u8 = undefined;
    const control = try hosted.frame(&encoded, 3, 1, "event");
    var stream: Mock = .{ .result = 1, .input = control, .max_read = 5 };
    var decoder: hosted.Decoder = .{};
    var handler: Handler = .{ .state = &state, .disconnect = true };
    var rx: [512]u8 = undefined;
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectEqual(mod.Outcome.pending, try tx.step(&stream, &decoder, &handler, &rx, 2));
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    try testing.expectEqual(mod.Outcome.pending, try tx.step(&stream, &decoder, &handler, &rx, 3));
    try testing.expectEqual(mod.Outcome.pending, try tx.step(&stream, &decoder, &handler, &rx, 4));
    try testing.expectError(error.Stale, tx.step(&stream, &decoder, &handler, &rx, 5));
    try testing.expectEqual(@as(u32, 1), handler.frames);
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    try testing.expect(stream.retired);
}

test "real C6 exchange consumes fragmented link-down before UDP send" {
    const hosted = @import("hosted.zig");
    const exchange = @import("hosted_c6_time_exchange.zig");
    var connection: exchange.Exchange = .{};
    connection.phase = .ready;
    connection.deadline = 100;
    connection.station.phase = .done;
    connection.station.connected = true;
    connection.station.peer_chip = 13;
    connection.station.version_known = true;
    connection.station.version = .{ 3, 0, 10 };
    connection.station.peer_rpc_version = 2;
    connection.station.peer_sdio_buffer_blocks = .{ 7, 7 };
    connection.station.peer_mode = 1;
    connection.addresses = ready();
    connection.clock.reset(connection.addresses.generation);
    var tx = try sender(&connection.addresses);
    var rpc_buffer: [64]u8 = undefined;
    const rpc = try hosted.request(&rpc_buffer, 777, 1, &.{});
    rpc_buffer[13] = 3;
    @memcpy(rpc_buffer[3..9], "RPCEvt");
    var encoded: [100]u8 = undefined;
    const event = try hosted.frame(&encoded, 3, 1, rpc);
    var stream: Mock = .{ .result = 1, .input = event, .max_read = 4 };
    var decoder: hosted.Decoder = .{};
    var rx: [512]u8 = undefined;
    try tx.enqueue(peer, "abc", 1, 1, 50);
    var now: u64 = 2;
    while (stream.position < stream.input.len) : (now += 1) {
        _ = tx.step(&stream, &decoder, &connection, &rx, now) catch |err| {
            try testing.expectEqual(error.Stale, err);
            break;
        };
        try testing.expectEqual(@as(u32, 0), stream.short_calls);
    }
    try testing.expect(stream.retired and connection.addresses.address == null);
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
}

test "peer INIT retires sender before dispatch or transmission" {
    const hosted = @import("hosted.zig");
    var state = ready();
    var tx = try sender(&state);
    var encoded: [40]u8 = undefined;
    const event = try hosted.frame(&encoded, 5, 1, "init");
    var stream: Mock = .{ .result = 1, .input = event };
    var decoder: hosted.Decoder = .{};
    var handler: Handler = .{ .state = &state };
    var rx: [512]u8 = undefined;
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.Stale, tx.step(&stream, &decoder, &handler, &rx, 2));
    try testing.expectEqual(@as(u32, 0), handler.frames);
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    try testing.expect(stream.retired and state.address == null);
}

test "address revocation stops dispatch of later frames in same chunk" {
    const hosted = @import("hosted.zig");
    var state = ready();
    var tx = try sender(&state);
    var first: [40]u8 = undefined;
    var second: [40]u8 = undefined;
    const one = try hosted.frame(&first, 3, 1, "event");
    const two = try hosted.frame(&second, 1, 2, "data");
    var combined: [80]u8 = undefined;
    @memcpy(combined[0..one.len], one);
    @memcpy(combined[one.len..][0..two.len], two);
    var stream: Mock = .{ .result = 1, .input = combined[0 .. one.len + two.len] };
    var decoder: hosted.Decoder = .{};
    var handler: Handler = .{ .state = &state, .disconnect = true };
    var rx: [512]u8 = undefined;
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.Stale, tx.step(&stream, &decoder, &handler, &rx, 2));
    try testing.expectEqual(@as(u32, 1), handler.frames);
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    try testing.expect(stream.retired);
}

test "bounded receive sends only after empty read and fails closed" {
    const hosted = @import("hosted.zig");
    for (0..3) |case| {
        var state = ready();
        var tx = try sender(&state);
        var encoded: [40]u8 = undefined;
        const control = try hosted.frame(&encoded, 3, 1, "event");
        var stream: Mock = .{ .result = 1, .input = control, .receive_fail = case == 1 };
        var decoder: hosted.Decoder = .{};
        var handler: Handler = .{ .state = &state, .fail = case == 2 };
        var rx: [512]u8 = undefined;
        try tx.enqueue(peer, "abc", 1, 1, 50);
        if (case == 0) {
            try testing.expectEqual(mod.Outcome.pending, try tx.step(&stream, &decoder, &handler, &rx, 2));
            try testing.expectEqual(@as(u32, 1), handler.frames);
            try testing.expectEqual(@as(u32, 0), stream.short_calls);
            try testing.expectEqual(mod.Outcome.sent, try tx.step(&stream, &decoder, &handler, &rx, 3));
            try testing.expectEqual(@as(u32, 1), stream.short_calls);
        } else {
            try testing.expectError(if (case == 1) error.ReadFailed else error.DispatchFailed, tx.step(&stream, &decoder, &handler, &rx, 2));
            try testing.expect(stream.retired and state.address == null);
            try testing.expectEqual(@as(u32, 0), stream.short_calls);
        }
    }
}

test "an empty read with incomplete frame still waits until deadline" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{ .result = 1, .input = &.{ 3, 0, 5, 0, 12 } };
    var decoder: @import("hosted.zig").Decoder = .{};
    var handler: Handler = .{ .state = &state };
    var rx: [512]u8 = undefined;
    try tx.enqueue(peer, "abc", 1, 1, 5);
    try testing.expectEqual(mod.Outcome.pending, try tx.step(&stream, &decoder, &handler, &rx, 2));
    try testing.expectEqual(mod.Outcome.pending, try tx.step(&stream, &decoder, &handler, &rx, 3));
    try testing.expectEqual(@as(u32, 0), stream.short_calls);
    try testing.expectError(error.Deadline, tx.step(&stream, &decoder, &handler, &rx, 5));
    try testing.expectEqual(@as(u32, 2), stream.reads);
    try testing.expect(stream.retired);
}

test "ambiguous failure retires stream and current address without replay" {
    for (0..2) |case| {
        var state = ready();
        var tx = try sender(&state);
        var stream: Mock = .{ .failure = case == 0, .result = 17 };
        try tx.enqueue(peer, "abc", 1, 1, 50);
        try testing.expectError(if (case == 0) error.WriteFailed else error.PartialPacket, poll(&tx, &stream, 2));
        try testing.expect(stream.retired and state.address == null);
        try testing.expectError(error.Retired, poll(&tx, &stream, 3));
        try testing.expectEqual(@as(u32, 1), stream.short_calls);
    }
}

test "a concurrent newer address is not invalidated by an old failure" {
    var state = ready();
    var tx = try sender(&state);
    var stream: Mock = .{ .failure = true, .replace_state = &state };
    try tx.enqueue(peer, "abc", 1, 1, 50);
    try testing.expectError(error.WriteFailed, poll(&tx, &stream, 2));
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
    try testing.expectEqual(mod.Outcome.pending, try poll(&tx, &stream, 2));
    try tx.cancel();
    try testing.expectEqual(mod.Phase.idle, tx.phase);
    try testing.expectError(error.Busy, poll(&tx, &stream, 3));
    try tx.enqueue(peer, "next", 2, 3, 50);
    stream.result = 1;
    try testing.expectEqual(mod.Outcome.sent, try poll(&tx, &stream, 4));
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
        try testing.expectError(error.Retired, poll(&tx, &stream, 2));
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
    pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
        if (address == @import("c6_sdio.zig").length_register) return 0;
        return self.credits << 16;
    }
    pub fn readBytes(_: *@This(), _: u32, _: []u8) TransportError!void {
        return error.WriteFailed; // Empty RX never invokes this in this test.
    }
    pub fn writeWord(_: *@This(), _: u32, _: u32) TransportError!void {}
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
    try testing.expectEqual(mod.Outcome.pending, try poll(&tx, &stream, 2));
    try testing.expectEqual(@as(u32, 0), host.writes);
    host.credits = 1;
    try testing.expectEqual(mod.Outcome.sent, try poll(&tx, &stream, 3));
    try testing.expectEqual(@as(u32, 1), host.writes);
    const packet = try @import("udp_ipv4.zig").decode(host.data[12..1254]);
    try testing.expectEqualSlices(u8, &payload, packet.payload);
    try testing.expect(std.mem.allEqual(u8, host.data[1254..], 0));

    try tx.enqueue(peer, &payload, 2, 4, 50);
    host.credits = 2;
    host.fail = true;
    try testing.expectError(error.WriteFailed, poll(&tx, &stream, 5));
    try testing.expect(stream.faulted and state.address == null);
    try testing.expectError(error.Retired, poll(&tx, &stream, 6));
    try testing.expectEqual(@as(u32, 2), host.writes);
}

test "bounded step uses real SDIO stream empty-read before sending" {
    var state = ready();
    var tx = try sender(&state);
    var host: Host = .{ .credits = 1 };
    var stream: @import("c6_sdio.zig").ProfileStream(Host, 64) = .{ .host = &host };
    var decoder: @import("hosted.zig").Decoder = .{};
    var handler: Handler = .{ .state = &state };
    var rx: [512]u8 = undefined;
    const payload: [1200]u8 = @splat(0x5a);
    try tx.enqueue(peer, &payload, 1, 1, 50);
    try testing.expectEqual(mod.Outcome.sent, try tx.step(&stream, &decoder, &handler, &rx, 2));
    try testing.expectEqual(@as(u32, 1), host.writes);
    try testing.expectEqualSlices(u8, &payload, (try @import("udp_ipv4.zig").decode(host.data[12..1254])).payload);
}

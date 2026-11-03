const std = @import("std");
const t = std.testing;
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const packet = @import("hosted_udp_frame.zig");
const udp = @import("udp_ipv4.zig");
const shared = @import("hosted_udp_shared.zig");
const local = [6]u8{ 2, 0, 0, 0, 0, 1 };
const peer = udp.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 44444 };
const range = @import("hosted_udp_lease.zig").PortRange{ .first = 49152, .last = 61439 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
}
const Stream = struct {
    writes: usize = 0,
    mode: enum { full, zero, partial } = .full,
    retired: bool = false,
    pub fn send(self: *@This(), bytes: []const u8) !usize {
        self.writes += 1;
        return switch (self.mode) {
            .full => bytes.len,
            .zero => 0,
            .partial => 1,
        };
    }
    pub fn sendLong(self: *@This(), bytes: []const u8, _: *[1536]u8) !usize {
        return self.send(bytes);
    }
    pub fn invalidate(self: *@This()) void {
        self.retired = true;
    }
};

const SdioHost = struct {
    pub const TransportError = error{WriteFailed};
    credits: u32 = 0,
    writes: u32 = 0,
    data: [1536]u8 = @splat(0),
    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        return self.credits << 16;
    }
    pub fn writeBytes(self: *@This(), _: u32, bytes: []const u8) TransportError!void {
        self.writes += 1;
        @memcpy(self.data[0..bytes.len], bytes);
    }
    pub fn writeBlocks(self: *@This(), _: u32, bytes: []const u8) TransportError!void {
        try self.writeBytes(0, bytes);
    }
};

test "station, other producers and partial RX take precedence over UDP" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    try owner.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var stream: Stream = .{};
    var decoder: hosted.Decoder = .{};
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 2, true, true, false));
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 3, true, false, true));
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 4, false, false, false));
    decoder.used = 1;
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 5, true, false, false));
    try t.expectEqual(@as(usize, 0), stream.writes);
    decoder.used = 0;
    try t.expectEqual(shared.Send.sent, try owner.poll(h, &stream, &decoder, 6, true, false, false));
    try t.expectEqual(@as(usize, 1), stream.writes);
}

test "zero credit allows other producer before retry" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    try owner.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var stream: Stream = .{ .mode = .zero };
    const decoder: hosted.Decoder = .{};
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 2, true, false, false));
    stream.mode = .full;
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 3, true, true, false));
    try t.expectEqual(@as(usize, 1), stream.writes);
    try t.expectEqual(shared.Send.sent, try owner.poll(h, &stream, &decoder, 4, true, false, false));
}

test "shared priority and credits gate a 1200-byte SDIO frame" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    const payload: [1200]u8 = @splat(0x5a);
    try owner.socket.sendTo(h, peer, &payload, 1, 1, 100);
    var host: SdioHost = .{};
    var stream: @import("c6_sdio.zig").ProfileStream(SdioHost, 64) = .{ .host = &host };
    const decoder: hosted.Decoder = .{};
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 2, true, false, false));
    host.credits = 1;
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 3, true, true, false));
    try t.expectEqual(@as(u32, 0), host.writes);
    try t.expectEqual(shared.Send.sent, try owner.poll(h, &stream, &decoder, 4, true, false, false));
    try t.expectEqual(@as(u32, 1), host.writes);
    try t.expectEqualSlices(u8, &payload, (try udp.decode(host.data[12..1254])).payload);
    try t.expect(std.mem.allEqual(u8, host.data[1254..], 0));
}

test "blocked deadline preserves shared stream and partial write retires it" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    try owner.socket.sendTo(h, peer, "hello", 1, 1, 10);
    var stream: Stream = .{};
    const decoder: hosted.Decoder = .{};
    try t.expectError(error.Deadline, owner.poll(h, &stream, &decoder, 10, false, true, true));
    try t.expect(!stream.retired and !owner.retired);
    try t.expect(state.address != null);
    try t.expectEqual(@as(usize, 0), stream.writes);
    _ = try owner.bind(&state, local, 49152, range);
    state = ready();
    owner = .{};
    const next = try owner.bind(&state, local, 49152, range);
    try owner.socket.sendTo(next, peer, "hello", 1, 1, 100);
    stream = .{ .mode = .partial };
    try t.expectError(error.PartialPacket, owner.poll(next, &stream, &decoder, 2, true, false, false));
    try t.expect(stream.retired and owner.retired);
    try t.expectError(error.Retired, owner.poll(next, &stream, &decoder, 3, true, false, false));
    try t.expectEqual(@as(usize, 1), stream.writes);
}

test "poisoned shared decoder retires even without a pending send" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    var stream: Stream = .{};
    var decoder: hosted.Decoder = .{};
    decoder.poisoned = true;
    try t.expectError(error.Malformed, owner.poll(h, &stream, &decoder, 1, false, true, true));
    try t.expect(stream.retired and owner.retired and state.address == null);
}

test "stale receive retires adapter for external transport recovery" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    _ = state.invalidate();
    try t.expectError(error.StaleHandle, owner.receiveProcessed(h, .{ .interface = 3, .payload = &.{} }));
    try t.expect(owner.retired);
    state = ready();
    try t.expectError(error.Retired, owner.bind(&state, local, 49152, range));
}

test "processed receive preserves first datagram and counts the second" {
    var state = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&state, local, 49152, range);
    const dst = owner.socket.sender.?.binding.local;
    var storage: [1512]u8 = undefined;
    const bytes = try packet.prepare(&storage, peer, dst, "hello", 1);
    var decoder: hosted.Decoder = .{};
    var incoming: ?hosted.Frame = null;
    for (bytes) |b| if (try decoder.push(b)) |f| {
        incoming = f;
    };
    try t.expectEqual(shared.Receive.accepted, try owner.receiveProcessed(h, incoming.?));
    try t.expectEqual(shared.Receive.dropped, try owner.receiveProcessed(h, incoming.?));
    var out: [8]u8 = undefined;
    const result = (try owner.socket.read(h, &out)).?;
    try t.expectEqualStrings("hello", out[0..result.bytes]);
}

test "stale handle and address changes cannot touch replacement stream" {
    var state = ready();
    var owner: shared.Shared = .{};
    const old = try owner.bind(&state, local, 49152, range);
    try owner.socket.close(old);
    const next = try owner.bind(&state, local, 49152, range);
    var stream: Stream = .{};
    const decoder: hosted.Decoder = .{};
    try t.expectError(error.StaleHandle, owner.poll(old, &stream, &decoder, 1, true, false, false));
    try t.expect(!stream.retired and !owner.retired);
    _ = state.invalidate();
    try t.expectError(error.StaleHandle, owner.poll(next, &stream, &decoder, 2, true, false, false));
    try t.expect(stream.retired and owner.retired);
}

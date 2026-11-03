const std = @import("std");
const t = std.testing;
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const udp = @import("udp_ipv4.zig");
const packet = @import("hosted_udp_frame.zig");
const owner = @import("hosted_udp_owner.zig");
const local = [6]u8{ 2, 0, 0, 0, 0, 1 };
const peer = udp.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 44444 };
const range = @import("hosted_udp_lease.zig").PortRange{ .first = 49152, .last = 61439 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
}
const Stream = struct {
    input: []const u8 = &.{},
    pos: usize = 0,
    chunk: usize = 512,
    reads: usize = 0,
    writes: usize = 0,
    mode: enum { full, zero, partial } = .full,
    retired: bool = false,
    pub fn receive(self: *@This(), out: []u8) !usize {
        self.reads += 1;
        const n = @min(self.chunk, @min(out.len, self.input.len - self.pos));
        @memcpy(out[0..n], self.input[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
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
const Handler = struct {
    state: *split.State,
    calls: usize = 0,
    disconnect: bool = false,
    replace_then_fail: bool = false,
    pub fn receive(self: *@This(), frame: hosted.Frame, _: u64) !void {
        self.calls += 1;
        if (self.disconnect and frame.interface == 3) _ = self.state.invalidate();
        if (self.replace_then_fail and frame.interface == 3) {
            self.state.generation += 1;
            return error.ControlFailure;
        }
    }
};

test "fragmented control is applied before queued send" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    try o.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var encoded: [64]u8 = undefined;
    const control = try hosted.frame(&encoded, 3, 1, "control");
    var stream: Stream = .{ .input = control, .chunk = 4 };
    var handler: Handler = .{ .state = &state };
    var time: u64 = 2;
    while (stream.pos < stream.input.len) : (time += 1) {
        const p = try o.step(h, &stream, &handler, time);
        try t.expectEqual(owner.Send.pending, p.send);
        try t.expectEqual(@as(usize, 0), stream.writes);
    }
    try t.expectEqual(@as(usize, 1), handler.calls);
    const done = try o.step(h, &stream, &handler, time);
    try t.expectEqual(owner.Send.sent, done.send);
    try t.expectEqual(@as(usize, 1), stream.writes);
}

test "failure does not revoke a newer address snapshot" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    var encoded: [64]u8 = undefined;
    const control = try hosted.frame(&encoded, 3, 1, "changed");
    var stream: Stream = .{ .input = control };
    var handler: Handler = .{ .state = &state, .replace_then_fail = true };
    try t.expectError(error.ControlFailure, o.step(h, &stream, &handler, 2));
    try t.expectEqual(@as(u64, 8), state.generation);
    try t.expect(state.address != null and stream.retired);
}

test "disconnect during input revokes queued send and retires stream" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    try o.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var encoded: [64]u8 = undefined;
    const control = try hosted.frame(&encoded, 3, 1, "down");
    var stream: Stream = .{ .input = control };
    var handler: Handler = .{ .state = &state, .disconnect = true };
    try t.expectError(error.StaleHandle, o.step(h, &stream, &handler, 2));
    try t.expect(stream.retired and o.retired);
    try t.expectEqual(@as(usize, 0), stream.writes);
    try t.expectError(error.Retired, o.step(h, &stream, &handler, 3));
}

test "bounded receive copies one datagram and accounts for overflow" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    const dst = o.socket.sender.?.binding.local;
    var encoded: [1512]u8 = undefined;
    const one = try packet.prepare(&encoded, peer, dst, "first", 1);
    var copies: [3024]u8 = undefined;
    @memcpy(copies[0..one.len], one);
    @memcpy(copies[one.len .. 2 * one.len], one);
    var stream: Stream = .{ .input = copies[0 .. 2 * one.len] };
    var handler: Handler = .{ .state = &state };
    const p = try o.step(h, &stream, &handler, 1);
    try t.expectEqual(@as(u16, 2), p.frames);
    try t.expectEqual(@as(u16, 1), p.accepted);
    try t.expectEqual(@as(u16, 1), p.dropped);
    try t.expect(!stream.retired);
    var out: [10]u8 = undefined;
    const r = (try o.socket.read(h, &out)).?;
    try t.expectEqualStrings("first", out[0..r.bytes]);
}

test "partial writes require transport recovery" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    try o.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var stream: Stream = .{ .mode = .partial };
    var handler: Handler = .{ .state = &state };
    try t.expectError(error.PartialPacket, o.step(h, &stream, &handler, 2));
    try t.expect(stream.retired and o.retired);
    var out: [1]u8 = undefined;
    try t.expectError(error.StaleHandle, o.socket.read(h, &out));
}

test "fresh peer initialization retires socket before queued transmission" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    try o.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var encoded: [64]u8 = undefined;
    const init = try hosted.frame(&encoded, 5, 1, "init");
    var stream: Stream = .{ .input = init };
    var handler: Handler = .{ .state = &state };
    try t.expectError(error.Stale, o.step(h, &stream, &handler, 2));
    try t.expect(stream.retired and o.retired);
    try t.expect(state.address == null);
    try t.expectEqual(@as(usize, 0), handler.calls);
    try t.expectEqual(@as(usize, 0), stream.writes);
}

test "zero credit retries only after stream is drained" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    try o.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var stream: Stream = .{ .mode = .zero };
    var handler: Handler = .{ .state = &state };
    try t.expectEqual(owner.Send.pending, (try o.step(h, &stream, &handler, 2)).send);
    var encoded: [64]u8 = undefined;
    stream.input = try hosted.frame(&encoded, 3, 1, "control");
    stream.mode = .full;
    try t.expectEqual(owner.Send.pending, (try o.step(h, &stream, &handler, 3)).send);
    try t.expectEqual(@as(usize, 1), stream.writes);
    try t.expectEqual(owner.Send.sent, (try o.step(h, &stream, &handler, 4)).send);
}

test "expired queued send retires before touching transport" {
    var state = ready();
    var o: owner.Owner = .{};
    const h = try o.bind(&state, local, 49152, range);
    try o.socket.sendTo(h, peer, "hello", 1, 1, 10);
    var stream: Stream = .{};
    var handler: Handler = .{ .state = &state };
    try t.expectError(error.Deadline, o.step(h, &stream, &handler, 10));
    try t.expectEqual(@as(usize, 0), stream.reads);
    try t.expectEqual(@as(usize, 0), stream.writes);
    try t.expect(stream.retired and o.retired);
    try t.expect(state.address == null);
}

test "old handle cannot touch a replacement stream" {
    var state = ready();
    var o: owner.Owner = .{};
    const old = try o.bind(&state, local, 49152, range);
    try o.socket.close(old);
    const current = try o.bind(&state, local, 49152, range);
    var stream: Stream = .{};
    var handler: Handler = .{ .state = &state };
    try t.expectError(error.StaleHandle, o.step(old, &stream, &handler, 1));
    try t.expect(!o.retired and !stream.retired);
    _ = try o.step(current, &stream, &handler, 2);
}

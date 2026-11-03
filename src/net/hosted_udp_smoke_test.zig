const std = @import("std");
const t = std.testing;
const smoke = @import("hosted_udp_smoke.zig");
const socket = @import("hosted_udp_socket.zig");
const udp = @import("udp_ipv4.zig");
const peer = udp.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 44444 };
const handle = socket.Handle{ .generation = 7, .id = 1 };
const Io = struct {
    ready: bool = false,
    queued: usize = 0,
    closed: usize = 0,
    reject_peer: bool = false,
    response: enum { none, valid, wrong_peer, wrong_payload } = .none,
    pub fn bind(self: *@This(), port: u16) !socket.Handle {
        if (!self.ready) return error.NetworkUnavailable;
        if (port != 49152) return error.InvalidArgument;
        return handle;
    }
    pub fn send(self: *@This(), h: socket.Handle, destination: udp.Endpoint, data: []const u8, _: u64) !void {
        if (self.reject_peer) return error.PeerNotDirect;
        if (!std.meta.eql(h, handle) or !std.meta.eql(destination, peer) or data.len != smoke.payload_len) return error.InvalidArgument;
        var expected: [smoke.payload_len]u8 = undefined;
        smoke.payload(&expected);
        if (!std.mem.eql(u8, data, &expected)) return error.InvalidArgument;
        self.queued += 1;
    }
    pub fn read(self: *@This(), h: socket.Handle, out: []u8) !?socket.Received {
        if (!std.meta.eql(h, handle)) return error.InvalidArgument;
        if (self.response == .none) return null;
        var data: [smoke.payload_len]u8 = undefined;
        smoke.payload(&data);
        if (self.response == .wrong_payload) data[20] ^= 1;
        @memcpy(out[0..data.len], &data);
        const src = if (self.response == .wrong_peer) udp.Endpoint{ .ip = peer.ip, .mac = peer.mac, .port = 1 } else peer;
        self.response = .none;
        return .{ .source = src, .bytes = data.len };
    }
    pub fn close(self: *@This(), h: socket.Handle) !void {
        if (!std.meta.eql(h, handle)) return error.InvalidArgument;
        self.closed += 1;
    }
};

test "waits for link and requires exact peer and payload" {
    var p: smoke.Probe = .{};
    var io: Io = .{};
    try p.start(peer, 1, 100);
    p.step(&io, 2);
    try t.expectEqual(smoke.Phase.waiting_link, p.phase);
    io.ready = true;
    p.step(&io, 3);
    try t.expectEqual(@as(usize, 1), io.queued);
    io.response = .wrong_peer;
    p.step(&io, 4);
    io.response = .wrong_payload;
    p.step(&io, 5);
    try t.expectEqual(@as(u32, 2), p.snapshot().rejected);
    io.response = .valid;
    p.step(&io, 6);
    try t.expectEqual(smoke.Phase.passed, p.phase);
    try t.expectEqual(@as(u32, 1), p.snapshot().matched);
    try t.expectEqual(@as(usize, 1), io.closed);
    p.step(&io, 7);
    try t.expectEqual(@as(usize, 1), io.queued);
}

test "deadline closes pending socket and never retries" {
    var p: smoke.Probe = .{};
    var io: Io = .{ .ready = true };
    try p.start(peer, 1, 10);
    p.step(&io, 2);
    p.step(&io, 10);
    try t.expectEqual(smoke.Phase.failed, p.phase);
    try t.expectEqual(@as(u32, @intFromError(error.Deadline)), p.snapshot().error_code);
    try t.expectEqual(@as(usize, 1), io.closed);
    p.step(&io, 11);
    try t.expectEqual(@as(usize, 1), io.queued);
}

test "direct peer requires a valid matching subnet and usable address" {
    try t.expect(smoke.directPeer(0xc0000201, 0xffffff00, .{ 192, 0, 2, 2 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0xffffff00, .{ 192, 0, 3, 2 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0xffffff00, .{ 192, 0, 2, 1 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0xffffff00, .{ 192, 0, 2, 0 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0xffffff00, .{ 192, 0, 2, 255 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0xff00ff00, .{ 192, 0, 2, 2 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0, .{ 192, 0, 2, 2 }));
    try t.expect(!smoke.directPeer(0xc0000201, 0xffffffff, .{ 192, 0, 2, 2 }));
}

test "a non-direct peer fails and closes without queuing" {
    var p: smoke.Probe = .{};
    var io: Io = .{ .ready = true, .reject_peer = true };
    try p.start(peer, 1, 10);
    p.step(&io, 2);
    try t.expectEqual(smoke.Phase.failed, p.phase);
    try t.expectEqual(@as(u32, @intFromError(error.PeerNotDirect)), p.snapshot().error_code);
    try t.expectEqual(@as(usize, 0), io.queued);
    try t.expectEqual(@as(usize, 1), io.closed);
}

test "AP event matching validates nested BSSID and keeps malformed data unknown" {
    const expected = [6]u8{ 2, 3, 4, 5, 6, 7 };
    const matched = [_]u8{ 0x12, 8, 0x1a, 6, 2, 3, 4, 5, 6, 7 };
    const mismatch = [_]u8{ 0x12, 8, 0x1a, 6, 2, 3, 4, 5, 6, 8 };
    const short = [_]u8{ 0x12, 4, 0x1a, 2, 2, 3 };
    try t.expectEqual(@as(u32, 1), smoke.compareApEvent(&matched, expected));
    try t.expectEqual(@as(u32, 2), smoke.compareApEvent(&mismatch, expected));
    try t.expectEqual(@as(u32, 0), smoke.compareApEvent(&short, expected));
    try t.expectEqual(@as(u32, 0), smoke.compareApEvent(&matched, @splat(0)));
}

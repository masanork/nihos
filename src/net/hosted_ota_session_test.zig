const std = @import("std");
const wire = @import("hosted.zig");
const session = @import("hosted_ota_session.zig");
const Fake = struct {
    sent: usize = 0,
    response: [128]u8 = undefined,
    used: usize = 0,
    pub fn send(self: *@This(), frame: []const u8) !usize {
        self.sent += 1;
        if (frame[0] == 5) return frame.len;
        var r: wire.Reader = .{ .bytes = frame[24..] };
        var id: u32 = 0;
        var uid: u32 = 0;
        while (try r.next()) |f| {
            if (f.number == 2) id = @intCast(f.value);
            if (f.number == 3) uid = @intCast(f.value);
        }
        var buf: [64]u8 = undefined;
        var body_buf: [16]u8 = undefined;
        var body: wire.Writer = .{ .out = &body_buf };
        if (id == 350) {
            try body.uint(2, 1);
            try body.uint(3, 4);
            try body.uint(4, 1);
        }
        const payload = try wire.request(&buf, id + 256, uid, body.slice());
        buf[13] = 2;
        self.used = (try wire.frame(&self.response, 3, 0, payload)).len;
        return frame.len;
    }
    pub fn receive(self: *@This(), out: []u8) !usize {
        const n = self.used;
        @memcpy(out[0..n], self.response[0..n]);
        self.used = 0;
        return n;
    }
};
fn candidate() [40]u8 {
    var b: [40]u8 = @splat(0);
    b[0] = 0xe9;
    b[12] = 13;
    std.mem.writeInt(u32, b[32..36], 0xabcd5432, .little);
    return b;
}
fn start(bytes: []const u8) !session.Session {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return session.Session.init(bytes, h, 0, 100);
}
test "unsupported or unknown peer never receives OTA Begin" {
    const b = candidate();
    var s = try start(&b);
    var f: Fake = .{};
    s.client.phase = .done;
    s.client.peer_chip = 13;
    s.client.version_known = true;
    s.client.version = .{ 1, 4, 0 };
    try std.testing.expectError(error.UnsupportedPeer, s.step(&f, 1));
    try std.testing.expectEqual(@as(usize, 0), f.sent);
    try std.testing.expectEqual(session.State.failed, s.state);
}
test "handshake correlation is inherited by OTA and finishes only on End response" {
    const b = candidate();
    var s = try start(&b);
    var f: Fake = .{};
    s.client.phase = .done;
    s.client.peer_chip = 13;
    s.client.version_known = true;
    s.client.version = .{ 1, 4, 1 };
    s.client.uid = 12;
    try s.step(&f, 1);
    try std.testing.expectEqual(@as(usize, 0), f.sent);
    try s.step(&f, 2);
    try std.testing.expectEqual(@as(u32, 13), s.transfer.?.client.uid);
    var now: u64 = 3;
    while (s.state != .complete) : (now += 1) try s.step(&f, now);
    try std.testing.expectEqual(@as(usize, 3), f.sent);
}

test "complete simulated INIT version and OTA sequence" {
    const b = candidate();
    var s = try start(&b);
    var f: Fake = .{};
    f.used = (try wire.frame(&f.response, 5, 0, &.{ 0x22, 3, 0x12, 1, 13 })).len;
    var now: u64 = 1;
    while (s.state != .complete and now < 50) : (now += 1) try s.step(&f, now);
    try std.testing.expectEqual(session.State.complete, s.state);
    try std.testing.expectEqual(@as(usize, 5), f.sent);
}

test "in-place initialization checks candidate before touching transport" {
    const b = candidate();
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&b, &h, .{});
    var s: session.Session = undefined;
    try s.initInPlace(&b, h, 1, 100);
    try std.testing.expectEqual(session.State.handshake, s.state);
    try std.testing.expectEqual(@as(usize, 0), s.decoder.used);
    h[0] ^= 1;
    try std.testing.expectError(error.DigestMismatch, s.initInPlace(&b, h, 1, 100));
}

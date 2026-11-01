const std = @import("std");
const wire = @import("hosted.zig");
const guard = @import("hosted_ota_guard.zig");
const Fake = struct {
    sends: usize = 0,
    last_id: u32 = 0,
    response: [128]u8 = @splat(0),
    used: usize = 0,
    pub fn send(self: *@This(), bytes: []const u8) !usize {
        self.sends += 1;
        var reader: wire.Reader = .{ .bytes = bytes[24..] };
        var id: u32 = 0;
        var uid: u32 = 0;
        while (try reader.next()) |f| {
            if (f.number == 2) id = @intCast(f.value);
            if (f.number == 3) uid = @intCast(f.value);
        }
        self.last_id = id;
        var buf: [64]u8 = undefined;
        const payload = try wire.request(&buf, id + 256, uid, &.{});
        buf[13] = 2;
        self.used = (try wire.frame(&self.response, 3, 0, payload)).len;
        return bytes.len;
    }
    pub fn receive(self: *@This(), out: []u8) !usize {
        const n = self.used;
        @memcpy(out[0..n], self.response[0..n]);
        self.used = 0;
        return n;
    }
};
test "handshake completion cannot write until exact one-shot candidate token" {
    var image: [40]u8 = @splat(0);
    image[0] = 0xe9;
    image[12] = 13;
    std.mem.writeInt(u32, image[32..36], 0xabcd5432, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&image, &digest, .{});
    var g: guard.Guard = undefined;
    try g.initInPlace(&image, digest, 0, 100);
    g.session.client.phase = .done;
    g.session.client.peer_chip = 13;
    g.session.client.version_known = true;
    g.session.client.version = .{ 1, 4, 1 };
    var stream: Fake = .{};
    try std.testing.expectError(error.WrongState, g.feed('O', 1));
    try g.step(&stream, 1);
    try std.testing.expectEqual(guard.State.awaiting_start, g.state);
    try g.step(&stream, 2);
    try std.testing.expectEqual(@as(usize, 0), stream.sends);
    const hex = "0123456789abcdef";
    var token: [70]u8 = undefined;
    @memcpy(token[0..5], "OTA1 ");
    for (digest, 0..) |b, i| {
        token[5 + i * 2] = hex[b >> 4];
        token[6 + i * 2] = hex[b & 15];
    }
    token[69] = '\n';
    for (token[0..69]) |b| try std.testing.expect(!try g.feed(b, 3));
    try std.testing.expect(try g.feed(token[69], 3));
    try g.step(&stream, 4);
    try std.testing.expectEqual(@as(u32, 272), stream.last_id);
    try std.testing.expectEqual(@as(usize, 1), stream.sends);
    var now: u64 = 5;
    while (g.state != .complete) : (now += 1) try g.step(&stream, now);
    try std.testing.expectEqual(@as(usize, 3), stream.sends);
    try std.testing.expectError(error.WrongState, g.step(&stream, now));
}

test "invalid start token and expired deadline permanently stop writes" {
    var image: [40]u8 = @splat(0);
    image[0] = 0xe9;
    image[12] = 13;
    std.mem.writeInt(u32, image[32..36], 0xabcd5432, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&image, &digest, .{});
    var g: guard.Guard = undefined;
    var stream: Fake = .{};
    try g.initInPlace(&image, digest, 0, 10);
    g.session.client.phase = .done;
    g.session.client.peer_chip = 13;
    g.session.client.version_known = true;
    g.session.client.version = .{ 1, 4, 1 };
    try g.step(&stream, 1);
    try std.testing.expectError(error.InvalidToken, g.feed('\n', 2));
    try std.testing.expectEqual(guard.State.failed, g.state);
    try std.testing.expectError(error.WrongState, g.step(&stream, 3));
    try std.testing.expectEqual(@as(usize, 0), stream.sends);
    try g.initInPlace(&image, digest, 0, 10);
    g.session.client.phase = .done;
    g.session.client.peer_chip = 13;
    g.session.client.version_known = true;
    g.session.client.version = .{ 1, 4, 1 };
    try g.step(&stream, 1);
    try std.testing.expectError(error.Timeout, g.step(&stream, 10));
    try std.testing.expectEqual(guard.State.failed, g.state);
    try std.testing.expectEqual(@as(usize, 0), stream.sends);
}

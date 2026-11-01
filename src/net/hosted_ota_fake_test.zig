const std = @import("std");
const fake = @import("hosted_ota_fake.zig");
const ota = @import("hosted_ota.zig");
const pump = @import("hosted_ota_pump.zig");

test "P4 simulation verifies and acknowledges every candidate byte" {
    const image = try std.testing.allocator.alloc(u8, 1_079_120);
    defer std.testing.allocator.free(image);
    for (image, 0..) |*byte, i| byte.* = @truncate(i *% 29);
    image[0] = 0xe9;
    image[12] = 13;
    image[13] = 0;
    std.mem.writeInt(u32, image[32..36], 0xabcd5432, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
    var client = try ota.Client.init(image, digest, 9, 0);
    var driver = try pump.Pump.init(client, 0, 10_000);
    var peer: fake.Fake = .{ .image = image };
    var now: u64 = 1;
    while (driver.state != .complete) : (now += 1) try driver.step(&peer, now);
    try std.testing.expectEqual(image.len, peer.offset);
    try std.testing.expectEqual(@TypeOf(peer.phase).complete, peer.phase);
    try std.testing.expectEqual(image.len, driver.client.offset);
    _ = &client;
}
test "P4 simulation rejects a modified write before acknowledging" {
    const image = [_]u8{ 1, 2, 3 };
    var peer: fake.Fake = .{ .image = &image, .phase = .write, .last_uid = 1 };
    var body: [16]u8 = undefined;
    const wire = @import("hosted.zig");
    var writer: wire.Writer = .{ .out = &body };
    try writer.data(1, &.{ 1, 2, 4 });
    var message: [64]u8 = undefined;
    var frame: [128]u8 = undefined;
    const packet = try wire.frame(&frame, 3, 0, try wire.request(&message, 273, 2, writer.slice()));
    try std.testing.expectError(error.Malformed, peer.send(packet));
    try std.testing.expectEqual(@as(usize, 0), peer.offset);
    try std.testing.expectEqual(@as(usize, 0), peer.used);
}

const CounterStream = struct {
    calls: usize = 0,
    pub fn send(self: *@This(), bytes: []const u8) !usize {
        self.calls += 1;
        return bytes.len;
    }
    pub fn receive(_: *@This(), _: []u8) !usize {
        return 0;
    }
};
test "simulation physical transport blocks all OTA request IDs" {
    const wire = @import("hosted.zig");
    var inner: CounterStream = .{};
    var safe: fake.NoOtaStream(CounterStream) = .{ .inner = &inner };
    var message: [128]u8 = undefined;
    var frame: [160]u8 = undefined;
    for ([_]u32{ 266, 272, 273, 274 }) |id| {
        const payload = try wire.request(&message, id, 1, &.{});
        const packet = try wire.frame(&frame, 3, 0, payload);
        try std.testing.expectError(error.PersistentWriteForbidden, safe.send(packet));
    }
    try std.testing.expectEqual(@as(usize, 0), inner.calls);
    const payload = try wire.request(&message, 350, 1, &.{});
    const version = try wire.frame(&frame, 3, 0, payload);
    try std.testing.expectEqual(version.len, try safe.send(version));
    try std.testing.expectEqual(@as(usize, 1), inner.calls);
}
test "upgrade and recovery sizes transfer fully with the peer's activation protocol" {
    for ([_]struct { size: usize, explicit: bool }{
        .{ .size = 1_278_048, .explicit = false },
        .{ .size = 1_079_120, .explicit = true },
    }) |case| {
        const image = try std.testing.allocator.alloc(u8, case.size);
        defer std.testing.allocator.free(image);
        for (image, 0..) |*byte, i| byte.* = @truncate(i *% 17);
        image[0] = 0xe9;
        image[12] = 13;
        image[13] = 0;
        std.mem.writeInt(u32, image[32..36], 0xabcd5432, .little);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
        var client = try ota.Client.init(image, digest, 9, 0);
        if (case.explicit) client.activation = .explicit_rpc;
        var driver = try pump.Pump.init(client, 0, 10_000);
        var peer: fake.Fake = .{ .image = image, .explicit_activation = case.explicit };
        var now: u64 = 1;
        while (driver.state != .complete) : (now += 1) try driver.step(&peer, now);
        try std.testing.expectEqual(case.size, peer.offset);
        try std.testing.expectEqual(@TypeOf(peer.phase).complete, peer.phase);
    }
}

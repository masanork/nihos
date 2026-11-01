const std = @import("std");
const wire = @import("hosted.zig");
const ota = @import("hosted_ota.zig");
const pump = @import("hosted_ota_pump.zig");
const Fake = struct {
    requests: usize = 0,
    zero_once: bool = false,
    partial: bool = false,
    drop_next: bool = false,
    bytes: [512]u8 = @splat(0),
    used: usize = 0,
    pub fn send(self: *@This(), frame: []const u8) !usize {
        if (self.zero_once) {
            self.zero_once = false;
            return 0;
        }
        self.requests += 1;
        if (self.partial) return 1;
        if (self.drop_next) {
            self.drop_next = false;
            return frame.len;
        }
        var reader: wire.Reader = .{ .bytes = frame[24..] };
        var id: u32 = 0;
        var uid: u32 = 0;
        while (try reader.next()) |field| {
            if (field.number == 2) id = @intCast(field.value);
            if (field.number == 3) uid = @intCast(field.value);
        }
        var response: [128]u8 = undefined;
        const msg = try wire.request(&response, id + 256, uid, &.{});
        response[13] = 2;
        self.used = (try wire.frame(&self.bytes, 3, 0, msg)).len;
        return frame.len;
    }
    pub fn receive(self: *@This(), dest: []u8) !usize {
        const n = self.used;
        @memcpy(dest[0..n], self.bytes[0..n]);
        self.used = 0;
        return n;
    }
};
fn makeClient(bytes: []const u8) !ota.Client {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return ota.Client.init(bytes, hash, 0, 0);
}
test "complete OTA over simulated SDIO including zero credit" {
    var img: [810]u8 = @splat(42);
    img[0] = 0xe9;
    img[12] = 13;
    img[13] = 0;
    std.mem.writeInt(u32, img[32..36], 0xabcd5432, .little);
    var driver = try pump.Pump.init(try makeClient(&img), 0, 100);
    var stream: Fake = .{ .zero_once = true };
    var now: u64 = 1;
    while (driver.state != .complete) : (now += 1) try driver.step(&stream, now);
    try std.testing.expectEqual(@as(usize, 5), stream.requests);
    try std.testing.expectEqual(img.len, driver.client.offset);
    try std.testing.expectError(error.WrongState, driver.step(&stream, now));
}
test "partial send and timeout retire the transaction" {
    var img: [40]u8 = @splat(0);
    img[0] = 0xe9;
    img[12] = 13;
    std.mem.writeInt(u32, img[32..36], 0xabcd5432, .little);
    var driver = try pump.Pump.init(try makeClient(&img), 0, 5);
    var stream: Fake = .{ .partial = true };
    try std.testing.expectError(error.PartialPacket, driver.step(&stream, 1));
    try std.testing.expectEqual(pump.State.failed, driver.state);
    try std.testing.expectError(error.WrongState, driver.step(&stream, 2));
    driver = try pump.Pump.init(try makeClient(&img), 0, 5);
    stream = .{ .zero_once = true };
    try driver.step(&stream, 1);
    try std.testing.expectError(error.Timeout, driver.step(&stream, 5));
    try std.testing.expectEqual(pump.State.failed, driver.state);
    try std.testing.expectEqual(@as(usize, 0), stream.requests);
}

test "lost write acknowledgement is never replayed" {
    var image: [810]u8 = @splat(42);
    image[0] = 0xe9;
    image[12] = 13;
    image[13] = 0;
    std.mem.writeInt(u32, image[32..36], 0xabcd5432, .little);
    var driver = try pump.Pump.init(try makeClient(&image), 0, 6);
    var stream: Fake = .{};
    try driver.step(&stream, 1); // Begin sent.
    stream.drop_next = true;
    try driver.step(&stream, 2); // Begin acknowledged; first Write is lost.
    try std.testing.expectEqual(@as(usize, 2), stream.requests);
    try driver.step(&stream, 3);
    try driver.step(&stream, 4);
    try driver.step(&stream, 5);
    try std.testing.expectError(error.Timeout, driver.step(&stream, 6));
    try std.testing.expectEqual(@as(usize, 2), stream.requests);
    try std.testing.expectEqual(@as(usize, 0), driver.client.offset);
    try std.testing.expectEqual(pump.State.failed, driver.state);
}

const VerifyingPeer = struct {
    expected: []const u8,
    offset: usize = 0,
    writes: usize = 0,
    response: [128]u8 = @splat(0),
    used: usize = 0,
    pub fn send(self: *@This(), frame: []const u8) !usize {
        var reader: wire.Reader = .{ .bytes = frame[24..] };
        var id: u32 = 0;
        var uid: u32 = 0;
        var body: ?[]const u8 = null;
        while (try reader.next()) |field| {
            if (field.number == 2) id = @intCast(field.value);
            if (field.number == 3) uid = @intCast(field.value);
            if (field.number >= 256) body = field.bytes;
        }
        if (id == 273) {
            const chunk = (try wire.data(body orelse return error.Malformed, 1)) orelse return error.Malformed;
            if (chunk.len == 0 or chunk.len > ota.chunk_size or chunk.len > self.expected.len - self.offset) return error.Malformed;
            try std.testing.expectEqualSlices(u8, self.expected[self.offset..][0..chunk.len], chunk);
            self.offset += chunk.len;
            self.writes += 1;
        }
        var response: [64]u8 = undefined;
        const message = try wire.request(&response, id + 256, uid, &.{});
        response[13] = 2;
        self.used = (try wire.frame(&self.response, 3, 0, message)).len;
        return frame.len;
    }
    pub fn receive(self: *@This(), destination: []u8) !usize {
        const count = self.used;
        @memcpy(destination[0..count], self.response[0..count]);
        self.used = 0;
        return count;
    }
};
test "candidate-sized image is transferred exactly in bounded acknowledged chunks" {
    const image = try std.testing.allocator.alloc(u8, 1_079_120);
    defer std.testing.allocator.free(image);
    for (image, 0..) |*byte, i| byte.* = @truncate(i *% 37);
    image[0] = 0xe9;
    image[12] = 13;
    image[13] = 0;
    std.mem.writeInt(u32, image[32..36], 0xabcd5432, .little);
    var driver = try pump.Pump.init(try makeClient(image), 0, 10_000);
    var stream: VerifyingPeer = .{ .expected = image };
    var now: u64 = 1;
    while (driver.state != .complete) : (now += 1) try driver.step(&stream, now);
    try std.testing.expectEqual(image.len, stream.offset);
    try std.testing.expectEqual((image.len + ota.chunk_size - 1) / ota.chunk_size, stream.writes);
    try std.testing.expectEqual(image.len, driver.client.offset);
}

const std = @import("std");
const wire = @import("hosted.zig");
const ota = @import("hosted_ota.zig");
const pump = @import("hosted_ota_pump.zig");
const Fake = struct {
    requests: usize = 0,
    zero_once: bool = false,
    partial: bool = false,
    bytes: [512]u8 = undefined,
    used: usize = 0,
    pub fn send(self: *@This(), frame: []const u8) !usize {
        if (self.zero_once) {
            self.zero_once = false;
            return 0;
        }
        self.requests += 1;
        if (self.partial) return 1;
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

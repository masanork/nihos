const std = @import("std");
const wire = @import("hosted.zig");
const ota = @import("hosted_ota.zig");

fn image() [810]u8 {
    var bytes: [810]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i);
    bytes[0] = 0xe9;
    bytes[12] = 13;
    bytes[13] = 0;
    std.mem.writeInt(u32, bytes[32..36], 0xabcd5432, .little);
    return bytes;
}
fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn response(out: []u8, id: u32, uid: u32, body: []const u8) ![]const u8 {
    const result = try wire.request(out, id, uid, body);
    out[13] = 2;
    return result;
}
fn checkRequest(frame: []const u8, id: u32, uid: u32, expected: []const u8) !void {
    try std.testing.expect(frame.len <= 512);
    try std.testing.expectEqual(@as(u8, 3), frame[0]);
    var reader: wire.Reader = .{ .bytes = frame[24..] };
    var seen = false;
    while (try reader.next()) |field| {
        if (field.number == 2) try std.testing.expectEqual(id, field.value);
        if (field.number == 3) try std.testing.expectEqual(uid, field.value);
        if (field.number == id) {
            seen = true;
            if (id == 273) {
                try std.testing.expectEqualSlices(u8, expected, (try wire.data(field.bytes.?, 1)).?);
            } else try std.testing.expectEqual(@as(usize, 0), field.bytes.?.len);
        }
    }
    try std.testing.expect(seen);
}
test "full transaction correlates responses and sends exact sequential image bytes" {
    const bytes = image();
    var client = try ota.Client.init(&bytes, digest(&bytes), 8, 0);
    var reply: [128]u8 = undefined;
    try checkRequest(try client.next(), 272, 9, &.{});
    try std.testing.expectError(error.WrongState, client.next());
    try std.testing.expect(!try client.receive(.{ .interface = 3, .payload = try response(&reply, 528, 8, &.{}) }));
    try std.testing.expect(try client.receive(.{ .interface = 3, .payload = try response(&reply, 528, 9, &.{}) }));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = @min(ota.chunk_size, bytes.len - offset);
        try checkRequest(try client.next(), 273, client.uid, bytes[offset..][0..n]);
        try std.testing.expectEqual(offset, client.offset);
        try std.testing.expect(try client.receive(.{ .interface = 3, .payload = try response(&reply, 529, client.uid, &.{}) }));
        offset += n;
    }
    try checkRequest(try client.next(), 274, client.uid, &.{});
    try std.testing.expect(try client.receive(.{ .interface = 3, .payload = try response(&reply, 530, client.uid, &.{}) }));
    try std.testing.expectEqual(ota.Phase.complete, client.phase);
    try std.testing.expectError(error.WrongState, client.next());
}
test "image identity and failed or uncertain transactions fail closed" {
    var bytes = image();
    const hash = digest(&bytes);
    bytes[1] ^= 1;
    try std.testing.expectError(error.DigestMismatch, ota.Client.init(&bytes, hash, 0, 0));
    bytes[0] = 0;
    try std.testing.expectError(error.InvalidImage, ota.Client.init(&bytes, digest(&bytes), 0, 0));
    bytes = image();
    bytes[32] = 0; // A bootloader/full-flash image is not an app image.
    try std.testing.expectError(error.InvalidImage, ota.Client.init(&bytes, digest(&bytes), 0, 0));
    bytes = image();
    var client = try ota.Client.init(&bytes, digest(&bytes), 0, 0);
    _ = try client.next();
    var reply: [128]u8 = undefined;
    try std.testing.expectError(error.Rejected, client.receive(.{ .interface = 3, .payload = try response(&reply, 528, client.uid, &.{ 8, 1 }) }));
    try std.testing.expectError(error.WrongState, client.next());
    client = try ota.Client.init(&bytes, digest(&bytes), 0, 0);
    _ = try client.next();
    client.fail();
    try std.testing.expectError(error.WrongState, client.next());
    client = try ota.Client.init(&bytes, digest(&bytes), std.math.maxInt(u32), 0);
    try std.testing.expectError(error.UidExhausted, client.next());
}

test "image changed during transfer cannot be committed" {
    var bytes = image();
    var client = try ota.Client.init(&bytes, digest(&bytes), 0, 0);
    var reply: [128]u8 = undefined;
    _ = try client.next();
    _ = try client.receive(.{ .interface = 3, .payload = try response(&reply, 528, client.uid, &.{}) });
    while (client.phase == .write) {
        _ = try client.next();
        _ = try client.receive(.{ .interface = 3, .payload = try response(&reply, 529, client.uid, &.{}) });
    }
    bytes[42] ^= 1;
    try std.testing.expectError(error.DigestMismatch, client.next());
    try std.testing.expectEqual(ota.Phase.failed, client.phase);
}

const std = @import("std");
const time = @import("hosted_c6_time.zig");
const hosted = @import("hosted.zig");
fn event(storage: []u8, raw: []const u8) !hosted.Rpc {
    var w = hosted.Writer{ .out = storage };
    try w.uint(1, 0);
    try w.uint(2, 0x4e54_5152);
    try w.data(3, raw);
    return .{ .kind = 3, .id = 788, .uid = 0, .body = w.slice() };
}
fn result(id: u32, gen: u64, known: bool) [32]u8 {
    var raw: [32]u8 = @splat(0);
    raw[0] = 1;
    raw[1] = @intFromBool(known);
    std.mem.writeInt(u32, raw[4..8], id, .little);
    std.mem.writeInt(u64, raw[8..16], gen, .little);
    if (known) {
        std.mem.writeInt(u64, raw[16..24], 0x1122334455667788, .little);
        std.mem.writeInt(u32, raw[24..28], 42, .little);
    }
    return raw;
}
test "matching synchronized and unsynchronized snapshots" {
    var s = time.Session{};
    s.reset(0x0102030405060708);
    var req: [128]u8 = undefined;
    var ev: [128]u8 = undefined;
    _ = try s.start(&req, 1, 10, 20);
    try std.testing.expectError(error.Busy, s.start(&req, 2, 10, 20));
    const raw = result(1, 0x0102030405060708, true);
    const sample = (try s.receive(try event(&ev, &raw), 19)).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), sample.seconds);
    try std.testing.expectEqual(@as(u32, 42), sample.age_seconds);
    _ = try s.start(&req, 2, 20, 30);
    const unknown = result(2, 0x0102030405060708, false);
    try std.testing.expect((try s.receive(try event(&ev, &unknown), 21)) == null);
}
test "stale generations, malformed and expired events cannot consume request" {
    var s = time.Session{};
    s.reset(10);
    var req: [128]u8 = undefined;
    var ev: [128]u8 = undefined;
    _ = try s.start(&req, 1, 1, 5);
    var raw = result(1, 9, true);
    try std.testing.expectError(error.Stale, s.receive(try event(&ev, &raw), 2));
    raw = result(1, 10, true);
    raw[28] = 1;
    try std.testing.expectError(error.Malformed, s.receive(try event(&ev, &raw), 2));
    raw = result(1, 10, true);
    try std.testing.expectError(error.Deadline, s.receive(try event(&ev, &raw), 5));
    _ = try s.start(&req, 2, 5, 8);
    s.reset(11);
    try std.testing.expectError(error.Stale, s.receive(try event(&ev, &raw), 6));
}
test "unknown snapshot must not carry an old clock" {
    var s = time.Session{};
    s.reset(1);
    var req: [128]u8 = undefined;
    var ev: [128]u8 = undefined;
    _ = try s.start(&req, 1, 0, 5);
    var raw = result(1, 1, false);
    raw[16] = 1;
    try std.testing.expectError(error.Malformed, s.receive(try event(&ev, &raw), 1));
}
test "C and Zig share the exact 32-byte result vector" {
    var s = time.Session{};
    s.reset(0x0102030405060708);
    s.next_id = 0x12345678;
    var req: [128]u8 = undefined;
    var ev: [128]u8 = undefined;
    _ = try s.start(&req, 1, 1, 5);
    const golden = [_]u8{ 1, 1, 0, 0, 0x78, 0x56, 0x34, 0x12, 8, 7, 6, 5, 4, 3, 2, 1, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 42, 0, 0, 0, 0, 0, 0, 0 };
    const sample = (try s.receive(try event(&ev, &golden), 2)).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), sample.seconds);
    try std.testing.expectEqual(@as(u32, 42), sample.age_seconds);
}
test "request contains the C parser's exact golden bytes" {
    var s = time.Session{};
    s.reset(0x0102030405060708);
    s.next_id = 0x12345678;
    var output: [128]u8 = undefined;
    const packet = try s.start(&output, 12, 1, 3);
    var outer = hosted.Reader{ .bytes = packet[12..] };
    var payload: ?[]const u8 = null;
    while (try outer.next()) |field| if (field.number == 388) {
        payload = field.bytes;
    };
    var custom = hosted.Reader{ .bytes = payload.? };
    var request: ?[]const u8 = null;
    while (try custom.next()) |field| if (field.number == 2) {
        request = field.bytes;
    };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0x78, 0x56, 0x34, 0x12, 8, 7, 6, 5, 4, 3, 2, 1 }, request.?);
}
test "cancelled request cannot accept a delayed event" {
    var s = time.Session{};
    s.reset(7);
    var req: [128]u8 = undefined;
    var ev: [128]u8 = undefined;
    _ = try s.start(&req, 1, 0, 5);
    s.cancel();
    const raw = result(1, 7, true);
    try std.testing.expectError(error.Stale, s.receive(try event(&ev, &raw), 1));
    _ = try s.start(&req, 2, 1, 5);
    try std.testing.expectError(error.Stale, s.receive(try event(&ev, &raw), 2));
}

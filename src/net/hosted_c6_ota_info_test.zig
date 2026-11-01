const std = @import("std");
const wire = @import("hosted.zig");
const info = @import("hosted_c6_ota_info.zig");

fn event(raw: []const u8, out: []u8) !wire.Rpc {
    var writer: wire.Writer = .{ .out = out };
    try writer.uint(2, info.result_id);
    try writer.data(3, raw);
    return .{ .kind = 3, .id = 788, .uid = 1, .body = writer.slice() };
}
test "C6-generated OTA info decodes bounded partition and security status" {
    var b: [128]u8 = undefined;
    const result = try info.parseEvent(try event(@embedFile("fixtures/hosted-ota-info-v1.bin"), &b), 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x400000), result.flash_size);
    try std.testing.expectEqual(@as(u32, 0x10000), result.running.offset);
    try std.testing.expectEqual(@as(u32, 0x190000), result.next.offset);
    try std.testing.expectEqual(@as(u32, 0x180000), result.next.size);
    try std.testing.expectEqual(@as(?u32, 2), result.running_state);
    try std.testing.expect(!result.secure_boot and !result.flash_encrypted);
}
test "OTA info rejects stale, incomplete and out-of-range snapshots" {
    const fixture = @embedFile("fixtures/hosted-ota-info-v1.bin");
    var b: [128]u8 = undefined;
    try std.testing.expectError(error.Stale, info.parseEvent(try event(fixture, &b), 9));
    var raw: [40]u8 = fixture.*;
    raw[1] &= ~@as(u8, 4);
    try std.testing.expectError(error.Incomplete, info.parseEvent(try event(&raw, &b), 0x12345678));
    raw = fixture.*;
    std.mem.writeInt(u32, raw[28..32], 0x10000, .little);
    try std.testing.expectError(error.Malformed, info.parseEvent(try event(&raw, &b), 0x12345678));
    raw = fixture.*;
    std.mem.writeInt(u32, raw[32..36], 0xffffffff, .little);
    try std.testing.expectError(error.Malformed, info.parseEvent(try event(&raw, &b), 0x12345678));
    raw = fixture.*;
    raw[2] = 1;
    try std.testing.expectError(error.Malformed, info.parseEvent(try event(&raw, &b), 0x12345678));
}
test "OTA info request has a nonzero nonce and uses custom RPC" {
    var out: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, info.request(&out, 1, 0));
    const packet = try info.request(&out, 7, 0x12345678);
    var reader: wire.Reader = .{ .bytes = packet[12..] };
    var id: u32 = 0;
    var uid: u32 = 0;
    var body: ?[]const u8 = null;
    while (try reader.next()) |field| switch (field.number) {
        2 => id = @intCast(field.value),
        3 => uid = @intCast(field.value),
        388 => body = field.bytes,
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 388), id);
    try std.testing.expectEqual(@as(u32, 7), uid);
    try std.testing.expectEqual(info.request_id, try wire.integer(body.?, 1));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0x78, 0x56, 0x34, 0x12 }, (try wire.data(body.?, 2)).?);
}
test "OTA info requires correlated acknowledgement and result in either order" {
    for ([_]bool{ false, true }) |event_first| {
        var session: info.Session = .{};
        var out: [128]u8 = undefined;
        _ = try session.start(&out, 7, 0x12345678, 1, 100);
        const ack: wire.Rpc = .{ .kind = 2, .id = 644, .uid = 7, .body = &.{} };
        var b: [128]u8 = undefined;
        const reply = try event(@embedFile("fixtures/hosted-ota-info-v1.bin"), &b);
        try session.receive(if (event_first) reply else ack, 2);
        try std.testing.expectEqual(@TypeOf(session.phase).waiting, session.phase);
        try session.receive(if (event_first) ack else reply, 3);
        try std.testing.expectEqual(@TypeOf(session.phase).complete, session.phase);
        try std.testing.expect(session.result != null);
    }
}
test "OTA info invalidates on timeout, bad acknowledgement or duplicate event" {
    var session: info.Session = .{};
    var out: [128]u8 = undefined;
    _ = try session.start(&out, 7, 0x12345678, 1, 10);
    try std.testing.expect(session.expire(10));
    try std.testing.expectEqual(@TypeOf(session.phase).failed, session.phase);
    session = .{};
    _ = try session.start(&out, 7, 0x12345678, 1, 10);
    try std.testing.expectError(error.Stale, session.receive(.{ .kind = 2, .id = 644, .uid = 8, .body = &.{} }, 2));
    try std.testing.expect(session.result == null);
    session = .{};
    _ = try session.start(&out, 7, 0x12345678, 1, 10);
    var b: [128]u8 = undefined;
    const reply = try event(@embedFile("fixtures/hosted-ota-info-v1.bin"), &b);
    try session.receive(reply, 2);
    try std.testing.expectError(error.Stale, session.receive(reply, 3));
    try std.testing.expect(session.result == null);
}

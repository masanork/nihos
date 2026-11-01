//! Derived from nihos commit 0b066228, experimental custom-C6 Network Split tests.
const std = @import("std");
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");

const sample = split.Address{
    .ip = 0xc0a8070c,
    .mask = 0xffffff00,
    .gateway = 0xc0a80701,
    .dns = 0xc0a80701,
};

fn padded(text: []const u8) [64]u8 {
    var result: [64]u8 = @splat(0);
    @memcpy(result[0..text.len], text);
    return result;
}

fn statusBody(out: []u8, address: ?split.Address) ![]const u8 {
    var writer = hosted.Writer{ .out = out };
    if (address) |value| {
        try writer.uint(2, 1);
        try writer.uint(3, 1);
        const ip = padded(if (value.ip == sample.ip) "192.168.7.12" else "192.168.7.13");
        const mask = padded("255.255.255.0");
        const gateway = padded("192.168.7.1");
        const dns = padded("192.168.7.1");
        try writer.data(4, &ip);
        try writer.data(5, &mask);
        try writer.data(6, &gateway);
        try writer.uint(7, 1);
        try writer.data(8, &dns);
    } else {
        const zeros: [64]u8 = @splat(0);
        try writer.data(4, &zeros);
        try writer.data(5, &zeros);
        try writer.data(6, &zeros);
        try writer.data(8, &zeros);
    }
    return writer.slice();
}

fn event(out: []u8, body: []const u8) ![]const u8 {
    var writer = hosted.Writer{ .out = out[12..] };
    try writer.uint(1, 3);
    try writer.uint(2, split.event_id);
    try writer.data(split.event_id, body);
    @memcpy(out[0..10], &[_]u8{ 1, 6, 0, 'R', 'P', 'C', 'E', 'v', 't', 2 });
    std.mem.writeInt(u16, out[10..12], @intCast(writer.used), .little);
    return out[0 .. 12 + writer.used];
}

test "padded v2.13.1 DHCP event establishes one generation" {
    var body_buffer: [320]u8 = undefined;
    const body = try statusBody(&body_buffer, sample);
    var envelope: [384]u8 = undefined;
    const message = try hosted.rpc(try event(&envelope, body));
    var state: split.State = .{};
    try std.testing.expectEqual(split.Outcome.changed, state.receive(message));
    try std.testing.expectEqual(@as(u64, 1), state.generation);
    try std.testing.expectEqual(sample, state.current(1).?);
    try std.testing.expect(state.current(0) == null);
    try std.testing.expectEqual(split.Outcome.unchanged, state.receive(message));
    try std.testing.expectEqual(@as(u64, 1), state.generation);
}

test "status query is UID-correlated and accepts variable response strings" {
    var request_buffer: [64]u8 = undefined;
    const request = try split.statusRequest(&request_buffer, 42);
    try std.testing.expectEqualStrings("RPCRsp", request[3..9]);
    var request_reader = hosted.Reader{ .bytes = request[12..] };
    var body_seen = false;
    while (try request_reader.next()) |field| if (field.number == split.request_id) {
        try std.testing.expectEqual(@as(usize, 0), field.bytes.?.len);
        body_seen = true;
    };
    try std.testing.expect(body_seen);

    var body_buffer: [96]u8 = undefined;
    var writer = hosted.Writer{ .out = &body_buffer };
    try writer.uint(2, 1);
    try writer.uint(3, 1);
    try writer.data(4, "192.168.7.12\x00");
    try writer.data(5, "255.255.255.0\x00");
    try writer.data(6, "192.168.7.1\x00");
    try writer.uint(7, 1);
    try writer.data(8, "192.168.7.1\x00");
    const response = hosted.Rpc{ .kind = 2, .id = split.response_id, .uid = 42, .body = writer.slice() };
    var state: split.State = .{};
    try std.testing.expectEqual(split.Outcome.ignored, state.receiveResponse(response, 41));
    try std.testing.expectEqual(split.Outcome.changed, state.receiveResponse(response, 42));
    try std.testing.expectEqual(sample, state.address.?);
}

test "address change and all-zero down event revoke old generations" {
    var first_buffer: [320]u8 = undefined;
    var second_buffer: [320]u8 = undefined;
    var down_buffer: [320]u8 = undefined;
    const changed = split.Address{ .ip = 0xc0a8070d, .mask = sample.mask, .gateway = sample.gateway, .dns = sample.dns };
    var state: split.State = .{};
    _ = state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = try statusBody(&first_buffer, sample) });
    try std.testing.expectEqual(split.Outcome.changed, state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = try statusBody(&second_buffer, changed) }));
    try std.testing.expectEqual(@as(u64, 2), state.generation);
    try std.testing.expectEqual(changed, state.current(2).?);
    try std.testing.expectEqual(split.Outcome.changed, state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = try statusBody(&down_buffer, null) }));
    try std.testing.expectEqual(@as(u64, 3), state.generation);
    try std.testing.expect(state.address == null);
    try std.testing.expectEqual(split.Outcome.unchanged, state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = &.{} }));
}

test "malformed status cannot replace the active address" {
    var good_buffer: [320]u8 = undefined;
    var state: split.State = .{};
    _ = state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = try statusBody(&good_buffer, sample) });
    const generation = state.generation;
    const bad = [_][]const u8{
        &.{ 8, 1 }, // AP interface.
        &.{ 16, 1, 24, 1 }, // Partial-up status.
        &.{ 80, 1 }, // Failed response.
        &.{ 88, 0 }, // Unknown field 11.
        &.{ 16, 1, 16, 1 }, // Duplicate field.
        &.{ 18, 1, 1 }, // Scalar field with bytes wire type.
    };
    for (bad) |body| try std.testing.expectEqual(split.Outcome.rejected, state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = body }));
    try std.testing.expectEqual(generation, state.generation);
    try std.testing.expectEqual(sample, state.address.?);
    try std.testing.expectEqual(@as(u32, bad.len), state.rejected);
}

test "invalid address padding mask subnet and DNS are rejected" {
    const values = [_]struct { ip: []const u8, mask: []const u8, gateway: []const u8, dns: []const u8 }{
        .{ .ip = "192.168.7.12", .mask = "255.0.255.0", .gateway = "192.168.7.1", .dns = "192.168.7.1" },
        .{ .ip = "192.168.7.12", .mask = "255.255.255.0", .gateway = "192.168.8.1", .dns = "192.168.7.1" },
        .{ .ip = "192.168.7.12", .mask = "255.255.255.0", .gateway = "192.168.7.1", .dns = "224.0.0.1" },
    };
    for (values) |value| {
        var bytes: [320]u8 = undefined;
        var writer = hosted.Writer{ .out = &bytes };
        try writer.uint(2, 1);
        try writer.uint(3, 1);
        try writer.data(4, value.ip);
        try writer.data(5, value.mask);
        try writer.data(6, value.gateway);
        try writer.uint(7, 1);
        try writer.data(8, value.dns);
        try std.testing.expectError(error.InvalidAddress, split.decode(writer.slice()));
    }
    var padded_bad = padded("192.168.7.12");
    padded_bad[63] = 1;
    var bytes: [320]u8 = undefined;
    var writer = hosted.Writer{ .out = &bytes };
    try writer.uint(2, 1);
    try writer.uint(3, 1);
    try writer.data(4, &padded_bad);
    try writer.data(5, "255.255.255.0");
    try writer.data(6, "192.168.7.1");
    try writer.uint(7, 1);
    try writer.data(8, "192.168.7.1");
    try std.testing.expectError(error.Malformed, split.decode(writer.slice()));
}

test "unrelated RPC is ignored and generation exhaustion is fail-closed" {
    var bytes: [320]u8 = undefined;
    const body = try statusBody(&bytes, sample);
    var state = split.State{ .generation = std.math.maxInt(u64) };
    try std.testing.expectEqual(split.Outcome.ignored, state.receive(.{ .kind = 2, .id = split.event_id, .uid = 1, .body = body }));
    try std.testing.expectEqual(split.Outcome.ignored, state.receive(.{ .kind = 3, .id = 775, .uid = 0, .body = body }));
    try std.testing.expectEqual(split.Outcome.rejected, state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = body }));
    try std.testing.expect(state.address == null);
    try std.testing.expectEqual(std.math.maxInt(u64), state.generation);
}

test "transport invalidation revokes an address without waiting for down event" {
    var bytes: [320]u8 = undefined;
    var state: split.State = .{};
    _ = state.receive(.{ .kind = 3, .id = split.event_id, .uid = 0, .body = try statusBody(&bytes, sample) });
    const old = state.generation;
    try std.testing.expect(state.invalidate());
    try std.testing.expectEqual(old + 1, state.generation);
    try std.testing.expect(state.current(old) == null);
    try std.testing.expect(state.address == null);

    state.generation = std.math.maxInt(u64);
    try std.testing.expect(!state.invalidate());
    try std.testing.expect(state.address == null);
}

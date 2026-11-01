const std = @import("std");
const wire = @import("hosted.zig");
const desc = @import("hosted_c6_app_desc.zig");
fn response(out: []u8, version: []const u8, digest: ?[]const u8) !wire.Rpc {
    var nested_bytes: [160]u8 = undefined;
    var nested: wire.Writer = .{ .out = &nested_bytes };
    try nested.data(4, version);
    try nested.data(5, "network_adapter\x00");
    try nested.data(8, "v5.5.2\x00");
    if (digest) |d| try nested.data(9, d);
    var body: wire.Writer = .{ .out = out };
    try body.data(2, nested.slice());
    return .{ .kind = 2, .id = desc.response_id, .uid = 17, .body = body.slice() };
}
test "application description accepts legacy NUL and optional ELF hash" {
    var buffer: [256]u8 = undefined;
    const d = try desc.parse(try response(&buffer, "2.13.1\x00", null), 17);
    try std.testing.expectEqualStrings("2.13.1", d.version.slice());
    try std.testing.expectEqualStrings("network_adapter", d.project.slice());
    try std.testing.expectEqualStrings("v5.5.2", d.idf.slice());
    try std.testing.expect(d.elf_sha256 == null);
    const digest: [32]u8 = @splat(0x42);
    const full = try desc.parse(try response(&buffer, "3.0.10", &digest), 17);
    try std.testing.expectEqualSlices(u8, &digest, &full.elf_sha256.?);
}
test "application description rejects stale or malformed metadata" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(error.Stale, desc.parse(try response(&buffer, "ok", null), 18));
    try std.testing.expectError(error.Malformed, desc.parse(try response(&buffer, "bad\x00name", null), 17));
    try std.testing.expectError(error.Malformed, desc.parse(try response(&buffer, "ok", &.{1}), 17));
    try std.testing.expectError(error.Malformed, desc.parse(try response(&buffer, "", null), 17));
}

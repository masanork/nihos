const std = @import("std");
const wire = @import("hosted.zig");
const diag = @import("hosted_diagnostics.zig");

test "factory response has no extension; candidate reports uptime and heap" {
    var buf: [64]u8 = undefined;
    var w: wire.Writer = .{ .out = &buf };
    try w.uint(2, 1);
    try w.uint(3, 4);
    try w.uint(4, 1);
    try std.testing.expect((try diag.parse(w.slice())) == null);
    try w.uint(100, 1);
    try w.uint(101, 125);
    try w.uint(102, 134217);
    const d = (try diag.parse(w.slice())).?;
    try std.testing.expectEqual(@as(u32, 125), d.uptime_seconds);
    try std.testing.expectEqual(@as(u32, 134217), d.free_heap_bytes);
    try w.uint(102, 1);
    try std.testing.expectError(error.Malformed, diag.parse(w.slice()));
}

test "incomplete and malformed extensions cannot appear as diagnostics" {
    var buf: [64]u8 = undefined;
    var w: wire.Writer = .{ .out = &buf };
    try w.uint(100, 1);
    try w.uint(101, 0);
    try std.testing.expectError(error.Malformed, diag.parse(w.slice()));
    try w.data(102, "oops");
    try std.testing.expectError(error.Malformed, diag.parse(w.slice()));
}

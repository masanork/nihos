//! Shared pinned monospace face, independent of platform font APIs.
//! Uses the same Source Code Pro revision as the generated console masks.
const std = @import("std");
pub const ttf = @import("ttf.zig");
pub const bytes: []const u8 = @embedFile("ascii/nihos-code.ttf");
pub fn face() ttf.Error!ttf.Face {
    return ttf.Face.init(ttf.SliceReader.fromSlice(&bytes));
}

test "shared code face has a genuine monospace advance and rasterizes printable ASCII" {
    const font_face = try face();
    const family = ttf.Family{ .faces = &.{font_face} };
    var cache: ttf.TwoTierCache(8, 1024, 8, 96 * 96) = .{};
    var scratch: [16384]u8 = undefined;
    for (32..127) |cp| {
        const glyph = try cache.getOrRender(family, 0, @intCast(cp), 0, 25, false, &scratch);
        try std.testing.expectEqual(@as(i32, 15 * 64), glyph.metrics.x_advance_26_6);
        if (cp != ' ') try std.testing.expect(glyph.metrics.width > 0);
    }
}

test "sideways ASCII rotates ink and preserves horizontal spacing at every book size" {
    const font_face = try face();
    const family = ttf.Family{ .faces = &.{font_face} };
    var cache: ttf.TwoTierCache(4, 1024, 4, 96 * 96) = .{};
    var scratch: [16384]u8 = undefined;
    for ([_]u8{ 16, 25, 32, 64 }) |size| for (33..127) |cp| {
        const h = try cache.getOrRender(family, 0, @intCast(cp), 0, size, false, &scratch);
        const v = try cache.getOrRender(family, 0, @intCast(cp), 0, size, true, &scratch);
        try std.testing.expectEqual(-h.metrics.x_advance_26_6, v.metrics.y_advance_26_6);
        try std.testing.expectEqual(@as(i32, 0), v.metrics.x_advance_26_6);
        // Rotating a non-square ink box swaps its dimensions. Raster rounding
        // can add one edge pixel; an upright glyph cannot pass this for F/I/_ .
        try std.testing.expect(@abs(@as(i32, h.metrics.width) - v.metrics.height) <= 1);
        try std.testing.expect(@abs(@as(i32, h.metrics.height) - v.metrics.width) <= 1);
        const again = try cache.getOrRender(family, 0, @intCast(cp), 0, size, false, &scratch);
        try std.testing.expectEqualDeep(h.metrics, again.metrics);
    };
    try std.testing.expectEqual(ttf.VerticalTransform.none, ttf.VerticalTransform.forCodepoint('日'));
    try std.testing.expectEqual(ttf.VerticalTransform.shift_top_right, ttf.VerticalTransform.forCodepoint('。'));
}

test "ASCII recovery subset preserves every rendered pixel of the pinned original" {
    const original_bytes: []const u8 = @embedFile("ascii/SourceCodePro-Medium.ttf");
    const original = try ttf.Face.init(ttf.SliceReader.fromSlice(&original_bytes));
    const recovery = try face();
    var left: ttf.TwoTierCache(2, 1024, 2, 128 * 128) = .{};
    var right: ttf.TwoTierCache(2, 1024, 2, 128 * 128) = .{};
    var scratch: [32768]u8 = undefined;
    for ([_]u8{ 8, 25, 64, 96 }) |size| for ([_]bool{ false, true }) |vertical| for (32..127) |cp| {
        const a = try left.getOrRender(.{ .faces = &.{original} }, 0, @intCast(cp), 0, size, vertical, &scratch);
        const b = try right.getOrRender(.{ .faces = &.{recovery} }, 0, @intCast(cp), 0, size, vertical, &scratch);
        try std.testing.expectEqualDeep(a.metrics, b.metrics);
        try std.testing.expectEqualSlices(u8, a.alpha, b.alpha);
    };
}

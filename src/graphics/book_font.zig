//! Century Schoolbook lineage: renamed quadratic TeX Gyre Schola Latin subset.
pub const ttf = @import("ttf.zig");
pub const bytes: []const u8 = @embedFile("serif/nihos-book-serif.ttf");
pub fn face() ttf.Error!ttf.Face {
    return ttf.Face.init(ttf.SliceReader.fromSlice(&bytes));
}

test "book serif is proportional while source retains its monospace metrics" {
    const std = @import("std");
    const book = try face();
    const code = try @import("code_font.zig").face();
    const family = ttf.Family{ .faces = &.{book}, .code_faces = &.{code} };
    var cache: ttf.TwoTierCache(8, 1024, 8, 128 * 128) = .{};
    var scratch: [32768]u8 = undefined;
    const thin = try cache.getOrRender(family, 2, 'i', 0, 32, false, &scratch);
    const wide = try cache.getOrRender(family, 2, 'W', 0, 32, false, &scratch);
    try std.testing.expect(thin.metrics.x_advance_26_6 < wide.metrics.x_advance_26_6);
    const a = try cache.getOrRender(family, 3, 'i', 0, 32, false, &scratch);
    const b = try cache.getOrRender(family, 3, 'W', 0, 32, false, &scratch);
    try std.testing.expectEqual(a.metrics.x_advance_26_6, b.metrics.x_advance_26_6);
    for ([_]u8{ 16, 25, 32, 64 }) |size| for (32..127) |cp| {
        const g = try cache.getOrRender(family, 2, @intCast(cp), 0, size, false, &scratch);
        if (cp != ' ') try std.testing.expect(g.metrics.width > 0);
    };
}

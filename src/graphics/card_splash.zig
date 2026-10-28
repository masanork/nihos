//! Fixed TTB inscription using the shared RGB565/A8 surface compositor.
//! No font worker, allocation or display ownership at boot.
const std = @import("std");
const surface = @import("surface");
const assets = @import("card_boot/assets.zig");
pub const width = 720;
pub const height = 1280;
pub const background: u16 = rgb565(0x192424);
pub fn rgb565(value: u32) u16 {
    return @intCast(((value >> 19) & 31) << 11 | ((value >> 10) & 63) << 5 | ((value >> 3) & 31));
}
pub inline fn paint(comptime section: ?[]const u8, frame: []u8, stride: usize) bool {
    const Store = if (section) |name| struct {
        const data: [assets.masks.len]u8 align(16) linksection(name ++ ".mask") = assets.masks.*;
        const glyphs: [assets.glyphs.len]assets.Mask linksection(name ++ ".meta") = assets.glyphs;
        const placements: [assets.placements.len]assets.Placement linksection(name ++ ".meta") = assets.placements;
    } else struct {
        const data = assets.masks.*;
        const glyphs = assets.glyphs;
        const placements = assets.placements;
    };
    const target = surface.Surface.init(frame, width, height, stride) orelse return false;
    // Validate the immutable stream completely before touching the target.
    for (Store.glyphs) |g| {
        if (g.width > width or g.offset > Store.data.len or g.length > Store.data.len - g.offset) return false;
        var pixels: usize = 0;
        for (Store.data[g.offset..][0..g.length]) |run| pixels += @as(usize, run & 15) + 1;
        if (pixels != @as(usize, g.width) * g.height) return false;
    }
    for (Store.placements) |p| {
        if (p.mask >= Store.glyphs.len) return false;
        const g = Store.glyphs[p.mask];
        if (p.x > width or g.width > width - p.x or p.y > height or g.height > height - p.y) return false;
    }
    if (!@call(.always_inline, surface.Surface.fill, .{ target, background })) return false;
    var row: [width]u8 = undefined;
    for (Store.placements) |p| {
        const g = Store.glyphs[p.mask];
        var x: usize = 0;
        var y: usize = 0;
        for (Store.data[g.offset..][0..g.length]) |run| {
            for (0..@as(usize, run & 15) + 1) |_| {
                row[x] = @as(u8, run >> 4) * 17;
                x += 1;
                if (x == g.width) {
                    if (!@call(.always_inline, surface.Surface.blit, .{ target, surface.Mask{ .bytes = row[0..g.width], .width = g.width, .height = 1, .stride = g.width }, @as(i32, p.x), @as(i32, @intCast(@as(usize, p.y) + y)), rgb565(p.color) })) return false;
                    x = 0;
                    y += 1;
                }
            }
        }
    }
    // Flat rails use the same compositor without an extra bitmap.
    @memset(row[0..616], 255);
    if (!@call(.always_inline, surface.Surface.blit, .{ target, surface.Mask{ .bytes = row[0..616], .width = 616, .height = 1, .stride = 616 }, 52, 125, rgb565(0x40504a) })) return false;
    return true;
}

test "portrait boot rejects invalid geometry before writing and preserves stride guards" {
    const allocator = std.testing.allocator;
    const stride = width * 2 + 16;
    const bytes = try allocator.alloc(u8, stride * height + 32);
    defer allocator.free(bytes);
    @memset(bytes, 0xa5);
    try std.testing.expect(!paint(null, bytes[16..][0 .. stride * height - 1], stride));
    try std.testing.expect(std.mem.allEqual(u8, bytes, 0xa5));
    try std.testing.expect(paint(null, bytes[16..][0 .. stride * height], stride));
    try std.testing.expect(std.mem.allEqual(u8, bytes[0..16], 0xa5));
    try std.testing.expect(std.mem.allEqual(u8, bytes[bytes.len - 16 ..], 0xa5));
    for (0..height) |y| try std.testing.expect(std.mem.allEqual(u8, bytes[16 + y * stride + width * 2 ..][0..16], 0xa5));
}

//! Differential check of PIN indicator pixels, without touching the card path.
const std = @import("std");
const pin = @import("card_pin.zig");
const canvas = @import("canvas.zig");
const rgb = @import("test_pattern.zig").rgb565;

test "canvas matches all PIN indicator counts from production dynamic renderer" {
    const rect = pin.dots_rect;
    const bytes = @as(usize, rect.width) * rect.height * 2;
    const old = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(old);
    const new = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(new);
    const label_rect = pin.submitRect();
    const label = try std.testing.allocator.alloc(u8, @as(usize, label_rect.width) * label_rect.height * 2);
    defer std.testing.allocator.free(label);
    for (0..5) |count| {
        @memset(old, 0xa5);
        @memset(new, 0xa5);
        try std.testing.expect(pin.paintDynamic(null, old, label, .{ .active = true, .masked_digits = @intCast(count), .remaining = 3, .can_submit = count == 4 }));
        const c = canvas.Canvas.init(new, rect.width, rect.height, @as(usize, rect.width) * 2).?;
        c.fillRect(.{ .x = 0, .y = 0, .width = rect.width, .height = rect.height }, pin.paper_color);
        for (0..4) |index| {
            const left: i32 = @intCast(2 + index * 84);
            c.fillRect(.{ .x = left, .y = 0, .width = 16, .height = 16 }, rgb(38, 40, 43));
            if (index >= count) c.fillRect(.{ .x = left + 2, .y = 2, .width = 12, .height = 12 }, pin.paper_color);
        }
        try std.testing.expectEqualSlices(u8, old, new);
    }
}

test "card boot composition equals existing renderer including padded rows" {
    const splash = @import("card_splash.zig");
    const assets = @import("card_boot/assets.zig");
    const stride = splash.width * 2 + 16;
    const n = stride * splash.height;
    const original = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(original);
    const actual = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(actual);
    @memset(original, 0xaa);
    @memset(actual, 0xaa);
    try std.testing.expect(splash.paint(null, original, stride));
    const target = canvas.Canvas.init(actual, splash.width, splash.height, stride).?;
    target.fillRect(.{ .x = 0, .y = 0, .width = splash.width, .height = splash.height }, splash.background);
    var row: [splash.width]u8 = undefined;
    for (assets.placements) |p| {
        const glyph = assets.glyphs[p.mask];
        var x: usize = 0;
        var y: usize = 0;
        for (assets.masks[glyph.offset..][0..glyph.length]) |run| {
            for (0..@as(usize, run & 15) + 1) |_| {
                row[x] = (run >> 4) * 17;
                x += 1;
                if (x == glyph.width) {
                    try target.blitMask(.{ .bytes = row[0..glyph.width], .width = glyph.width, .height = 1, .stride = glyph.width }, p.x, @intCast(@as(usize, p.y) + y), splash.rgb565(p.color));
                    x = 0;
                    y += 1;
                }
            }
        }
    }
    target.fillRect(.{ .x = 52, .y = 125, .width = 616, .height = 1 }, splash.rgb565(0x40504a));
    try std.testing.expectEqualSlices(u8, original, actual);
}

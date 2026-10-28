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

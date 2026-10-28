//! Private boot-time scanout fixture. The display owner supplies its frame.
const canvas = @import("canvas");
const std = @import("std");

pub fn paint(frame: []u8, width: usize, height: usize, stride: usize) bool {
    if (width != 720 or height != 1280) return false;
    const c = canvas.Canvas.init(frame, width, height, stride) orelse return false;
    c.fillRect(.{ .x = 0, .y = 0, .width = 720, .height = 1280 }, 0x18c3);
    c.fillRect(.{ .x = 48, .y = 64, .width = 624, .height = 96 }, 0xffff);
    c.fillRect(.{ .x = 48, .y = 200, .width = 288, .height = 240 }, 0xf800);
    c.fillRect(.{ .x = 384, .y = 200, .width = 288, .height = 240 }, 0x07e0);
    c.fillRect(.{ .x = 48, .y = 488, .width = 624, .height = 240 }, 0x001f);
    // A separate source row exercises the same-size RGB565 blit into scanout.
    var row: [256]u8 = undefined;
    for (0..128) |x| {
        const color: u16 = if ((x / 16) % 2 == 0) 0xffff else 0x0000;
        std.mem.writeInt(u16, row[x * 2 ..][0..2], color, .little);
    }
    for (760..800) |y| c.blitRgb565(.{ .bytes = &row, .width = 128, .height = 1, .stride = row.len }, 48, @intCast(y)) catch return false;
    c.line(48, 800, 671, 1120, 0xffff);
    c.line(48, 1120, 671, 800, 0xffe0);
    return true;
}

test "pattern paints expected pixels and preserves padding" {
    const stride = 1456;
    const frame = try std.testing.allocator.alloc(u8, stride * 1280);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0xa5);
    try std.testing.expect(!paint(frame, 719, 1280, stride));
    try std.testing.expect(std.mem.allEqual(u8, frame, 0xa5));
    try std.testing.expect(paint(frame, 720, 1280, stride));
    try std.testing.expectEqual(@as(u16, 0xf800), std.mem.readInt(u16, frame[200 * stride + 48 * 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 0x07e0), std.mem.readInt(u16, frame[200 * stride + 384 * 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, frame[760 * stride + 48 * 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 0x0000), std.mem.readInt(u16, frame[760 * stride + 64 * 2 ..][0..2], .little));
    for (0..1280) |y| try std.testing.expect(std.mem.allEqual(u8, frame[y * stride + 1440 ..][0..16], 0xa5));
}

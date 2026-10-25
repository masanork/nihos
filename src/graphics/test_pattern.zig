//! A dependency-free RGB565 bring-up pattern.
//!
//! This stays in Zig so the first visible pixels exercise the same ownership,
//! bounds, and pixel-format rules that later renderers will use.

const std = @import("std");

pub fn rgb565(red: u8, green: u8, blue: u8) u16 {
    return (@as(u16, red >> 3) << 11) |
        (@as(u16, green >> 2) << 5) |
        @as(u16, blue >> 3);
}

pub fn paintRgb565Le(
    framebuffer: []u8,
    width: usize,
    height: usize,
    stride_bytes: usize,
) bool {
    const row_bytes = std.math.mul(usize, width, 2) catch return false;
    if (width == 0 or height == 0 or stride_bytes < row_bytes) return false;
    const required = std.math.mul(usize, stride_bytes, height) catch return false;
    if (framebuffer.len < required) return false;

    const bars = [_]u16{
        rgb565(255, 255, 255),
        rgb565(255, 255, 0),
        rgb565(0, 255, 255),
        rgb565(0, 255, 0),
        rgb565(255, 0, 255),
        rgb565(255, 0, 0),
        rgb565(0, 0, 255),
        rgb565(0, 0, 0),
    };

    for (0..height) |y| {
        const row = framebuffer[y * stride_bytes ..][0..row_bytes];
        for (0..width) |x| {
            var color = bars[@min((x * bars.len) / width, bars.len - 1)];
            // A dark checker strip makes direction and stride errors obvious.
            if (y >= (height * 7) / 8 and ((x / 32 + y / 32) & 1) == 0) {
                color >>= 1;
                color &= 0x7bef;
            }
            row[x * 2] = @truncate(color);
            row[x * 2 + 1] = @truncate(color >> 8);
        }
    }
    return true;
}

test "RGB565 conversion and little-endian paint are bounded" {
    try std.testing.expectEqual(@as(u16, 0xf800), rgb565(255, 0, 0));
    try std.testing.expectEqual(@as(u16, 0x07e0), rgb565(0, 255, 0));
    try std.testing.expectEqual(@as(u16, 0x001f), rgb565(0, 0, 255));

    var pixels: [16]u8 = @splat(0xaa);
    try std.testing.expect(paintRgb565Le(pixels[0..], 2, 2, 8));
    try std.testing.expectEqual(@as(u8, 0xff), pixels[0]);
    try std.testing.expectEqual(@as(u8, 0xff), pixels[1]);
    try std.testing.expectEqual(@as(u8, 0xaa), pixels[4]);
    try std.testing.expect(!paintRgb565Le(pixels[0..], 4, 4, 4));
}

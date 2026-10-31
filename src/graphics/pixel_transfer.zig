//! Presentation-only conversion of the canonical RGB565LE framebuffer.
//! No text shaping, blending, scaling or color adjustment belongs here.
const std = @import("std");
pub const Error = error{ InvalidGeometry, BufferTooSmall };

pub fn expand(color: u16) [4]u8 {
    const r: u8 = @intCast((color >> 11) & 31);
    const g: u8 = @intCast((color >> 5) & 63);
    const b: u8 = @intCast(color & 31);
    return .{ (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255 };
}
pub fn rgba8(source: []const u8, width: usize, height: usize, source_stride: usize, out: []u8, out_stride: usize) Error!void {
    const source_row = std.math.mul(usize, width, 2) catch return error.InvalidGeometry;
    const out_row = std.math.mul(usize, width, 4) catch return error.InvalidGeometry;
    const source_bytes = std.math.mul(usize, height, source_stride) catch return error.InvalidGeometry;
    const out_bytes = std.math.mul(usize, height, out_stride) catch return error.InvalidGeometry;
    if (width == 0 or height == 0 or source_stride < source_row or out_stride < out_row) return error.InvalidGeometry;
    if (source.len < source_bytes or out.len < out_bytes) return error.BufferTooSmall;
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = y * source_stride + x * 2;
            const color = @as(u16, source[offset]) | (@as(u16, source[offset + 1]) << 8);
            const pixel = expand(color);
            @memcpy(out[y * out_stride + x * 4 ..][0..4], &pixel);
        }
    }
}
test "all 65536 RGB565 colors round trip exactly through transfer expansion" {
    for (0..65536) |value| {
        const pixel = expand(@intCast(value));
        const encoded = (@as(u16, pixel[0] >> 3) << 11) | (@as(u16, pixel[1] >> 2) << 5) | @as(u16, pixel[2] >> 3);
        try std.testing.expectEqual(@as(u16, @intCast(value)), encoded);
        try std.testing.expectEqual(@as(u8, 255), pixel[3]);
    }
}
test "conversion preserves row padding and rejects invalid buffers before writing" {
    const source = [_]u8{ 0, 0xf8, 0xe0, 7, 99, 99, 0x1f, 0, 0xff, 0xff, 99, 99 };
    var out: [20]u8 = @splat(0xa5);
    try rgba8(&source, 2, 2, 6, &out, 10);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, out[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 255, 255, 255 }, out[10..18]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, out[8..10]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, out[18..20]);
    const before = out;
    try std.testing.expectError(error.BufferTooSmall, rgba8(&source, 2, 2, 6, out[0..8], 10));
    try std.testing.expectEqualSlices(u8, &before, &out);
}

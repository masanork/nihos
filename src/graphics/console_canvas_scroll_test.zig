//! Host experiment: map the live console's rotated scroll to Canvas.copyRect.
//! This does not replace the production renderer or repaint its exposed band.
const std = @import("std");
const Canvas = @import("canvas").Canvas;
const console = @import("console");

test "Canvas copy matches the console physical scroll including padding" {
    inline for (.{ console.raster.Face.basic, console.raster.Face.basic_light }) |face| {
        const L = console.raster.Layout(face);
        const stride = console.raster.width * 2 + 8;
        const size = stride * console.raster.height;
        const actual = try std.testing.allocator.alloc(u8, size + 32);
        defer std.testing.allocator.free(actual);
        const expected = try std.testing.allocator.alloc(u8, size + 32);
        defer std.testing.allocator.free(expected);
        for ([_]usize{ 1, 2 }) |lines| {
            for (actual, 0..) |*byte, i| byte.* = @truncate((i *% 37) ^ (i >> 7));
            @memcpy(expected, actual);
            const top = L.margin_y + console.snapshot.header_rows * L.cell_height;
            const bottom = L.margin_y + L.rows * L.cell_height;
            const count = lines * L.cell_height;
            const first_y = 1280 - L.margin_x - L.columns * L.cell_width;
            const last_y = 1280 - L.margin_x;
            const reference = expected[16..][0..size];
            // Same scanline movement as Renderer.step before its strip repaint.
            for (first_y..last_y) |y| {
                const begin = y * stride + top * 2;
                std.mem.copyForwards(u8, reference[begin..][0 .. (bottom - top - count) * 2], reference[begin + count * 2 ..][0 .. (bottom - top - count) * 2]);
            }
            const canvas = Canvas.init(actual[16..][0..size], 720, 1280, stride).?;
            canvas.copyRect(.{ .x = @intCast(top + count), .y = @intCast(first_y), .width = @intCast(bottom - top - count), .height = @intCast(last_y - first_y) }, @intCast(top), @intCast(first_y));
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
    }
}

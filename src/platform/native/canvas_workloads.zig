//! Deterministic offscreen Canvas workloads; not an editor or Quake port.
const canvas = @import("canvas");
const std = @import("std");
pub const width = 320;
pub const height = 200;
pub const stride = width * 2;
pub const frame_bytes = height * stride;
pub const index_bytes = 160 * 100;

/// Approximate editor rectangles and scroll the retained surface up 16 pixels.
pub fn scroll(storage: []u8) bool {
    if (storage.len < frame_bytes) return false;
    const c = canvas.Canvas.init(storage[0..frame_bytes], width, height, stride) orelse return false;
    c.fillRect(.{ .x = 0, .y = 0, .width = width, .height = height }, 0x1082);
    for (0..12) |i| {
        const color: u16 = @intCast((i * 997 + 0x1234) & 0xffff);
        c.fillRect(.{ .x = 8, .y = @intCast(8 + i * 12), .width = 220, .height = 7 }, color);
    }
    c.fillRect(.{ .x = 30, .y = 56, .width = 120, .height = 9 }, 0x07ff);
    c.copyRect(.{ .x = 0, .y = 16, .width = width, .height = height - 16 }, 0, 0);
    c.fillRect(.{ .x = 0, .y = height - 16, .width = width, .height = 16 }, 0x1082);
    const clipped = c.clipped(.{ .x = 10, .y = 12, .width = 280, .height = 170 });
    clipped.line(std.math.minInt(i32), 20, std.math.maxInt(i32), 20, 0xf800);
    clipped.line(270, std.math.maxInt(i32), 270, std.math.minInt(i32), 0x001f);
    clipped.line(15, 15, 15, 15, 0xffff);
    clipped.line(std.math.minInt(i32), std.math.minInt(i32) + 5, std.math.maxInt(i32) - 5, std.math.maxInt(i32), 0x07e0);
    clipped.line(280, 30, 10, 160, 0xffe0);
    // Synthetic antialiased glyph coverage with padded source rows. The two
    // placements cross different clip edges and existing background colors.
    const coverage = [_]u8{ 0, 1, 32, 64, 127, 128, 192, 254, 255 };
    var mask: [15 * 8]u8 = @splat(0xa5);
    for (0..8) |y| for (0..13) |x| {
        mask[y * 15 + x] = coverage[(x * 3 + y * 5) % coverage.len];
    };
    const image = canvas.Image{ .bytes = &mask, .width = 13, .height = 8, .stride = 15 };
    clipped.blitMask(image, 8, 10, 0xf39c) catch return false;
    clipped.blitMask(image, 265, 176, 0xf39c) catch return false;
    return true;
}

/// Indexed 160×100 source expanded 2× into a 320×200 RGB565 destination.
pub fn indexed(storage: []u8) bool {
    if (storage.len < frame_bytes + index_bytes) return false;
    const target = storage[0..frame_bytes];
    const source = storage[frame_bytes..][0..index_bytes];
    for (0..100) |y| for (0..160) |x| {
        source[y * 160 + x] = @truncate(x * 3 + y * 5);
    };
    var palette: [256]u16 = undefined;
    for (&palette, 0..) |*p, i| p.* = @as(u16, @intCast(i * 257)) ^ 0x5a5a;
    const c = canvas.Canvas.init(target, width, height, stride) orelse return false;
    c.blitIndexed8Scaled(.{ .bytes = source, .width = 160, .height = 100, .stride = 160 }, &palette, .{ .x = 0, .y = 0, .width = width, .height = height }) catch return false;
    return true;
}

test "workloads reject undersized destination before writing" {
    var guard: [32]u8 = @splat(0xa5);
    try std.testing.expect(!scroll(&guard));
    try std.testing.expect(!indexed(&guard));
    try std.testing.expect(std.mem.allEqual(u8, &guard, 0xa5));
}

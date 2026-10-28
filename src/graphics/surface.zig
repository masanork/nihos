//! Borrowed RGB565LE surfaces and A8 masks. No allocation, font or driver API.
//! Geometry/alias errors are rejected before writes; clipping is a valid no-op.
const std = @import("std");

pub const Mask = struct { bytes: []const u8, width: usize, height: usize, stride: usize };
pub const Surface = struct {
    bytes: []u8,
    width: usize,
    height: usize,
    stride: usize,

    pub fn init(bytes: []u8, width: usize, height: usize, stride: usize) ?Surface {
        const result = Surface{ .bytes = bytes, .width = width, .height = height, .stride = stride };
        return if (valid(bytes.len, width, height, stride, 2)) result else null;
    }
    pub fn fill(self: Surface, color: u16) bool {
        if (!valid(self.bytes.len, self.width, self.height, self.stride, 2)) return false;
        for (0..self.height) |y| for (0..self.width) |x| self.put(y * self.stride + x * 2, color);
        return true;
    }
    pub fn blit(self: Surface, mask: Mask, x: i32, y: i32, color: u16) bool {
        if (!valid(self.bytes.len, self.width, self.height, self.stride, 2) or
            !valid(mask.bytes.len, mask.width, mask.height, mask.stride, 1)) return false;
        const source = @intFromPtr(mask.bytes.ptr);
        const target = @intFromPtr(self.bytes.ptr);
        if (if (source <= target) target - source < mask.bytes.len else source - target < self.bytes.len) return false;
        const left = @max(@as(i64, 0), x);
        const top = @max(@as(i64, 0), y);
        const right = @min(@as(i64, @intCast(self.width)), @as(i64, x) + @as(i64, @intCast(mask.width)));
        const bottom = @min(@as(i64, @intCast(self.height)), @as(i64, y) + @as(i64, @intCast(mask.height)));
        if (left >= right or top >= bottom) return true;
        for (@as(usize, @intCast(top))..@as(usize, @intCast(bottom))) |dy| {
            const sy: usize = @intCast(@as(i64, @intCast(dy)) - y);
            for (@as(usize, @intCast(left))..@as(usize, @intCast(right))) |dx| {
                const sx: usize = @intCast(@as(i64, @intCast(dx)) - x);
                const alpha = mask.bytes[sy * mask.stride + sx];
                if (alpha == 0) continue;
                const offset = dy * self.stride + dx * 2;
                const background = @as(u16, self.bytes[offset]) | (@as(u16, self.bytes[offset + 1]) << 8);
                self.put(offset, if (alpha == 255) color else blend(background, color, alpha));
            }
        }
        return true;
    }
    fn put(self: Surface, offset: usize, pixel: u16) void {
        self.bytes[offset] = @truncate(pixel);
        self.bytes[offset + 1] = @truncate(pixel >> 8);
    }
};

fn valid(length: usize, width: usize, height: usize, stride: usize, pixel_bytes: usize) bool {
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return false;
    const row = std.math.mul(usize, width, pixel_bytes) catch return false;
    const required = std.math.mul(usize, stride, height) catch return false;
    return stride >= row and length >= required;
}
fn blend(background: u16, color: u16, alpha: u8) u16 {
    const a: u32 = alpha;
    const r = (((@as(u32, color) >> 11) & 31) * a + ((@as(u32, background) >> 11) & 31) * (255 - a) + 127) / 255;
    const g = (((@as(u32, color) >> 5) & 63) * a + ((@as(u32, background) >> 5) & 63) * (255 - a) + 127) / 255;
    const b = ((@as(u32, color) & 31) * a + (@as(u32, background) & 31) * (255 - a) + 127) / 255;
    return @intCast((r << 11) | (g << 5) | b);
}

test "coverage endpoints and half blend preserve stride and guards" {
    var bytes: [16]u8 = @splat(0xaa);
    const surface = Surface.init(bytes[2..14], 3, 1, 12).?;
    try std.testing.expect(surface.fill(0x001f));
    const mask = [_]u8{ 0, 128, 255 };
    try std.testing.expect(surface.blit(.{ .bytes = &mask, .width = 3, .height = 1, .stride = 3 }, 0, 0, 0xf800));
    try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0, 0x0f, 0x80, 0, 0xf8 }, bytes[2..8]);
    try std.testing.expect(std.mem.allEqual(u8, bytes[8..], 0xaa));
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
}
test "negative placement clips source rows and fully outside masks do nothing" {
    var bytes: [12]u8 = @splat(0);
    const surface = Surface.init(&bytes, 2, 2, 6).?;
    const mask = [_]u8{ 0, 0, 77, 0, 255, 99 };
    try std.testing.expect(surface.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 3 }, -1, -1, 0xffff));
    try std.testing.expectEqualSlices(u8, &.{ 255, 255 }, bytes[0..2]);
    try std.testing.expect(std.mem.allEqual(u8, bytes[2..], 0));
    const saved = bytes;
    try std.testing.expect(surface.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 3 }, std.math.maxInt(i32), 0, 1));
    try std.testing.expectEqualSlices(u8, &saved, &bytes);
}
test "invalid geometry and aliased masks fail before mutation" {
    var bytes: [16]u8 = @splat(0x55);
    try std.testing.expect(Surface.init(&bytes, std.math.maxInt(usize), 2, 8) == null);
    const surface = Surface.init(&bytes, 2, 2, 8).?;
    try std.testing.expect(!surface.blit(.{ .bytes = bytes[0..1], .width = 1, .height = 1, .stride = 1 }, 0, 0, 0));
    const mask = [_]u8{255};
    try std.testing.expect(!surface.blit(.{ .bytes = &mask, .width = 2, .height = 2, .stride = 2 }, 0, 0, 0));
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0x55));
}

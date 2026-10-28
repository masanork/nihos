//! Small, allocation-free RGB565LE canvas. Not an SDL or M5GFX implementation.
const std = @import("std");
const surface = @import("surface.zig");

pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
pub const Image = struct { bytes: []const u8, width: u32, height: u32, stride: usize };
pub const Error = error{ InvalidImage, Aliased };
const Bounds = struct { left: i64, top: i64, right: i64, bottom: i64 };
fn bounds(r: Rect) Bounds {
    return .{ .left = r.x, .top = r.y, .right = @as(i64, r.x) + r.width, .bottom = @as(i64, r.y) + r.height };
}
fn intersect(a: Bounds, b: Bounds) Bounds {
    return .{ .left = @max(a.left, b.left), .top = @max(a.top, b.top), .right = @min(a.right, b.right), .bottom = @min(a.bottom, b.bottom) };
}
fn validImage(image: Image, bpp: usize) bool {
    const row = std.math.mul(usize, image.width, bpp) catch return false;
    const length = std.math.mul(usize, image.stride, image.height) catch return false;
    return image.stride >= row and image.bytes.len >= length;
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return if (x <= y) y - x < a.len else x - y < b.len;
}

/// The caller owns the buffer and must serialize access for this canvas's lifetime.
pub const Canvas = struct {
    target: surface.Surface,
    clip: Bounds,

    pub fn init(bytes: []u8, width: usize, height: usize, stride: usize) ?Canvas {
        const target = surface.Surface.init(bytes, width, height, stride) orelse return null;
        return .{ .target = target, .clip = .{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) } };
    }
    /// Returns an independent view whose clip intersects the existing clip.
    pub fn clipped(self: Canvas, rect: Rect) Canvas {
        var result = self;
        result.clip = intersect(self.clip, bounds(rect));
        return result;
    }
    pub fn fillRect(self: Canvas, rect: Rect, color: u16) void {
        const r = intersect(self.clip, bounds(rect));
        if (r.left >= r.right or r.top >= r.bottom) return;
        for (@as(usize, @intCast(r.top))..@as(usize, @intCast(r.bottom))) |y| {
            for (@as(usize, @intCast(r.left))..@as(usize, @intCast(r.right))) |x| {
                std.mem.writeInt(u16, self.target.bytes[y * self.target.stride + x * 2 ..][0..2], color, .little);
            }
        }
    }
    /// Copies RGB565LE or converts one-byte palette indices to RGB565LE.
    /// Source and palette must not alias any part of the target buffer.
    pub fn blitRgb565(self: Canvas, image: Image, x: i32, y: i32) Error!void {
        try self.copy(image, x, y, null);
    }
    pub fn blitIndexed8(self: Canvas, image: Image, palette: *const [256]u16, x: i32, y: i32) Error!void {
        if (overlaps(self.target.bytes, std.mem.asBytes(palette))) return error.Aliased;
        try self.copy(image, x, y, palette);
    }
    fn copy(self: Canvas, image: Image, x: i32, y: i32, palette: ?*const [256]u16) Error!void {
        const bpp: usize = if (palette == null) 2 else 1;
        if (!validImage(image, bpp)) return error.InvalidImage;
        if (overlaps(self.target.bytes, image.bytes)) return error.Aliased;
        const area = intersect(self.clip, bounds(.{ .x = x, .y = y, .width = image.width, .height = image.height }));
        if (area.left >= area.right or area.top >= area.bottom) return;
        for (@as(usize, @intCast(area.top))..@as(usize, @intCast(area.bottom))) |dy| {
            const sy: usize = @intCast(@as(i64, @intCast(dy)) - y);
            for (@as(usize, @intCast(area.left))..@as(usize, @intCast(area.right))) |dx| {
                const sx: usize = @intCast(@as(i64, @intCast(dx)) - x);
                const source = sy * image.stride + sx * bpp;
                const color = if (palette) |p| p[image.bytes[source]] else std.mem.readInt(u16, image.bytes[source..][0..2], .little);
                std.mem.writeInt(u16, self.target.bytes[dy * self.target.stride + dx * 2 ..][0..2], color, .little);
            }
        }
    }
    /// Uses the existing surface compositor, retaining its encoded RGB565 rounding.
    pub fn blitMask(self: Canvas, mask: Image, x: i32, y: i32, color: u16) Error!void {
        if (!validImage(mask, 1) or mask.width > std.math.maxInt(i32) or mask.height > std.math.maxInt(i32)) return error.InvalidImage;
        if (overlaps(self.target.bytes, mask.bytes)) return error.Aliased;
        const area = intersect(self.clip, bounds(.{ .x = x, .y = y, .width = mask.width, .height = mask.height }));
        if (area.left >= area.right or area.top >= area.bottom) return;
        const dx: usize = @intCast(area.left);
        const dy: usize = @intCast(area.top);
        const sx: usize = @intCast(area.left - x);
        const sy: usize = @intCast(area.top - y);
        const w: usize = @intCast(area.right - area.left);
        const h: usize = @intCast(area.bottom - area.top);
        // Full remaining rows are supplied because Surface validates stride * height.
        const dest = self.target.bytes[dy * self.target.stride ..][0 .. h * self.target.stride];
        const src = mask.bytes[sy * mask.stride ..][0 .. h * mask.stride];
        // A shifted slice lacks trailing padding after the last row; use per-row calls.
        for (0..h) |row| {
            const row_target = surface.Surface.init(dest[row * self.target.stride ..][0..self.target.stride], self.target.width, 1, self.target.stride) orelse return error.InvalidImage;
            const row_mask = surface.Mask{ .bytes = src[row * mask.stride + sx ..][0..w], .width = w, .height = 1, .stride = w };
            if (!row_target.blit(row_mask, @intCast(dx), 0, color)) return error.InvalidImage;
        }
    }
};

test "nested clip and half-open rectangles preserve padding and guards" {
    var bytes: [28]u8 = @splat(0xaa);
    const canvas = Canvas.init(bytes[2..26], 3, 3, 8).?;
    canvas.clipped(.{ .x = 1, .y = 0, .width = 2, .height = 2 }).fillRect(.{ .x = -1, .y = 1, .width = 4, .height = 3 }, 0x1234);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0x34, 0x12, 0x34, 0x12, 0xaa, 0xaa }, bytes[10..18]);
    try std.testing.expect(std.mem.allEqual(u8, bytes[0..10], 0xaa));
    try std.testing.expect(std.mem.allEqual(u8, bytes[18..], 0xaa));
}
test "extreme coordinates and invalid geometry are safe" {
    var bytes: [8]u8 = @splat(0);
    try std.testing.expect(Canvas.init(&bytes, 3, 2, 4) == null);
    const c = Canvas.init(&bytes, 2, 2, 4).?;
    c.clipped(.{ .x = std.math.minInt(i32), .y = 0, .width = 1, .height = 1 }).fillRect(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0xffff);
    c.fillRect(.{ .x = std.math.maxInt(i32), .y = 0, .width = std.math.maxInt(u32), .height = 2 }, 0xffff);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0));
}
test "mask clipping agrees with existing compositor" {
    var expected: [24]u8 = @splat(0x19);
    var actual = expected;
    const mask = [_]u8{ 0, 40, 255, 99, 128, 200, 255, 99 };
    const old = surface.Surface.init(&expected, 3, 3, 8).?;
    try std.testing.expect(old.blit(.{ .bytes = &mask, .width = 3, .height = 2, .stride = 4 }, 0, 1, 0xf800));
    const c = Canvas.init(&actual, 3, 3, 8).?;
    try c.blitMask(.{ .bytes = &mask, .width = 3, .height = 2, .stride = 4 }, 0, 1, 0xf800);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    @memset(&actual, 0x19);
    try c.clipped(.{ .x = 1, .y = 2, .width = 2, .height = 1 }).blitMask(.{ .bytes = &mask, .width = 3, .height = 2, .stride = 4 }, 0, 1, 0xf800);
    try std.testing.expectEqualSlices(u8, expected[18..22], actual[18..22]);
    try std.testing.expect(std.mem.allEqual(u8, actual[0..18], 0x19));
    try std.testing.expect(std.mem.allEqual(u8, actual[22..], 0x19));
}
test "indexed and RGB image copies clip and reject invalid or aliased inputs before writes" {
    var target: [16]u8 = @splat(0xaa);
    const c = Canvas.init(&target, 3, 2, 8).?;
    var palette: [256]u16 = @splat(0);
    palette[1] = 0x1234;
    palette[2] = 0xabcd;
    const indices = [_]u8{ 1, 2, 0, 0xee, 2, 1, 0, 0xee };
    try c.clipped(.{ .x = 0, .y = 0, .width = 2, .height = 2 }).blitIndexed8(.{ .bytes = &indices, .width = 3, .height = 2, .stride = 4 }, &palette, -1, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa, 0x34, 0x12, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa }, &target);
    const before = target;
    try std.testing.expectError(error.InvalidImage, c.blitRgb565(.{ .bytes = &indices, .width = 3, .height = 2, .stride = 4 }, 0, 0));
    try std.testing.expectError(error.Aliased, c.blitRgb565(.{ .bytes = target[0..8], .width = 2, .height = 2, .stride = 4 }, 0, 0));
    try std.testing.expectError(error.Aliased, c.blitMask(.{ .bytes = target[0..8], .width = 2, .height = 2, .stride = 4 }, 0, 0, 0));
    try std.testing.expectEqualSlices(u8, &before, &target);
    const rgb = [_]u8{ 0x78, 0x56, 0xef, 0xbe };
    try c.blitRgb565(.{ .bytes = &rgb, .width = 2, .height = 1, .stride = 4 }, 1, 1);
    try std.testing.expectEqualSlices(u8, &rgb, target[10..14]);
}

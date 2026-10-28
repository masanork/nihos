//! Small, allocation-free RGB565LE canvas. Not an SDL or M5GFX implementation.
const std = @import("std");
const surface = @import("surface.zig");

pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
const Bounds = struct { left: i64, top: i64, right: i64, bottom: i64 };
fn bounds(r: Rect) Bounds {
    return .{ .left = r.x, .top = r.y, .right = @as(i64, r.x) + r.width, .bottom = @as(i64, r.y) + r.height };
}
fn intersect(a: Bounds, b: Bounds) Bounds {
    return .{ .left = @max(a.left, b.left), .top = @max(a.top, b.top), .right = @min(a.right, b.right), .bottom = @min(a.bottom, b.bottom) };
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

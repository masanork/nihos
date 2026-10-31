//! Pure geometry over the shared Canvas. No window, allocator, clock or I/O.
const std = @import("std");
const canvas = @import("canvas");
pub const animation = @import("../app/animation.zig");
pub const Area = struct { x: i32, y: i32, width: u32, height: u32 };
const sine = table: {
    @setEvalBranchQuota(10_000);
    var result: [256]i16 = undefined;
    for (&result, 0..) |*value, n| value.* = @intFromFloat(@sin(@as(f64, @floatFromInt(n)) * 2 * std.math.pi / 256) * 30_000);
    break :table result;
};

pub fn background(target: canvas.Canvas, area: Area) void {
    const clipped = target.clipped(.{ .x = area.x, .y = area.y, .width = area.width, .height = area.height });
    clipped.fillRect(.{ .x = area.x, .y = area.y, .width = area.width, .height = area.height }, 0xffff);
    if (area.width < 2 or area.height < 2) return;
    for (0..9) |n| {
        const x = area.x + @as(i32, @intCast(n * (area.width - 1) / 8));
        clipped.line(x, area.y, x, area.y + @as(i32, @intCast(area.height - 1)), 0xe71c);
    }
    for (0..5) |n| {
        const y = area.y + @as(i32, @intCast(n * (area.height - 1) / 4));
        clipped.line(area.x, y, area.x + @as(i32, @intCast(area.width - 1)), y, 0xe71c);
    }
    const center = area.y + @as(i32, @intCast(area.height / 2));
    clipped.line(area.x, center, area.x + @as(i32, @intCast(area.width - 1)), center, 0x8c51);
}

pub fn curves(target: canvas.Canvas, area: Area, state: animation.State) void {
    if (area.width < 2 or area.height < 2) return;
    const clipped = target.clipped(.{ .x = area.x, .y = area.y, .width = area.width, .height = area.height });
    const phase: u32 = @intCast(state.phase % 256);
    const center = area.y + @as(i32, @intCast(area.height / 2));
    const amplitude: i64 = @intCast(area.height * 3 / 8);
    for ([_]u16{ 0x1979, 0xd326 }, 0..) |color, series| {
        var last_x = area.x;
        var last_y = center;
        for (0..area.width) |offset| {
            const sample = (offset * 512 / area.width + phase + series * 64) % 256;
            const y = center - @as(i32, @intCast(@divTrunc(@as(i64, sine[sample]) * amplitude, 30_000)));
            const x = area.x + @as(i32, @intCast(offset));
            if (offset != 0) clipped.line(last_x, last_y, x, y, color);
            last_x = x;
            last_y = y;
        }
    }
}

test "curves move deterministically and preserve pixels outside their plot" {
    const width = 160;
    const height = 120;
    const stride = width * 2 + 8;
    var a: [stride * height]u8 = @splat(0xa5);
    var b = a;
    const first = canvas.Canvas.init(&a, width, height, stride).?;
    const second = canvas.Canvas.init(&b, width, height, stride).?;
    const area = Area{ .x = 12, .y = 16, .width = 120, .height = 80 };
    background(first, area);
    background(second, area);
    curves(first, area, .{});
    curves(second, area, .{ .phase = 12 });
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    for (0..height) |y| for (0..stride) |x| {
        if (y < 16 or y >= 96 or x < 24 or x >= 264) try std.testing.expectEqual(@as(u8, 0xa5), a[y * stride + x]);
    };
    const saved = b;
    background(second, area);
    curves(second, area, .{ .phase = 12 });
    try std.testing.expectEqualSlices(u8, &saved, &b);
}

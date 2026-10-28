//! Finite composition driver, not a paragraph/ruby layout policy or scanout.
const std = @import("std");
const surface = @import("surface");
const protocol = @import("font_protocol");
const heap = @import("native_memory").reusable;
extern fn nih_native_task_failed() callconv(.c) noreturn;
pub const width = 192;
pub const height = 96;
pub const stride = 400;
pub const Report = struct {
    frames: u32 = 0,
    blits: u32 = 0,
    clipped: u32 = 0,
    guards: u32 = 0,
    rejected: u32 = 0,
    peak_charge: u32 = 0,
    live_charge: u32 = 0,
};
pub var metrics: Report = .{};
var hashes: [5]u32 = @splat(0);
pub fn hash(index: usize) u32 {
    return hashes[index];
}
fn digest(bytes: []const u8) u32 {
    var value: u32 = 2166136261;
    for (bytes) |byte| value = (value ^ byte) *% 16777619;
    return value;
}
pub fn compose(reply: *const protocol.Reply, pixels: []const u8) void {
    const before = heap.availableBytes() orelse nih_native_task_failed();
    const allocation = heap.allocTask(stride * height + 64, 16) catch nih_native_task_failed();
    const charge: u32 = @intCast(before - (heap.availableBytes() orelse nih_native_task_failed()));
    metrics.peak_charge = @max(metrics.peak_charge, charge);
    metrics.live_charge = charge;
    @memset(allocation.bytes, 0xa5);
    const data = allocation.bytes[32..][0 .. stride * height];
    const target = surface.Surface.init(data, width, height, stride) orelse nih_native_task_failed();
    if (!target.fill(0xf79e)) nih_native_task_failed();
    var pen_x: [2]i64 = .{ 0, 0 };
    var pen_y: [2]i64 = .{ 0, 0 };
    for (reply.output.glyphs[0..reply.output.count]) |g| {
        const run = g.run;
        const origin_x: i64 = if (reply.id == 8) (if (run == 0) @as(i64, 150) else 178) else if (reply.id == 9) -8 else 8;
        const origin_y: i64 = if (reply.id == 8) 8 else if (run == 1) 18 else if (reply.id == 9) 80 else 48;
        const x = std.math.cast(i32, origin_x + @divFloor(pen_x[run] + g.x_offset, 64) + g.left) orelse nih_native_task_failed();
        const y = std.math.cast(i32, origin_y - @divFloor(pen_y[run] + g.y_offset, 64) - g.top) orelse nih_native_task_failed();
        pen_x[run] += g.x_advance;
        pen_y[run] += g.y_advance;
        const count = g.width * g.height;
        const mask = surface.Mask{ .bytes = pixels[g.pixel_offset..][0..count], .width = g.width, .height = g.height, .stride = g.width };
        if (!target.blit(mask, x, y, if (run == 0) 0x192b else 0xb9a7)) nih_native_task_failed();
        metrics.blits += 1;
        if (x < 0 or y < 0 or @as(i64, x) + g.width > width or @as(i64, y) + g.height > height) metrics.clipped += 1;
    }
    const value = digest(data);
    const first = reply.output.glyphs[0];
    if (target.blit(.{ .bytes = pixels[first.pixel_offset..][0 .. first.width * first.height - 1], .width = first.width, .height = first.height, .stride = first.width }, 0, 0, 0)) nih_native_task_failed();
    if (target.blit(.{ .bytes = data[0..1], .width = 1, .height = 1, .stride = 1 }, 0, 0, 0)) nih_native_task_failed();
    metrics.rejected += 2;
    if (digest(data) != value) nih_native_task_failed();
    for (0..height) |y| if (!std.mem.allEqual(u8, data[y * stride + width * 2 ..][0 .. stride - width * 2], 0xa5)) nih_native_task_failed();
    if (!std.mem.allEqual(u8, allocation.bytes[0..32], 0xa5) or !std.mem.allEqual(u8, allocation.bytes[32 + stride * height ..], 0xa5)) nih_native_task_failed();
    metrics.guards += 1;
    hashes[reply.id - 5] = value;
    heap.freeTask(allocation) catch nih_native_task_failed();
    if ((heap.availableBytes() orelse nih_native_task_failed()) != before) nih_native_task_failed();
    metrics.live_charge = 0;
    metrics.frames += 1;
}

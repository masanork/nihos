//! Host-only benchmark adapter. This is not an application or device ABI.
const Canvas = @import("canvas").Canvas;
export fn render(out: [*]u8, src: [*]const u8, count: u32) u32 {
    const c = Canvas.init(out[0 .. 720 * 480 * 2], 720, 480, 1440) orelse return 0;
    for (0..count) |_| c.blitRgb565(.{ .bytes = src[0 .. 720 * 480 * 2], .width = 720, .height = 480, .stride = 1440 }, 0, 0) catch return 0;
    return 1;
}

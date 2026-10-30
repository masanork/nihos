//! Host-only A8 glyph-mask workload; not a device or application benchmark.
const Canvas = @import("canvas").Canvas;
export fn render(out: [*]u8, mask: [*]const u8, count: u32) u32 {
    const c = Canvas.init(out[0 .. 320 * 200 * 2], 320, 200, 640) orelse return 0;
    for (0..count) |_| for (0..12) |row| for (0..20) |col| {
        c.blitMask(.{ .bytes = mask[0 .. 16 * 16], .width = 16, .height = 16, .stride = 16 }, @intCast(col * 16), @intCast(row * 16), 0xf39c) catch return 0;
    };
    return 1;
}

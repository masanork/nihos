//! Host-only indexed scaling adapter; not an application or device ABI.
const Canvas = @import("canvas").Canvas;
export fn render(out: [*]u8, src: [*]const u8, palette: *const [256]u16, count: u32, mode: u32) u32 {
    const c = Canvas.init(out[0 .. 320 * 200 * 2], 320, 200, 640) orelse return 0;
    for (0..count) |_| {
        if (mode == 0 or mode == 1) {
            c.blitIndexed8Scaled(.{ .bytes = src[0 .. 160 * 100], .width = 160, .height = 100, .stride = 160 }, palette, .{ .x = if (mode == 1) -10 else 0, .y = if (mode == 1) -6 else 0, .width = 320, .height = 200 }) catch return 0;
        } else if (mode == 2) {
            c.blitIndexed8Scaled(.{ .bytes = src[0 .. 200 * 125], .width = 200, .height = 125, .stride = 200 }, palette, .{ .x = 0, .y = 0, .width = 320, .height = 200 }) catch return 0;
        } else return 0;
    }
    return 1;
}

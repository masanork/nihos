//! Host-only copyRect benchmark adapter; not an application or device ABI.
const Canvas = @import("canvas").Canvas;
export fn render(out: [*]u8, count: u32, mode: u32) u32 {
    const c = Canvas.init(out[0 .. 720 * 480 * 2], 720, 480, 1440) orelse return 0;
    for (0..count) |_| switch (mode) {
        0 => c.copyRect(.{ .x = 0, .y = 16, .width = 720, .height = 464 }, 0, 0),
        1 => c.copyRect(.{ .x = 0, .y = 0, .width = 720, .height = 464 }, 0, 16),
        2 => c.copyRect(.{ .x = 0, .y = 0, .width = 704, .height = 480 }, 16, 0),
        else => return 0,
    };
    return 1;
}

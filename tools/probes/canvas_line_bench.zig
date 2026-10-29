//! Host-only Canvas line workload; not a device or application benchmark.
const Canvas = @import("canvas").Canvas;
export fn render(out: [*]u8, count: u32, mode: u32) u32 {
    const c = Canvas.init(out[0 .. 320 * 200 * 2], 320, 200, 640) orelse return 0;
    for (0..count) |_| for (0..100) |i| {
        const n: i32 = @intCast(i);
        switch (mode) {
            0 => c.line(-30 + n, n * 2, 319 - n, n * 2, 0x47e1),
            1 => c.line(n * 3, -30 + n, n * 3, 199 - n, 0x47e1),
            2 => c.line(n, 0, 319 - n, 199, 0x47e1),
            else => return 0,
        }
    };
    return 1;
}

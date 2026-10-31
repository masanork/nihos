//! Compile/link probe only: borrowed frame and pure application state on RV32.
const core = @import("core");
const Canvas = @import("canvas").Canvas;
export fn nih_animation_frame(bytes: [*]u8, length: usize, now_us: u64) callconv(.c) u32 {
    if (length < 64 * 48 * 2) return 0;
    var model = core.animation.Model{};
    _ = model.advance(0);
    _ = model.advance(now_us);
    const target = Canvas.init(bytes[0 .. 64 * 48 * 2], 64, 48, 128) orelse return 0;
    const area = core.animated_plot.Area{ .x = 0, .y = 0, .width = 64, .height = 48 };
    core.animated_plot.background(target, area);
    core.animated_plot.curves(target, area, model.state);
    var hash: u32 = 0x811c9dc5;
    for (bytes[0 .. 64 * 48 * 2]) |byte| hash = (hash ^ byte) *% 0x01000193;
    return hash;
}

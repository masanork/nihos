//! Host rendering of the actual fixed-mask boot path and its sparse plan.
const splash = @import("graphics/card_splash.zig");
const plan = @import("graphics/keypad_plan.zig");
pub export fn paint(frame: [*]u8, length: usize) bool {
    return splash.paint(null, frame[0..length], 1440);
}
pub export fn spans(frame: [*]const u8, length: usize, output: [*]plan.Segment, capacity: usize) usize {
    return (plan.buildStaticColor(frame[0..length], output[0..capacity], splash.background) catch return 0).len;
}
pub export fn textureStride() usize {
    return plan.textureStride();
}

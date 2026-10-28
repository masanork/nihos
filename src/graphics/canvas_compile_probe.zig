//! RV32 object compile/link probe only; not a display driver or ABI.
const Canvas = @import("canvas.zig").Canvas;

export fn nih_canvas_probe(out: [*]u8, src: [*]const u8, palette: *const [256]u16) bool {
    const c = Canvas.init(out[0..128], 8, 8, 16) orelse return false;
    c.fillRect(.{ .x = 1, .y = 1, .width = 6, .height = 6 }, 0xffff);
    c.line(-4, 0, 20, 7, 0xf800);
    c.copyRect(.{ .x = 0, .y = 0, .width = 7, .height = 7 }, 1, 1);
    c.blitIndexed8Scaled(.{ .bytes = src[0..4], .width = 2, .height = 2, .stride = 2 }, palette, .{ .x = 0, .y = 0, .width = 8, .height = 8 }) catch return false;
    c.blitMask(.{ .bytes = src[0..4], .width = 2, .height = 2, .stride = 2 }, 0, 0, 0xffff) catch return false;
    c.blitRgb565(.{ .bytes = src[0..4], .width = 2, .height = 1, .stride = 4 }, 0, 0) catch return false;
    return true;
}

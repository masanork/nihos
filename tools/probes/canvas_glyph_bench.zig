//! Host-only replay of captured A8 glyphs; not a font worker or application ABI.
const Canvas = @import("canvas").Canvas;
const Glyph = extern struct {
    offset: u32,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    color: u16,
};
export fn render(out: [*]u8, pixels: [*]const u8, pixels_len: usize, glyphs: [*]const Glyph, glyph_count: usize, iterations: u32) bool {
    const frame = out[0 .. 400 * 96];
    const canvas = Canvas.init(frame, 192, 96, 400) orelse return false;
    for (0..iterations) |_| {
        @memset(frame, 0xa5);
        canvas.fillRect(.{ .x = 0, .y = 0, .width = 192, .height = 96 }, 0xf79e);
        for (glyphs[0..glyph_count]) |glyph| {
            const bytes = @as(usize, glyph.width) * glyph.height;
            if (glyph.offset > pixels_len or bytes > pixels_len - glyph.offset) return false;
            canvas.blitMask(.{ .bytes = pixels[glyph.offset..][0..bytes], .width = glyph.width, .height = glyph.height, .stride = glyph.width }, glyph.x, glyph.y, glyph.color) catch return false;
        }
    }
    return true;
}

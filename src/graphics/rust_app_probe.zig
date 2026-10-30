//! Experimental single-owner synchronous adapter; not a general display service.
const Surface = @import("surface.zig").Surface;
const font = @embedFile("ascii/basic.bin");
var current: ?Surface = null;

/// The owner must keep storage alive and exclusive until detach, and must
/// serialize all calls. This trusted probe does not validate native pointers.
export fn nih_app_probe_attach(bytes: [*]u8, len: u32, width: u32, height: u32, stride: u32) callconv(.c) i32 {
    if (current != null) return -3;
    current = Surface.init(bytes[0..len], width, height, stride) orelse return -1;
    return 0;
}
export fn nih_app_probe_detach() callconv(.c) void {
    current = null;
}
fn rgb565(rgb: u32) u16 {
    return @intCast(((rgb >> 8) & 0xf800) | ((rgb >> 5) & 0x07e0) | ((rgb >> 3) & 0x001f));
}
export fn nih_app_fill_rect(x: i32, y: i32, width: u32, height: u32, rgb: u32) callconv(.c) i32 {
    const surface = current orelse return -3;
    if (rgb > 0xffffff) return -1;
    return if (surface.fillRect(x, y, width, height, rgb565(rgb))) 0 else -1;
}
export fn nih_app_text(x: i32, y: i32, bytes: [*]const u8, len: u32, rgb: u32) callconv(.c) i32 {
    const surface = current orelse return -3;
    if (len > 128 or rgb > 0xffffff) return -1;
    const text = bytes[0..len];
    for (text) |ch| if (ch < 32 or ch > 126) {
        return -2;
    };
    const end = @as(i64, x) + @as(i64, len) * 8;
    if (end > 2147483647) return -1;
    var mask: [64]u8 = undefined;
    for (text, 0..) |ch, index| {
        const offset = (@as(usize, ch) - 32) * 8;
        for (0..8) |row| for (0..8) |col| {
            mask[row * 8 + col] = if (font[offset + row] & (@as(u8, 1) << @as(u3, @intCast(col))) != 0) 255 else 0;
        };
        const glyph_x: i32 = @intCast(@as(i64, x) + @as(i64, @intCast(index)) * 8);
        if (!surface.blit(.{ .bytes = &mask, .width = 8, .height = 8, .stride = 8 }, glyph_x, y, rgb565(rgb))) return -1;
    }
    return 0;
}

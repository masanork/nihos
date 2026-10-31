//! Separately linked foreground renderer: code and boot faces stay in mapped Flash.
const session = @import("render_session.zig");
const protocol = @import("render_protocol.zig");
const ttf = @import("viewport_layout").ttf;
const mincho: []const u8 = @embedFile("fonts/mincho.ttf");
const gothic: []const u8 = @embedFile("fonts/gothic.ttf");
pub export fn nih_xy_render_bytes() callconv(.c) usize {
    return @sizeOf(session.Session);
}
pub export fn nih_xy_render_init(bytes: [*]u8, length: usize) callconv(.c) bool {
    if (length < @sizeOf(session.Session) or @intFromPtr(bytes) % @alignOf(session.Session) != 0) return false;
    const instance: *session.Session = @ptrCast(@alignCast(bytes));
    instance.init(ttf.SliceReader.fromSlice(&mincho), ttf.SliceReader.fromSlice(&gothic)) catch return false;
    return true;
}
pub export fn nih_xy_render(request: *const protocol.Request) callconv(.c) bool {
    const instance: *session.Session = @ptrCast(@alignCast(request.workspace));
    instance.render(request) catch return false;
    return true;
}

test "boot faces render Japanese spaces missing glyphs and live view settings" {
    const std = @import("std");
    const config_module = @import("view_config");
    const instance = try std.testing.allocator.create(session.Session);
    defer std.testing.allocator.destroy(instance);
    try instance.init(ttf.SliceReader.fromSlice(&mincho), ttf.SliceReader.fromSlice(&gothic));
    const pixels = try std.testing.allocator.alloc(u8, 720 * 1280 * 2);
    defer std.testing.allocator.free(pixels);
    var config = config_module.Config{};
    const sample = "日本語 あいうえお ABC\n青空文庫 𠮷";
    var request = protocol.Request{ .workspace = instance, .frame = pixels.ptr, .frame_length = pixels.len, .config = &config, .text = sample.ptr, .text_length = sample.len, .cursor = sample.len, .status = "(view/set! #:size 36)", .status_length = "(view/set! #:size 36)".len, .show_cursor = 1 };
    for ([_]u8{ 8, 24, 36, 64, 96 }) |size| {
        for (0..2) |style| {
            config.style.style_id = @intCast(style);
            config.style.body_px = size;
            config.style.axis = @intCast(style);
            try instance.render(&request);
            try std.testing.expect(instance.cache.bitmap_misses > 0);
        }
    }
    const viewport = @import("viewport_layout");
    const adapter = @import("render_adapter.zig");
    var paragraph_glyphs: [8]viewport.PlacedGlyph = @splat(.{});
    const paragraph_view = viewport.ViewStyle{};
    const paragraphs = try viewport.layoutParagraph(8, 64, 1, session.Cache, &instance.cache, .{ .faces = instance.faces[0..1] }, paragraph_view, "A\n\n", "", &.{}, &instance.scratch, &paragraph_glyphs);
    const paragraph_caret = adapter.computeCursorRect(paragraph_view, paragraphs, 3);
    try std.testing.expectEqual(@as(i32, paragraph_view.margin_y_px) + paragraph_view.ruby_px + 2 * (@as(i32, paragraph_view.body_px) + paragraph_view.ruby_px + paragraph_view.line_gap_px), paragraph_caret.y_px);
    var long_text: [2048]u8 = @splat('A');
    for (&long_text, 0..) |*c, i| if (i % 32 == 31) {
        c.* = '\n';
    };
    request.text = &long_text;
    request.text_length = long_text.len;
    request.cursor = long_text.len;
    for (0..2) |axis| {
        config.style.axis = @intCast(axis);
        config.style.body_px = 96;
        try instance.render(&request);
    }
    try config.set("foreground", .{ .number = 0x123456 });
    try config.set("background", .{ .number = 0xabcdef });
    request.text_length = 0;
    request.cursor = 0;
    try instance.render(&request);
    const expected = @import("render_adapter.zig").rgb565(0xab, 0xcd, 0xef);
    try std.testing.expectEqual(expected, std.mem.readInt(u16, pixels[0..2], .little));
}

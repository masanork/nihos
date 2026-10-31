//! Separately linked foreground renderer: code and boot faces stay in mapped Flash.
const session = @import("render_session.zig");
const reading = @import("native_reading.zig");
const catalog = @import("catalog.zig");
const learning = @import("learning_session.zig");
const Workspace = struct { renderer: reading.Session, lessons: learning.Session };
comptime {
    if (@sizeOf(Workspace) > 2 * 1024 * 1024) @compileError("xy render and lesson workspace exceeds PSRAM budget");
}
extern var nih_xy_reading_start: u8;
extern var nih_xy_reading_end: u8;
fn readingPack() catalog.Error!catalog.Pack {
    if (@import("builtin").is_test) return error.InvalidPack;
    const start: [*]const u8 = @ptrCast(&nih_xy_reading_start);
    const length = @intFromPtr(&nih_xy_reading_end) - @intFromPtr(&nih_xy_reading_start);
    return catalog.Pack.init(start[0..length]);
}
const protocol = @import("render_protocol.zig");
const ttf = @import("viewport_layout").ttf;
const mincho: []const u8 = @embedFile("fonts/mincho.ttf");
const gothic: []const u8 = @embedFile("fonts/gothic.ttf");
pub export fn nih_xy_render_bytes() callconv(.c) usize {
    return @sizeOf(Workspace);
}
pub export fn nih_xy_render_init(bytes: [*]u8, length: usize) callconv(.c) bool {
    if (length < @sizeOf(Workspace) or @intFromPtr(bytes) % @alignOf(Workspace) != 0) return false;
    const owner: *Workspace = @ptrCast(@alignCast(bytes));
    const instance = &owner.renderer;
    const pack = readingPack() catch return false;
    const mincho_font = pack.font(0) catch return false;
    const gothic_font = pack.font(1) catch return false;
    instance.initSlices(mincho_font, gothic_font) catch return false;
    owner.lessons.initInPlace();
    if (pack.learningBytes() catch return false) |data| owner.lessons.bind(data) catch return false;
    return true;
}
pub export fn nih_xy_render_learning(bytes: [*]u8) callconv(.c) *learning.Session {
    const owner: *Workspace = @ptrCast(@alignCast(bytes));
    return &owner.lessons;
}
pub export fn nih_xy_render(request: *const protocol.Request) callconv(.c) bool {
    const owner: *Workspace = @ptrCast(@alignCast(request.workspace));
    const instance = &owner.renderer;
    if (request.navigation) |nav| {
        const pack = readingPack() catch return false;
        reading.render(instance, request, pack) catch |err| {
            nav.error_code = @intFromError(err);
            return false;
        };
    } else instance.render(request) catch return false;
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
    const ruby_spans = [_]protocol.RubySpan{.{ .base_start = 2040, .base_end = 2043, .ruby_start = 0, .ruby_end = 1 }};
    request.ruby_text = "B";
    request.ruby_text_length = 1;
    request.ruby_spans = &ruby_spans;
    request.ruby_count = 1;
    config.style.body_px = 25;
    for (0..2) |axis| {
        config.style.axis = @intCast(axis);
        @memset(std.mem.asBytes(&instance.placed), 0);
        try instance.render(&request);
        var ruby_glyphs: usize = 0;
        for (instance.placed) |g| if (g.run == 1) {
            ruby_glyphs += 1;
        };
        try std.testing.expect(ruby_glyphs > 0);
    }
    request.ruby_count = 0;
    try config.set("foreground", .{ .number = 0x123456 });
    try config.set("background", .{ .number = 0xabcdef });
    request.text_length = 0;
    request.cursor = 0;
    try instance.render(&request);
    const expected = @import("render_adapter.zig").rgb565(0xab, 0xcd, 0xef);
    try std.testing.expectEqual(expected, std.mem.readInt(u16, pixels[0..2], .little));
}

test "native rotated scanout and desktop logical presentation match every pixel" {
    const std = @import("std");
    const instance = try std.testing.allocator.create(session.Session);
    defer std.testing.allocator.destroy(instance);
    try instance.init(ttf.SliceReader.fromSlice(&mincho), ttf.SliceReader.fromSlice(&gothic));
    const byte_count = 1280 * 720 * 2;
    const native = try std.testing.allocator.alloc(u8, byte_count + 16);
    defer std.testing.allocator.free(native);
    const logical = try std.testing.allocator.alloc(u8, byte_count + 16);
    defer std.testing.allocator.free(logical);
    @memset(native, 0xa5);
    @memset(logical, 0xa5);
    var config = @import("view_config").Config{};
    config.style.body_px = 25;
    config.style.ruby_px = 6;
    config.style.line_gap_px = 0;
    const text = "ASCII: 0123456789 ilMW () []\n日本語表示 あいうえお";
    const status = "xy / *scratch*  Source Code Pro";
    const ruby_spans = [_]protocol.RubySpan{.{ .base_start = 29, .base_end = 38, .ruby_start = 0, .ruby_end = "にほんご".len }};
    var request = protocol.Request{ .workspace = instance, .frame = native.ptr, .frame_length = byte_count, .config = &config, .text = text.ptr, .text_length = text.len, .cursor = text.len, .status = status.ptr, .status_length = status.len, .show_cursor = 1, .ruby_text = "にほんご", .ruby_text_length = "にほんご".len, .ruby_spans = &ruby_spans, .ruby_count = 1 };
    for (0..2) |axis| {
        config.style.axis = @intCast(axis);
        request.frame = native.ptr;
        try instance.render(&request);
        request.frame = logical.ptr;
        try instance.renderLogical(&request, 1280, 720, 2560);
        for (0..720) |y| for (0..1280) |x| {
            const physical = (1279 - x) * 1440 + y * 2;
            const desktop = y * 2560 + x * 2;
            try std.testing.expectEqualSlices(u8, native[physical..][0..2], logical[desktop..][0..2]);
        };
    }
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0xa5))), native[byte_count..]);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0xa5))), logical[byte_count..]);
}

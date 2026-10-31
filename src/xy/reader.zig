//! Bounded page fitting on the same glyph positions used for RGB565/RGBA.
//! Source offsets are UTF-8 bytes. A ruby base is indivisible across pages.
const std = @import("std");
const document = @import("document.zig");
pub const RubySpan = document.RubySpan;

pub fn validate(text: []const u8, readings: []const u8, spans: []const RubySpan) !void {
    if (text.len > 4096 or readings.len > 1024 or spans.len > 64) return error.Capacity;
    if (!std.unicode.utf8ValidateSlice(text) or !std.unicode.utf8ValidateSlice(readings)) return error.InvalidUtf8;
    var previous: u32 = 0;
    for (spans) |span| {
        if (span.base_start < previous or span.base_start >= span.base_end or span.base_end > text.len or span.ruby_start >= span.ruby_end or span.ruby_end > readings.len) return error.Range;
        if (!document.isClusterBoundary(text, span.base_start) or !document.isClusterBoundary(text, span.base_end) or !document.isClusterBoundary(readings, span.ruby_start) or !document.isClusterBoundary(readings, span.ruby_end)) return error.InvalidUtf8;
        previous = span.base_end;
    }
}

pub fn closeBoundary(end: usize, spans: []const RubySpan) usize {
    var result = end;
    for (spans) |span| {
        if (span.base_start < result and span.base_end > result) result = span.base_start;
    }
    return result;
}

/// Strictly reduce a candidate at a grapheme and group-ruby boundary.
pub fn shorter(text: []const u8, end: usize, spans: []const RubySpan) !usize {
    // Geometric backoff keeps large font sizes bounded instead of re-rasterizing
    // hundreds of prefixes one character at a time.
    const target = end * 3 / 4;
    var cut: usize = 0;
    var at: usize = 0;
    while (at < end) {
        at = try document.nextClusterEnd(text, at);
        if (at > target) break;
        cut = at;
    }
    return closeBoundary(cut, spans);
}

/// Find the first body cluster whose cell does not fit the usable page.
/// Ruby glyphs use their annotation's body start as the break position.
pub fn visibleEnd(text_len: usize, spans: []const RubySpan, placed: anytype, style: anytype) usize {
    var end = text_len;
    for (placed) |g| {
        const x = g.cell_x_px;
        const y = g.cell_y_px;
        const width: i32 = if (style.axis == 0) g.advance_px else g.px_size;
        const height: i32 = if (style.axis == 0) g.px_size else g.advance_px;
        // Ruby occupies the reserved band just outside the body margins.
        const min_x: i32 = if (g.run == 0) style.margin_x_px else 0;
        const min_y: i32 = if (g.run == 0) style.margin_y_px else 0;
        const max_x: i32 = @as(i32, style.viewport_width_px) - (if (g.run == 0) @as(i32, style.margin_x_px) else 0);
        const max_y: i32 = @as(i32, style.viewport_height_px) - (if (g.run == 0) @as(i32, style.margin_y_px) else 0);
        if (x < min_x or y < min_y or x + width > max_x or y + height > max_y) {
            if (g.run == 0) end = @min(end, g.cluster_byte_offset) else for (spans) |span| {
                if (span.ruby_start <= g.cluster_byte_offset and g.cluster_byte_offset < span.ruby_end) end = @min(end, span.base_start);
            }
        }
    }
    return closeBoundary(end, spans);
}

test "reader rejects invalid UTF-8 and split ruby and keeps groups with their base" {
    const text = "葛\u{E0100}の山";
    const spans = [_]RubySpan{.{ .base_start = 0, .base_end = 7, .ruby_start = 0, .ruby_end = 6 }};
    try validate(text, "かつ", &spans);
    try std.testing.expectEqual(@as(usize, 0), closeBoundary(3, &spans));
    try std.testing.expectEqual(@as(usize, 7), closeBoundary(7, &spans));
    try std.testing.expectEqual(@as(usize, 7), try shorter(text, 10, &spans));
    try std.testing.expectError(error.InvalidUtf8, validate("\xff", "", &.{}));
    var broken = spans;
    broken[0].base_end = 3; // Before IVS is not a grapheme boundary.
    try std.testing.expectError(error.InvalidUtf8, validate(text, "かつ", &broken));
}

test "ruby may occupy the reserved margin band but body must fit the page" {
    const Glyph = struct { cell_x_px: i32, cell_y_px: i32, px_size: u8, run: u8, cluster_byte_offset: u32, advance_px: u16 = 32 };
    const Style = struct { margin_x_px: u16 = 24, margin_y_px: u16 = 24, viewport_width_px: u16 = 1280, viewport_height_px: u16 = 680, axis: u8 = 0 };
    const spans = [_]RubySpan{.{ .base_start = 0, .base_end = 3, .ruby_start = 0, .ruby_end = 3 }};
    var glyphs = [_]Glyph{
        .{ .cell_x_px = 24, .cell_y_px = 40, .px_size = 32, .run = 0, .cluster_byte_offset = 0 },
        .{ .cell_x_px = 24, .cell_y_px = 22, .px_size = 16, .run = 1, .cluster_byte_offset = 0 },
    };
    try std.testing.expectEqual(@as(usize, 3), visibleEnd(3, &spans, &glyphs, Style{}));
    glyphs[0].cell_y_px = 660;
    try std.testing.expectEqual(@as(usize, 0), visibleEnd(3, &spans, &glyphs, Style{}));
}

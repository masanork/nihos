//! Module 2: Viewport Layout & Extended Grapheme (IVS / Dakuten) Shaper.
//! Bridges UTF-8 text + Ruby annotations through `japanese_break.zig`,
//! `line_layout.zig`, `ruby_layout.zig`, and `ttf.zig` to produce a
//! C-ABI Display List (`PlacedGlyph`) for both `nihos` (Tab5 framebuffer)
//! and macOS/PC (`GPUI` backend).
const std = @import("std");
pub const code_font = @import("code_font.zig");
pub const book_font = @import("book_font.zig");
pub const CodeSpan = @import("view_config").CodeSpan;
pub const ttf = @import("ttf.zig");
pub const ruby = @import("ruby_layout.zig");
pub const policy = ruby.policy;
pub const layout = policy.layout;

pub const Error = ttf.Error || ruby.Error || error{
    InvalidUtf8,
    ViewportTooSmall,
};

/// Live-configurable view parameters controllable from Scheme `(view/set! ...)`.
pub const ViewStyle = @import("view_config").Style;

/// C-ABI Display List item representing a positioned glyph ready for either
/// Tab5 RGB565 alpha-blitting or GPUI texture-atlas rendering.
pub const PlacedGlyph = extern struct {
    base_cp: u32 = 0,
    ivs_cp: u32 = 0,
    cluster_byte_offset: u32 = 0,
    run: u8 = 0, // 0: body, 1: ruby
    style_id: u8 = 0,
    px_size: u8 = 0,
    vertical: u8 = 0,
    /// Top-left cell origin in screen pixel coordinates
    cell_x_px: i32 = 0,
    cell_y_px: i32 = 0,
    /// Exact bitmap draw position in screen pixel coordinates
    bitmap_x_px: i32 = 0,
    bitmap_y_px: i32 = 0,
    bitmap_width: u16 = 0,
    bitmap_height: u16 = 0,
    /// Inline advance; base_cp=0 identifies an invisible paragraph caret anchor.
    advance_px: u16 = 0,
};

/// Internal shaped glyph compatible with `line_layout.zig` and `ruby_layout.zig`.
pub const ShapedGlyph = struct {
    style_id: u4 = 0,
    id: u32 = 1,
    cluster: u32 = 0,
    run: u32 = 0,
    base_cp: u21 = 0,
    ivs_cp: u21 = 0,
    px_size: u8 = 0,
    x_advance: i32 = 0,
    y_advance: i32 = 0,
    left_px: i16 = 0,
    top_px: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub inline fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

/// Combine base kana + combining Voiced/Semi-Voiced mark (U+3099 / U+309A) into
/// precomposed NFC codepoint when possible so single-glyph lookup succeeds.
pub inline fn composeDakuten(base: u21, mark: u21) ?u21 {
    if (mark == 0x3099) {
        return switch (base) {
            // Hiragana か..と, は..ほ, う
            0x304B,
            0x304D,
            0x304F,
            0x3051,
            0x3053,
            0x3055,
            0x3057,
            0x3059,
            0x305B,
            0x305D,
            0x305F,
            0x3061,
            0x3064,
            0x3066,
            0x3068,
            0x306F,
            0x3072,
            0x3075,
            0x3078,
            0x307B,
            0x309D,
            // Katakana カ..ト, ハ..ホ, ヽ
            0x30AB,
            0x30AD,
            0x30AF,
            0x30B1,
            0x30B3,
            0x30B5,
            0x30B7,
            0x30B9,
            0x30BB,
            0x30BD,
            0x30BF,
            0x30C1,
            0x30C4,
            0x30C6,
            0x30C8,
            0x30CF,
            0x30D2,
            0x30D5,
            0x30D8,
            0x30DB,
            0x30FD,
            => base + 1,
            0x3046 => 0x3094, // う + ゛ -> ゔ
            0x30A6 => 0x30F4, // ウ + ゛ -> ヴ
            else => null,
        };
    } else if (mark == 0x309A) {
        return switch (base) {
            // Hiragana & Katakana は..ほ / ハ..ホ
            0x306F,
            0x3072,
            0x3075,
            0x3078,
            0x307B,
            0x30CF,
            0x30D2,
            0x30D5,
            0x30D8,
            0x30DB,
            => base + 2,
            else => null,
        };
    }
    return null;
}

pub const GraphemeCluster = struct {
    base_cp: u21,
    ivs_cp: u21 = 0,
    byte_start: u32,
    byte_end: u32,
};

/// Iterate extended grapheme clusters for Japanese text (handling UTF-8 + IVS
/// U+FE00..U+FE0F / U+E0100..U+E01EF + combining dakuten U+3099/U+309A).
pub const ClusterIterator = struct {
    text: []const u8,
    index: usize = 0,

    pub fn next(self: *ClusterIterator) Error!?GraphemeCluster {
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const len0 = std.unicode.utf8ByteSequenceLength(self.text[self.index]) catch return error.InvalidUtf8;
        if (self.index + len0 > self.text.len) return error.InvalidUtf8;
        var base_cp = std.unicode.utf8Decode(self.text[self.index .. self.index + len0]) catch return error.InvalidUtf8;
        self.index += len0;

        var ivs_cp: u21 = 0;
        while (self.index < self.text.len) {
            const len1 = std.unicode.utf8ByteSequenceLength(self.text[self.index]) catch return error.InvalidUtf8;
            if (self.index + len1 > self.text.len) return error.InvalidUtf8;
            const next_cp = std.unicode.utf8Decode(self.text[self.index .. self.index + len1]) catch return error.InvalidUtf8;

            if (isVariationSelector(next_cp) and ivs_cp == 0) {
                ivs_cp = next_cp;
                self.index += len1;
            } else if (composeDakuten(base_cp, next_cp)) |composed| {
                base_cp = composed;
                self.index += len1;
            } else {
                break;
            }
        }

        return .{
            .base_cp = base_cp,
            .ivs_cp = ivs_cp,
            .byte_start = @intCast(start),
            .byte_end = @intCast(self.index),
        };
    }
};

/// Shape a single UTF-8 run (`run_id = 0` for body, `run_id = 1` for ruby) into `out_glyphs`.
pub fn shapeRun(
    comptime CacheType: type,
    cache: *CacheType,
    family: ttf.Family,
    style_id: u4,
    px_size: u8,
    vertical: bool,
    run_id: u32,
    text: []const u8,
    glyf_scratch: []u8,
    out_glyphs: []ShapedGlyph,
) Error!usize {
    return shapeStyledRun(CacheType, cache, family, style_id, px_size, vertical, run_id, text, glyf_scratch, out_glyphs, &.{}, 0);
}

pub fn shapeStyledRun(
    comptime CacheType: type,
    cache: *CacheType,
    family: ttf.Family,
    style_id: u4,
    px_size: u8,
    vertical: bool,
    run_id: u32,
    text: []const u8,
    glyf_scratch: []u8,
    out_glyphs: []ShapedGlyph,
    spans: []const CodeSpan,
    origin: u32,
) Error!usize {
    var it = ClusterIterator{ .text = text };
    var count: usize = 0;
    while (try it.next()) |cl| {
        if (count >= out_glyphs.len) return error.Capacity;
        const absolute = origin + cl.byte_start;
        var selected_style = style_id;
        for (spans) |span| if (absolute >= span.start and absolute < span.end) {
            selected_style = if (style_id == 4) 5 else 3;
            break;
        };
        const rendered = try cache.getOrRender(
            family,
            selected_style,
            cl.base_cp,
            cl.ivs_cp,
            px_size,
            vertical,
            glyf_scratch,
        );
        out_glyphs[count] = .{
            .id = 1,
            .style_id = selected_style,
            .cluster = cl.byte_start,
            .run = run_id,
            .base_cp = cl.base_cp,
            .ivs_cp = cl.ivs_cp,
            .px_size = px_size,
            .x_advance = rendered.metrics.x_advance_26_6,
            .y_advance = rendered.metrics.y_advance_26_6,
            .left_px = rendered.metrics.left_px,
            .top_px = rendered.metrics.top_px,
            .width = rendered.metrics.width,
            .height = rendered.metrics.height,
        };
        count += 1;
    }
    return count;
}

/// Lay out one or more `\n`-separated paragraphs with optional group-ruby annotations
/// according to `ViewStyle` and emit a flat `PlacedGlyph` Display List.
pub fn layoutParagraph(
    comptime max_glyphs: usize,
    comptime max_body_bytes: usize,
    comptime max_ruby_bytes: usize,
    comptime CacheType: type,
    cache: *CacheType,
    family: ttf.Family,
    view: ViewStyle,
    body_text: []const u8,
    ruby_text: []const u8,
    annotations: []const ruby.Annotation,
    glyf_scratch: []u8,
    out_display_list: []PlacedGlyph,
) Error![]PlacedGlyph {
    return layoutParagraphWithWordWrap(max_glyphs, max_body_bytes, max_ruby_bytes, CacheType, cache, family, view, body_text, ruby_text, annotations, glyf_scratch, out_display_list, false);
}

pub fn layoutParagraphWithWordWrap(
    comptime max_glyphs: usize,
    comptime max_body_bytes: usize,
    comptime max_ruby_bytes: usize,
    comptime CacheType: type,
    cache: *CacheType,
    family: ttf.Family,
    view: ViewStyle,
    body_text: []const u8,
    ruby_text: []const u8,
    annotations: []const ruby.Annotation,
    glyf_scratch: []u8,
    out_display_list: []PlacedGlyph,
    comptime wrap_words: bool,
) Error![]PlacedGlyph {
    return layoutStyledParagraph(max_glyphs, max_body_bytes, max_ruby_bytes, CacheType, cache, family, view, body_text, ruby_text, annotations, glyf_scratch, out_display_list, wrap_words, &.{});
}

pub fn layoutStyledParagraph(
    comptime max_glyphs: usize,
    comptime max_body_bytes: usize,
    comptime max_ruby_bytes: usize,
    comptime CacheType: type,
    cache: *CacheType,
    family: ttf.Family,
    view: ViewStyle,
    body_text: []const u8,
    ruby_text: []const u8,
    annotations: []const ruby.Annotation,
    glyf_scratch: []u8,
    out_display_list: []PlacedGlyph,
    comptime wrap_words: bool,
    code_spans: []const CodeSpan,
) Error![]PlacedGlyph {
    if (body_text.len == 0 or body_text.len > max_body_bytes or ruby_text.len > max_ruby_bytes)
        return error.Capacity;

    var previous: u32 = 0;
    for (code_spans) |span| {
        if (span.start < previous or span.start >= span.end or span.end > body_text.len) return error.Range;
        if ((span.start < body_text.len and body_text[span.start] & 0xc0 == 0x80) or (span.end < body_text.len and body_text[span.end] & 0xc0 == 0x80)) return error.InvalidUtf8;
        previous = span.end;
    }
    const axis: layout.Axis = if (view.axis == 0) .horizontal else .vertical;
    const is_vert = axis == .vertical;
    const style_u4: u4 = @intCast(view.style_id & 0x0F);

    const usable_w: i32 = @as(i32, view.viewport_width_px) - 2 * @as(i32, view.margin_x_px);
    const usable_h: i32 = @as(i32, view.viewport_height_px) - 2 * @as(i32, view.margin_y_px);
    if (usable_w <= @as(i32, view.body_px) or usable_h <= @as(i32, view.body_px))
        return error.ViewportTooSmall;

    const inline_limit_26_6: i32 = (if (is_vert) usable_h else usable_w) * 64;
    const step_px: i32 = @as(i32, view.body_px) + @as(i32, view.ruby_px) + @as(i32, view.line_gap_px);
    const step_26_6: i32 = step_px * 64;
    const max_lines: u16 = @intCast(@max(1, @divTrunc(if (is_vert) usable_w else usable_h, step_px) + 2));
    const cross_offset_26_6: i32 = (@as(i32, view.ruby_px) + @as(i32, view.ruby_gap_px)) * 64;

    var ruby_map: [max_ruby_bytes + 1]policy.Boundary = undefined;
    try policy.map(ruby_text, ruby_map[0 .. ruby_text.len + 1]);

    var body_map: [max_body_bytes + 1]policy.Boundary = undefined;
    var shaped: [max_glyphs]ShapedGlyph = undefined;
    // Body shaping must not overwrite ruby glyphs stored in the same array.
    var ruby_shaped: [@min(max_glyphs / 2, 512)]ShapedGlyph = undefined;

    const ruby_count = try shapeRun(
        CacheType,
        cache,
        family,
        style_u4,
        view.ruby_px,
        is_vert,
        1,
        ruby_text,
        glyf_scratch,
        &ruby_shaped,
    );

    var total_emitted: usize = 0;
    var para_block_offset_px: i32 = 0;

    var p_start: usize = 0;
    while (p_start <= body_text.len) {
        var p_end = p_start;
        while (p_end < body_text.len and body_text[p_end] != '\n' and body_text[p_end] != '\r') : (p_end += 1) {}

        const para_slice = body_text[p_start..p_end];
        if (para_slice.len > 0 and !((view.style_id == 2 or view.style_id == 4) and std.mem.trim(u8, para_slice, " \t").len == 0)) {
            try policy.map(para_slice, body_map[0 .. para_slice.len + 1]);

            const body_count = try shapeStyledRun(
                CacheType,
                cache,
                family,
                style_u4,
                view.body_px,
                is_vert,
                0,
                para_slice,
                glyf_scratch,
                shaped[0 .. max_glyphs - ruby_count],
                code_spans,
                @intCast(p_start),
            );

            if (wrap_words) keepWords(shaped[0..body_count], body_map[0 .. para_slice.len + 1], inline_limit_26_6, is_vert);

            // Copy only ruby annotations belonging to `[p_start, p_end)`
            var local_anns: [64]ruby.Annotation = undefined;
            var local_ann_count: usize = 0;
            const p_start_u32: u32 = @intCast(p_start);
            for (annotations) |ann| {
                if (ann.base.start >= p_start and ann.base.end <= p_end and local_ann_count < local_anns.len) {
                    local_anns[local_ann_count] = .{
                        .base = .{ .start = ann.base.start - p_start_u32, .end = ann.base.end - p_start_u32 },
                        .ruby = ann.ruby,
                    };
                    local_ann_count += 1;
                }
            }

            // Append ruby glyphs after `shaped[0..body_count]` when annotations exist in this paragraph
            var para_total = body_count;
            var para_ruby_bytes: usize = 0;
            var para_ruby_start: u32 = 0;
            if (local_ann_count > 0) {
                const ruby_start = local_anns[0].ruby.start;
                para_ruby_start = ruby_start;
                const ruby_end = local_anns[local_ann_count - 1].ruby.end;
                if (ruby_end < ruby_start or ruby_end > ruby_text.len) return error.Range;
                para_ruby_bytes = ruby_end - ruby_start;
                try policy.map(ruby_text[ruby_start..ruby_end], ruby_map[0 .. para_ruby_bytes + 1]);
                for (local_anns[0..local_ann_count]) |*ann| {
                    if (ann.ruby.start < ruby_start or ann.ruby.end > ruby_end) return error.Range;
                    ann.ruby.start -= ruby_start;
                    ann.ruby.end -= ruby_start;
                }
                for (ruby_shaped[0..ruby_count]) |g| {
                    if (g.cluster < ruby_start or g.cluster >= ruby_end) continue;
                    var local_glyph = g;
                    local_glyph.cluster -= ruby_start;
                    shaped[para_total] = local_glyph;
                    para_total += 1;
                }
            } else {
                try policy.map("", ruby_map[0..1]);
            }

            const initial_flow = try layout.Flow.init(inline_limit_26_6, step_26_6, max_lines);
            const plan = try ruby.plan(
                max_glyphs,
                ShapedGlyph,
                shaped[0..para_total],
                body_map[0 .. para_slice.len + 1],
                ruby_map[0 .. para_ruby_bytes + 1],
                local_anns[0..local_ann_count],
                axis,
                initial_flow,
                cross_offset_26_6,
            );

            var max_block_px_in_para: i32 = 0;
            for (shaped[0..para_total], 0..) |g, i| {
                // Skip ruby glyphs that did not belong to any annotation in this paragraph
                if (g.run == 1) {
                    var matched = false;
                    for (local_anns[0..local_ann_count]) |la| {
                        if (g.cluster >= la.ruby.start and g.cluster < la.ruby.end) {
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) continue;
                }

                if (total_emitted >= out_display_list.len) return error.Capacity;
                const pos = plan.positions[i];
                const inline_px = @divTrunc(pos.inline_offset + 32, 64);
                const block_px = para_block_offset_px + @divTrunc(pos.block_offset + 32, 64);
                if (g.run == 0) {
                    max_block_px_in_para = @max(max_block_px_in_para, @divTrunc(pos.block_offset + 32, 64));
                }

                var cell_x: i32 = 0;
                var cell_y: i32 = 0;
                if (!is_vert) {
                    cell_x = @as(i32, view.margin_x_px) + inline_px;
                    cell_y = @as(i32, view.margin_y_px) + @as(i32, view.ruby_px) + block_px;
                } else {
                    const right_col_x = @as(i32, view.viewport_width_px) - @as(i32, view.margin_x_px) - @as(i32, view.ruby_px) - @as(i32, view.body_px);
                    cell_x = right_col_x - block_px;
                    if (g.run == 1) {
                        cell_x = right_col_x - (block_px + @as(i32, view.ruby_px) + @as(i32, view.ruby_gap_px)) + @as(i32, view.body_px) + @as(i32, view.ruby_gap_px);
                    }
                    cell_y = @as(i32, view.margin_y_px) + inline_px;
                }

                const baseline_y = cell_y + @divTrunc(@as(i32, g.px_size) * 880 + 512, 1024);
                out_display_list[total_emitted] = .{
                    .base_cp = g.base_cp,
                    .ivs_cp = g.ivs_cp,
                    .cluster_byte_offset = if (g.run == 0) g.cluster + @as(u32, @intCast(p_start)) else g.cluster + para_ruby_start,
                    .run = @intCast(g.run),
                    .style_id = g.style_id,
                    .px_size = g.px_size,
                    .vertical = @intFromBool(is_vert),
                    .cell_x_px = cell_x,
                    .cell_y_px = cell_y,
                    .bitmap_x_px = cell_x + g.left_px,
                    .bitmap_y_px = baseline_y - g.top_px,
                    .bitmap_width = g.width,
                    .bitmap_height = g.height,
                    .advance_px = @intCast(@divTrunc((if (is_vert) -g.y_advance else g.x_advance) + 32, 64)),
                };
                total_emitted += 1;
            }
            para_block_offset_px += max_block_px_in_para + step_px;
        } else {
            para_block_offset_px += if (view.style_id == 2 or view.style_id == 4) @max(2, @divTrunc(step_px, 4)) else step_px;
        }

        if (p_end >= body_text.len) break;
        const next_start = if (body_text[p_end] == '\r' and p_end + 1 < body_text.len and body_text[p_end + 1] == '\n') p_end + 2 else p_end + 1;
        if (total_emitted >= out_display_list.len) return error.Capacity;
        out_display_list[total_emitted] = .{
            .cluster_byte_offset = @intCast(next_start),
            .px_size = view.body_px,
            .style_id = view.style_id,
            .vertical = @intFromBool(is_vert),
            .cell_x_px = if (is_vert) @as(i32, view.viewport_width_px) - view.margin_x_px - view.ruby_px - view.body_px - para_block_offset_px else view.margin_x_px,
            .cell_y_px = if (is_vert) view.margin_y_px else @as(i32, view.margin_y_px) + view.ruby_px + para_block_offset_px,
        };
        total_emitted += 1;
        p_start = next_start;
    }

    return out_display_list[0..total_emitted];
}

// Keep Latin words together in prose, including attached sideways punctuation
// in vertical text. Overlong identifiers retain grapheme-level emergency breaks.
fn keepWords(glyphs: []const ShapedGlyph, boundaries: []policy.Boundary, limit: i32, vertical: bool) void {
    var start: usize = 0;
    while (start < glyphs.len) {
        const cp = glyphs[start].base_cp;
        if (!(if (vertical) ttf.isSideways(cp) else cp < 128 and std.ascii.isAlphanumeric(@intCast(cp)))) {
            start += 1;
            continue;
        }
        var end = start + 1;
        var advance: i64 = if (vertical) -glyphs[start].y_advance else glyphs[start].x_advance;
        while (end < glyphs.len) : (end += 1) {
            const next = glyphs[end].base_cp;
            if (vertical) {
                if (!ttf.isSideways(next)) break;
            } else if (next >= 128 or !(std.ascii.isAlphanumeric(@intCast(next)) or next == '\'' or next == '_')) break;
            advance += if (vertical) -glyphs[end].y_advance else glyphs[end].x_advance;
        }
        if (advance <= limit) {
            for (glyphs[start + 1 .. end]) |g| boundaries[g.cluster].allowed = false;
        }
        start = end;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "sideways words use horizontal advances and wrap together into the next column" {
    const face = try code_font.face();
    const family = ttf.Family{ .faces = &.{face} };
    const Cache = ttf.TwoTierCache(8, 1024, 16, 64 * 64);
    var cache: Cache = .{};
    var scratch: [16384]u8 = undefined;
    var placed: [32]PlacedGlyph = undefined;
    const style = ViewStyle{ .body_px = 20, .ruby_px = 10, .axis = 1, .viewport_width_px = 256, .viewport_height_px = 140 };
    const list = try layoutParagraphWithWordWrap(32, 128, 0, Cache, &cache, family, style, "abc defghij", "", &.{}, &scratch, &placed, true);
    try std.testing.expectEqual(@as(usize, 11), list.len);
    try std.testing.expectEqual(@as(u16, 12), list[0].advance_px);
    try std.testing.expectEqual(list[0].cell_y_px + 12, list[1].cell_y_px);
    try std.testing.expect(list[4].cell_x_px < list[0].cell_x_px);
    try std.testing.expectEqual(@as(i32, style.margin_y_px), list[4].cell_y_px);
    for (list[5..], 5..) |g, i| {
        try std.testing.expectEqual(list[4].cell_x_px, g.cell_x_px);
        try std.testing.expectEqual(list[i - 1].cell_y_px + 12, g.cell_y_px);
    }
}

test "ClusterIterator groups IVS and composes combining dakuten" {
    // "か" (U+304B) + U+3099 -> "が" (U+304C), followed by "葛" (U+845B) + IVS U+E0100
    const text = "\u{304B}\u{3099}\u{845B}\u{E0100}A";
    var it = ClusterIterator{ .text = text };

    const c0 = (try it.next()).?;
    try std.testing.expectEqual(@as(u21, 0x304C), c0.base_cp);
    try std.testing.expectEqual(@as(u21, 0), c0.ivs_cp);
    try std.testing.expectEqual(@as(u32, 0), c0.byte_start);
    try std.testing.expectEqual(@as(u32, 6), c0.byte_end);

    const c1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u21, 0x845B), c1.base_cp);
    try std.testing.expectEqual(@as(u21, 0xE0100), c1.ivs_cp);
    try std.testing.expectEqual(@as(u32, 6), c1.byte_start);
    try std.testing.expectEqual(@as(u32, 13), c1.byte_end);

    const c2 = (try it.next()).?;
    try std.testing.expectEqual(@as(u21, 'A'), c2.base_cp);
    try std.testing.expect((try it.next()) == null);
}

test "layoutParagraph switches live between horizontal and vertical with group ruby and IVS" {
    // Build a test font supporting '葛' (U+845B) + IVS U+E0100 and 'か' (U+304B)
    var font_buf: [512]u8 = undefined;
    // Map U+3040..U+9FFF in Format 12 so both '葛' and 'か' resolve
    const bytes = ttf_test_helper(&font_buf);
    const face = try ttf.Face.init(ttf.SliceReader.fromSlice(&bytes));
    const family = ttf.Family{ .faces = &[_]ttf.Face{face} };

    const CacheType = ttf.TwoTierCache(16, 64, 32, 64 * 64);
    var cache: CacheType = .{};
    var scratch: [256]u8 = undefined;
    var dl: [32]PlacedGlyph = undefined;

    const body = "葛\u{E0100}か";
    const ruby_txt = "かつ";
    const ann = [_]ruby.Annotation{
        .{ .base = .{ .start = 0, .end = 7 }, .ruby = .{ .start = 0, .end = 6 } },
    };

    // 1. Horizontal layout (24px body, 12px ruby)
    const view_h = ViewStyle{ .body_px = 24, .ruby_px = 12, .axis = 0 };
    const list_h = try layoutParagraph(32, 64, 64, CacheType, &cache, family, view_h, body, ruby_txt, &ann, &scratch, &dl);
    // 2 body clusters ("葛+IVS", "か") + 2 ruby clusters ("か", "つ") = 4 PlacedGlyphs
    try std.testing.expectEqual(@as(usize, 4), list_h.len);
    try std.testing.expectEqual(@as(u32, 0x845B), list_h[0].base_cp);
    try std.testing.expectEqual(@as(u32, 0xE0100), list_h[0].ivs_cp);
    // In horizontal mode, ruby (list_h[2]) sits ABOVE body (list_h[0]): smaller Y
    try std.testing.expect(list_h[2].cell_y_px < list_h[0].cell_y_px);
    // Second body glyph advances to the right (+X)
    try std.testing.expect(list_h[1].cell_x_px > list_h[0].cell_x_px);

    const misses_after_h = cache.outline_misses;

    // 2. Live switch to Vertical layout (32px body, 16px ruby) -> ZERO new outline misses!
    const view_v = ViewStyle{ .body_px = 32, .ruby_px = 16, .axis = 1 };
    const list_v = try layoutParagraph(32, 64, 64, CacheType, &cache, family, view_v, body, ruby_txt, &ann, &scratch, &dl);
    try std.testing.expectEqual(@as(usize, 4), list_v.len);
    try std.testing.expectEqual(misses_after_h, cache.outline_misses);
    // In vertical mode, second body glyph advances downward (+Y) in the same column
    try std.testing.expect(list_v[1].cell_y_px > list_v[0].cell_y_px);
    try std.testing.expectEqual(list_v[0].cell_x_px, list_v[1].cell_x_px);
    // Ruby sits to the RIGHT (+X) of the parent vertical body column
    try std.testing.expect(list_v[2].cell_x_px > list_v[0].cell_x_px);
}

test "long body cannot overwrite ruby glyphs and paragraph readings stay local" {
    var font_buf: [512]u8 = undefined;
    const bytes = ttf_test_helper(&font_buf);
    const face = try ttf.Face.init(ttf.SliceReader.fromSlice(&bytes));
    const family = ttf.Family{ .faces = &[_]ttf.Face{face} };
    const CacheType = ttf.TwoTierCache(16, 64, 32, 64 * 64);
    var cache: CacheType = .{};
    var scratch: [256]u8 = undefined;
    var placed: [256]PlacedGlyph = undefined;
    var body: [424]u8 = undefined;
    for (0..140) |i| @memcpy(body[i * 3 ..][0..3], "か");
    @memcpy(body[420..], "\nか");
    const annotations = [_]ruby.Annotation{
        .{ .base = .{ .start = 417, .end = 420 }, .ruby = .{ .start = 0, .end = 3 } },
        .{ .base = .{ .start = 421, .end = 424 }, .ruby = .{ .start = 3, .end = 6 } },
    };
    for (0..2) |axis| {
        const style = ViewStyle{ .body_px = 16, .ruby_px = 8, .axis = @intCast(axis), .viewport_width_px = 4096, .viewport_height_px = 2048 };
        const list = try layoutParagraph(256, 512, 64, CacheType, &cache, family, style, &body, "つつ", &annotations, &scratch, &placed);
        var ruby_count: usize = 0;
        for (list) |glyph| if (glyph.run == 1) {
            try std.testing.expectEqual(@as(u32, 'つ'), glyph.base_cp);
            ruby_count += 1;
        };
        try std.testing.expectEqual(@as(usize, 2), ruby_count);
    }
}

pub fn ttf_test_helper(buf: []u8) []const u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, buf[4..6], 7, .big);
    const head_off: u32 = 124;
    const hhea_off: u32 = 180;
    const maxp_off: u32 = 216;
    const hmtx_off: u32 = 224;
    const loca_off: u32 = 236;
    const cmap_off: u32 = 252;
    const glyf_off: u32 = 340;
    const g1_len: u32 = 36;

    const writeEntry = struct {
        fn f(b: []u8, idx: usize, tag: *const [4]u8, off: u32, len: u32) void {
            const p = 12 + idx * 16;
            @memcpy(b[p .. p + 4], tag);
            std.mem.writeInt(u32, b[p + 8 ..][0..4], off, .big);
            std.mem.writeInt(u32, b[p + 12 ..][0..4], len, .big);
        }
    }.f;
    writeEntry(buf, 0, "cmap", cmap_off, 80);
    writeEntry(buf, 1, "glyf", glyf_off, g1_len);
    writeEntry(buf, 2, "head", head_off, 54);
    writeEntry(buf, 3, "hhea", hhea_off, 36);
    writeEntry(buf, 4, "hmtx", hmtx_off, 8);
    writeEntry(buf, 5, "loca", loca_off, 12);
    writeEntry(buf, 6, "maxp", maxp_off, 6);

    std.mem.writeInt(u16, buf[head_off + 18 ..][0..2], 1000, .big);
    std.mem.writeInt(i16, buf[head_off + 50 ..][0..2], 1, .big);
    std.mem.writeInt(i16, buf[hhea_off + 4 ..][0..2], 880, .big);
    std.mem.writeInt(i16, buf[hhea_off + 6 ..][0..2], -120, .big);
    std.mem.writeInt(u16, buf[hhea_off + 34 ..][0..2], 2, .big);
    std.mem.writeInt(u16, buf[maxp_off + 4 ..][0..2], 2, .big);

    for (0..2) |g| {
        std.mem.writeInt(u16, buf[hmtx_off + g * 4 ..][0..2], 1000, .big);
        std.mem.writeInt(i16, buf[hmtx_off + g * 4 + 2 ..][0..2], 100, .big);
    }
    std.mem.writeInt(u32, buf[loca_off + 0 ..][0..4], 0, .big);
    std.mem.writeInt(u32, buf[loca_off + 4 ..][0..4], 0, .big);
    std.mem.writeInt(u32, buf[loca_off + 8 ..][0..4], g1_len, .big);

    // Format 12 mapping U+0020..U+9FFF all to glyph 1 (start_gid=1, range of 1 group per test char or start_gid=1 with 1-char groups)
    std.mem.writeInt(u16, buf[cmap_off + 2 ..][0..2], 1, .big);
    std.mem.writeInt(u16, buf[cmap_off + 4 ..][0..2], 3, .big);
    std.mem.writeInt(u16, buf[cmap_off + 6 ..][0..2], 10, .big);
    std.mem.writeInt(u32, buf[cmap_off + 8 ..][0..4], 12, .big);

    const f12 = cmap_off + 12;
    std.mem.writeInt(u16, buf[f12 + 0 ..][0..2], 12, .big);
    std.mem.writeInt(u32, buf[f12 + 4 ..][0..4], 52, .big);
    std.mem.writeInt(u32, buf[f12 + 12 ..][0..4], 3, .big); // 3 groups -> all map to gid 1
    const cps = [_]u32{ 0x304B, 0x3064, 0x845B }; // 'か', 'つ', '葛'
    for (cps, 0..) |cp, i| {
        const g_off = f12 + 16 + i * 12;
        std.mem.writeInt(u32, buf[g_off + 0 ..][0..4], cp, .big);
        std.mem.writeInt(u32, buf[g_off + 4 ..][0..4], cp, .big);
        std.mem.writeInt(u32, buf[g_off + 8 ..][0..4], 1, .big);
    }

    const g1 = glyf_off;
    std.mem.writeInt(i16, buf[g1 + 0 ..][0..2], 1, .big);
    std.mem.writeInt(i16, buf[g1 + 2 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 4 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 6 ..][0..2], 800, .big);
    std.mem.writeInt(i16, buf[g1 + 8 ..][0..2], 800, .big);
    std.mem.writeInt(u16, buf[g1 + 10 ..][0..2], 3, .big);
    buf[g1 + 14] = 0x01;
    buf[g1 + 15] = 0x01;
    buf[g1 + 16] = 0x01;
    buf[g1 + 17] = 0x01;
    std.mem.writeInt(i16, buf[g1 + 18 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 20 ..][0..2], 0, .big);
    std.mem.writeInt(i16, buf[g1 + 22 ..][0..2], 700, .big);
    std.mem.writeInt(i16, buf[g1 + 24 ..][0..2], 0, .big);
    std.mem.writeInt(i16, buf[g1 + 26 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 28 ..][0..2], 700, .big);
    std.mem.writeInt(i16, buf[g1 + 30 ..][0..2], 0, .big);
    std.mem.writeInt(i16, buf[g1 + 32 ..][0..2], -700, .big);

    return buf[0 .. glyf_off + g1_len];
}

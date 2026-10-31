//! Shared TrueType viewport session. Caller owns memory and font readers.
const std = @import("std");
const layout = @import("viewport_layout");
const adapter = @import("render_adapter.zig");
const rotated = @import("rotated_surface");
const protocol = @import("render_protocol.zig");
const document = @import("document.zig");
pub const Cache = layout.ttf.TwoTierCache(24, 1024, 48, 128 * 128);
pub const Session = struct {
    cache: Cache,
    faces: [2]layout.ttf.Face,
    scratch: [32768]u8,
    placed: [256]layout.PlacedGlyph,
    status_placed: [128]layout.PlacedGlyph,
    frames: u32,

    pub fn init(self: *Session, mincho: layout.ttf.SliceReader, gothic: layout.ttf.SliceReader) !void {
        // Cache payload is inaccessible until a slot's valid bit is set.
        @memset(std.mem.asBytes(self), 0);
        self.faces[0] = try layout.ttf.Face.init(mincho);
        self.faces[1] = try layout.ttf.Face.init(gothic);
    }
    pub fn render(self: *Session, request: *const protocol.Request) !void {
        const physical = adapter.surface.Surface.init(request.frame[0..request.frame_length], 720, 1280, 1440) orelse return error.Geometry;
        const target = rotated.Rotated.init(physical);
        const config = request.config.*;
        var style = config.style;
        style.viewport_width_px = 1280;
        const status_height = @as(u16, style.body_px) + 2 * @as(u16, config.appearance.status_padding);
        style.viewport_height_px = 720 - status_height;
        const family = layout.ttf.Family{ .faces = self.faces[style.style_id..][0..1] };
        const text = request.text[0..request.text_length];
        if (text.len > 4096) return error.Capacity;
        if (!std.unicode.utf8ValidateSlice(text) or request.cursor > text.len or !document.isClusterBoundary(text, request.cursor)) return error.InvalidUtf8;
        // Size the bounded window to the current typography, then halve it if
        // paragraph breaks consume more lines than the conservative cell budget.
        const inline_px: usize = if (style.axis == 0) 1280 - 2 * @as(usize, style.margin_x_px) else @as(usize, style.viewport_height_px) - 2 * @as(usize, style.margin_y_px);
        const cross_px: usize = if (style.axis == 0) @as(usize, style.viewport_height_px) - 2 * @as(usize, style.margin_y_px) else 1280 - 2 * @as(usize, style.margin_x_px);
        const cells = @max(1, inline_px / style.body_px);
        const lines = @max(1, cross_px / (@as(usize, style.body_px) + style.ruby_px + style.line_gap_px));
        const budget: usize = @min(240, cells * lines);
        var before: usize = @min(160, budget * 2 / 3);
        var after: usize = budget - before;
        // Scan once; repeated prevClusterStart scans would make long buffers
        // quadratic. The ring retains every possible start in the bounded window.
        var boundaries: [241]u16 = @splat(0);
        var scanned: usize = 0;
        var total: usize = 0;
        while (scanned < request.cursor) {
            scanned = try document.nextClusterEnd(text, scanned);
            total += 1;
            boundaries[total % boundaries.len] = @intCast(scanned);
        }
        var cursor: u32 = 0;
        var list: []layout.PlacedGlyph = self.placed[0..0];
        while (true) {
            const used_before: usize = @min(before, total);
            var start: usize = boundaries[(total - used_before) % boundaries.len];
            var end = request.cursor;
            var used_after: usize = 0;
            while (end != text.len and used_after < after + before - used_before) : (used_after += 1) end = try document.nextClusterEnd(text, end);
            const remaining = before + after - used_before - used_after;
            const take_before: usize = @min(total, used_before + remaining);
            start = boundaries[(total - take_before) % boundaries.len];
            cursor = @intCast(request.cursor - start);
            if (start == end) break;
            list = layout.layoutParagraph(256, 4096, 1, Cache, &self.cache, family, style, text[start..end], "", &.{}, &self.scratch, &self.placed) catch |err| switch (err) {
                error.BlockFull, error.Capacity => {
                    before /= 2;
                    after /= 2;
                    continue;
                },
                else => return err,
            };
            break;
        }
        // Follow the caret in either writing direction after wrapping.
        const caret = adapter.computeCursorRect(style, list, cursor);
        const dx = if (style.axis != 0 and caret.x_px < style.margin_x_px) @as(i32, style.margin_x_px) - caret.x_px else 0;
        const bottom: i32 = @as(i32, style.viewport_height_px) - @as(i32, style.margin_y_px);
        const dy = if (style.axis == 0 and caret.y_px + style.body_px > bottom) bottom - caret.y_px - style.body_px else 0;
        for (list) |*g| {
            g.cell_x_px += dx;
            g.bitmap_x_px += dx;
            g.cell_y_px += dy;
            g.bitmap_y_px += dy;
        }
        const theme = adapter.ThemePalette.fromAppearance(config.appearance);
        _ = try adapter.paintSurfaceRgb565(Cache, target, &self.cache, family, style, theme, list, if (request.show_cursor != 0) cursor else null, config.appearance.linear_blend, &self.scratch);
        _ = target.fillRect(0, 720 - status_height, 1280, status_height, theme.minibuf_bg_rgb565);
        // Use the same TrueType shaper for the command/result line.
        var status_style = style;
        status_style.axis = 0;
        status_style.ruby_px = 0;
        status_style.margin_x_px = config.appearance.status_padding;
        status_style.margin_y_px = config.appearance.status_padding;
        status_style.viewport_height_px = 720;
        const full_line = request.status[0..request.status_length];
        var line_end: usize = 0;
        var line_count: usize = 0;
        while (line_end < full_line.len and line_count < 120) : (line_count += 1) line_end = try document.nextClusterEnd(full_line, line_end);
        const line = full_line[0..line_end];
        const status_list = try layout.layoutParagraph(128, 512, 1, Cache, &self.cache, family, status_style, if (line.len == 0) " " else line, "", &.{}, &self.scratch, &self.status_placed);
        for (status_list) |g| {
            if (g.cell_y_px > status_style.margin_y_px) break;
            const glyph = try self.cache.getOrRender(family, @intCast(g.style_id), @intCast(g.base_cp), @intCast(g.ivs_cp), g.px_size, false, &self.scratch);
            const mask = adapter.surface.Mask{ .bytes = glyph.alpha, .width = glyph.metrics.width, .height = glyph.metrics.height, .stride = glyph.metrics.width };
            const y = g.bitmap_y_px + 720 - @as(i32, status_height);
            _ = if (config.appearance.linear_blend) target.blitLinear(mask, g.bitmap_x_px, y, theme.minibuf_fg_rgb565) else target.blit(mask, g.bitmap_x_px, y, theme.minibuf_fg_rgb565);
        }
        self.frames +%= 1;
    }
};

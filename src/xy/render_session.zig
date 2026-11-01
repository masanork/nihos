//! Shared TrueType viewport session. Caller owns memory and font readers.
const std = @import("std");
const layout = @import("viewport_layout");
const adapter = @import("render_adapter.zig");
const rotated = @import("rotated_surface");
pub const protocol = @import("render_protocol.zig");
const document = @import("document.zig");
pub const Cache = layout.ttf.TwoTierCache(24, 1024, 48, 128 * 128);
pub const Session = SizedSession(256);

pub fn SizedSession(comptime page_capacity: usize) type {
    return struct {
        cache: Cache,
        faces: [3]layout.ttf.Face,
        book_face: layout.ttf.Face,
        scratch: [32768]u8,
        placed: [page_capacity]layout.PlacedGlyph,
        status_placed: [128]layout.PlacedGlyph,
        // Hosts can supply paged complete fonts; embedded targets use ROM faces.
        external_mincho: ?layout.ttf.Family,
        external_gothic: ?layout.ttf.Family,
        owned_font_slices: [2][]const u8,
        frames: u32,
        glyphs: u32,
        placed_count: u32,

        pub fn init(self: *@This(), mincho: layout.ttf.SliceReader, gothic: layout.ttf.SliceReader) !void {
            // Cache payload is inaccessible until a slot's valid bit is set.
            @memset(std.mem.asBytes(self), 0);
            self.faces[0] = try layout.code_font.face();
            self.book_face = try layout.book_font.face();
            self.faces[1] = try layout.ttf.Face.init(mincho);
            self.faces[2] = try layout.ttf.Face.init(gothic);
        }
        /// SliceReader stores a pointer to a slice descriptor, not its payload.
        /// Keep those descriptors in this stable owner, never on a caller stack.
        pub fn initSlices(self: *@This(), mincho: []const u8, gothic: []const u8) !void {
            @memset(std.mem.asBytes(self), 0);
            self.owned_font_slices = .{ mincho, gothic };
            self.faces[0] = try layout.code_font.face();
            self.book_face = try layout.book_font.face();
            self.faces[1] = try layout.ttf.Face.init(layout.ttf.SliceReader.fromSlice(&self.owned_font_slices[0]));
            self.faces[2] = try layout.ttf.Face.init(layout.ttf.SliceReader.fromSlice(&self.owned_font_slices[1]));
        }
        pub fn render(self: *@This(), request: *const protocol.Request) !void {
            const physical = adapter.surface.Surface.init(request.frame[0..request.frame_length], 720, 1280, 1440) orelse return error.Geometry;
            const target = rotated.Rotated.init(physical);
            try self.renderInto(request, target);
        }
        pub fn renderLogical(self: *@This(), request: *const protocol.Request, width: u32, height: u32, stride: u32) !void {
            const target = adapter.surface.Surface.init(request.frame[0..request.frame_length], width, height, stride) orelse return error.Geometry;
            try self.renderInto(request, target);
        }
        /// Bounded UI text has no editor caret window or status row. Share the
        /// font family/cache/shaper/compositor while retaining every label glyph.
        pub fn renderLabel(self: *@This(), request: *const protocol.Request, width: u32, height: u32, stride: u32, centered: bool) !void {
            if (request.text_length > 128) return error.Capacity;
            const target = adapter.surface.Surface.init(request.frame[0..request.frame_length], width, height, stride) orelse return error.Geometry;
            var style = request.config.style;
            style.viewport_width_px = @intCast(width);
            style.viewport_height_px = @intCast(height);
            style.ruby_px = 0;
            style.ruby_gap_px = 0;
            style.margin_x_px = 0;
            const faces = [_]layout.ttf.Face{ self.faces[0], self.faces[@as(usize, style.style_id) + 1] };
            const family = layout.ttf.Family{ .faces = &faces };
            const list = try layout.layoutParagraph(page_capacity, 4096, 1024, Cache, &self.cache, family, style, request.text[0..request.text_length], "", &.{}, &self.scratch, &self.placed);
            if (centered) {
                var right: i32 = 0;
                for (list) |g| right = @max(right, g.cell_x_px + @as(i32, g.advance_px));
                const dx = @divTrunc(@as(i32, @intCast(width)) - right, 2);
                if (dx > 0) for (list) |*g| {
                    g.cell_x_px += dx;
                    g.bitmap_x_px += dx;
                };
            }
            const stats = try adapter.paintSurfaceRgb565(Cache, target, &self.cache, family, style, adapter.ThemePalette.fromAppearance(request.config.appearance), list, null, request.config.appearance.linear_blend, &self.scratch);
            self.glyphs = @intCast(stats.glyphs_blitted);
            self.frames +%= 1;
        }
        fn renderInto(self: *@This(), request: *const protocol.Request, target: anytype) !void {
            const screen_width: u16 = @intCast(target.width);
            if (request.reserved_bottom_px >= target.height) return error.Geometry;
            const screen_height: u16 = @intCast(target.height - request.reserved_bottom_px);
            const config = request.config.*;
            var style = config.style;
            style.viewport_width_px = screen_width;
            const status_height = @as(u16, style.body_px) + 2 * @as(u16, config.appearance.status_padding);
            if (status_height >= screen_height) return error.Geometry;
            style.viewport_height_px = screen_height - status_height;
            if (@as(u32, style.margin_x_px) * 2 + style.body_px >= screen_width or
                @as(u32, style.margin_y_px) * 2 + style.body_px >= style.viewport_height_px) return error.ViewportTooSmall;
            const family_faces = [_]layout.ttf.Face{ self.faces[0], self.faces[@as(usize, style.style_id) + 1] };
            var family = (if (style.style_id == 0) self.external_mincho else self.external_gothic) orelse layout.ttf.Family{ .faces = &family_faces };
            const book_faces = [_]layout.ttf.Face{ self.book_face, family_faces[1] };
            if (request.book_prose != 0) {
                family = .{ .faces = &book_faces, .code_faces = family.faces };
                style.style_id = 2 + style.style_id * 2;
                style.ruby_px = 0;
                style.line_gap_px = @min(style.line_gap_px, @max(2, style.body_px / 5));
            }
            if (request.code_count > 64) return error.Capacity;
            const code_spans = if (request.code_spans) |p| p[0..request.code_count] else if (request.code_count == 0) &.{} else return error.Range;
            const text = request.text[0..request.text_length];
            if (text.len > 4096) return error.Capacity;
            if (!std.unicode.utf8ValidateSlice(text) or request.cursor > text.len or !document.isClusterBoundary(text, request.cursor)) return error.InvalidUtf8;
            if (request.ruby_text_length > (if (request.page_mode != 0) @as(usize, 2048) else 1024) or request.ruby_count > (if (request.page_mode != 0) @as(usize, 128) else 64)) return error.Capacity;
            const readings = request.ruby_text[0..request.ruby_text_length];
            const spans = if (request.ruby_spans) |ptr| ptr[0..request.ruby_count] else if (request.ruby_count == 0) &.{} else return error.Range;
            for (spans) |span| {
                if (span.base_start >= span.base_end or span.base_end > text.len or span.ruby_start >= span.ruby_end or span.ruby_end > readings.len) return error.Range;
                if (!document.isClusterBoundary(text, span.base_start) or !document.isClusterBoundary(text, span.base_end)) return error.InvalidUtf8;
            }
            var visible_readings: [1024]u8 = undefined;
            var annotations: [128]layout.ruby.Annotation = undefined;
            // Size the bounded window to the current typography, then halve it if
            // paragraph breaks consume more lines than the conservative cell budget.
            const inline_px: usize = if (style.axis == 0) @as(usize, screen_width) - 2 * @as(usize, style.margin_x_px) else @as(usize, style.viewport_height_px) - 2 * @as(usize, style.margin_y_px);
            const cross_px: usize = if (style.axis == 0) @as(usize, style.viewport_height_px) - 2 * @as(usize, style.margin_y_px) else @as(usize, screen_width) - 2 * @as(usize, style.margin_x_px);
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
            if (request.page_mode != 0) {
                for (spans, 0..) |span, i| annotations[i] = .{
                    .base = .{ .start = span.base_start, .end = span.base_end },
                    .ruby = .{ .start = span.ruby_start, .end = span.ruby_end },
                };
                if (text.len > 0) list = try layout.layoutStyledParagraph(page_capacity, 4096, 2048, Cache, &self.cache, family, style, text, readings, annotations[0..spans.len], &self.scratch, &self.placed, true, code_spans);
            } else while (true) {
                const used_before: usize = @min(before, total);
                var start: usize = boundaries[(total - used_before) % boundaries.len];
                var end = request.cursor;
                var used_after: usize = 0;
                while (end != text.len and used_after < after + before - used_before) : (used_after += 1) end = try document.nextClusterEnd(text, end);
                const remaining = before + after - used_before - used_after;
                const take_before: usize = @min(total, used_before + remaining);
                start = boundaries[(total - take_before) % boundaries.len];
                cursor = @intCast(request.cursor - start);
                if (start == end) {
                    if (text.len != 0) return error.Capacity;
                    break;
                }
                // Keep a group reading with its complete base when a viewport edge
                // crosses an annotation. Closure also handles overlapping groups;
                // the layout layer still validates their semantic compatibility.
                var extended = true;
                while (extended) {
                    extended = false;
                    for (spans) |span| {
                        if (span.base_start < end and span.base_end > start) {
                            const next_start = @min(start, span.base_start);
                            const next_end = @max(end, span.base_end);
                            extended = extended or next_start != start or next_end != end;
                            start = next_start;
                            end = next_end;
                        }
                    }
                }
                cursor = @intCast(request.cursor - start);
                var reading_bytes: usize = 0;
                var annotation_count: usize = 0;
                for (spans) |span| {
                    if (span.base_start < start or span.base_end > end) continue;
                    const reading = readings[span.ruby_start..span.ruby_end];
                    if (reading.len > visible_readings.len - reading_bytes) return error.Capacity;
                    @memcpy(visible_readings[reading_bytes..][0..reading.len], reading);
                    annotations[annotation_count] = .{
                        .base = .{ .start = @intCast(span.base_start - start), .end = @intCast(span.base_end - start) },
                        .ruby = .{ .start = @intCast(reading_bytes), .end = @intCast(reading_bytes + reading.len) },
                    };
                    annotation_count += 1;
                    reading_bytes += reading.len;
                }
                list = layout.layoutParagraph(256, 4096, 1024, Cache, &self.cache, family, style, text[start..end], visible_readings[0..reading_bytes], annotations[0..annotation_count], &self.scratch, &self.placed) catch |err| switch (err) {
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
            self.placed_count = @intCast(list.len);
            const stats = try adapter.paintSurfaceRgb565(Cache, target, &self.cache, family, style, theme, list, if (request.show_cursor != 0) cursor else null, config.appearance.linear_blend, &self.scratch);
            self.glyphs = @intCast(stats.glyphs_blitted);
            _ = target.fillRect(0, screen_height - status_height, screen_width, status_height, theme.minibuf_bg_rgb565);
            // Use the same TrueType shaper for the command/result line.
            var status_style = style;
            status_style.axis = 0;
            status_style.ruby_px = 0;
            status_style.margin_x_px = config.appearance.status_padding;
            status_style.margin_y_px = config.appearance.status_padding;
            status_style.viewport_height_px = screen_height;
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
                const y = g.bitmap_y_px + @as(i32, screen_height) - @as(i32, status_height);
                _ = if (config.appearance.linear_blend) target.blitLinear(mask, g.bitmap_x_px, y, theme.minibuf_fg_rgb565) else target.blit(mask, g.bitmap_x_px, y, theme.minibuf_fg_rgb565);
            }
            self.frames +%= 1;
        }
    };
}

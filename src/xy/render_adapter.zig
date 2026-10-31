//! Dual-Target Rendering Adapter (`src/xy/render_adapter.zig`)
//!
//! Bridges the `xy` core Display List (`PlacedGlyph` + `TwoTierCache` 8bpp alpha masks)
//! to both execution targets:
//! - **Target A (`nihos` Tab5)**: Blits 8bpp anti-aliased glyph masks, ruby annotations,
//!   and horizontal/vertical cursor carets directly onto a borrowed RGB565LE
//!   `surface.Surface` (`1280x720` MIPI-DSI framebuffer or sub-surface).
//! - **Target B (macOS / PC `GPUI` Host)**: Packs C-ABI `GpuiGlyphQuad` and
//!   `GpuiFrameDescriptor` structs with direct pointers to the 8bpp alpha masks
//!   and minibuffer text for GPU texture-atlas rendering at 120fps.

const std = @import("std");
pub const surface = @import("surface");
pub const viewport_layout = @import("viewport_layout");
pub const scheme_bridge = @import("scheme_bridge.zig");

pub const ttf = viewport_layout.ttf;
pub const ViewStyle = viewport_layout.ViewStyle;
pub const PlacedGlyph = viewport_layout.PlacedGlyph;

/// Pack 8-bit R, G, B components into little-endian RGB565 (`u16`).
pub inline fn rgb565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

/// Color palette shared between Tab5 RGB565LE framebuffer and desktop GPUI RGBA8888.
pub const ThemePalette = extern struct {
    bg_rgb565: u16,
    body_rgb565: u16,
    ruby_rgb565: u16,
    cursor_rgb565: u16,
    minibuf_bg_rgb565: u16,
    minibuf_fg_rgb565: u16,
    bg_rgba8: u32,
    body_rgba8: u32,
    ruby_rgba8: u32,
    cursor_rgba8: u32,
    cursor_width: u8 = 2,
    status_padding: u8 = 4,

    pub fn fromAppearance(a: @import("view_config").Appearance) ThemePalette {
        return .{ .bg_rgb565 = color565(a.background), .body_rgb565 = color565(a.foreground), .ruby_rgb565 = color565(a.ruby_color), .cursor_rgb565 = color565(a.cursor_color), .minibuf_bg_rgb565 = color565(a.status_background), .minibuf_fg_rgb565 = color565(a.status_foreground), .bg_rgba8 = a.background << 8 | 255, .body_rgba8 = a.foreground << 8 | 255, .ruby_rgba8 = a.ruby_color << 8 | 255, .cursor_rgba8 = a.cursor_color << 8 | 255, .cursor_width = a.cursor_width, .status_padding = a.status_padding };
    }
    fn color565(rgb: u32) u16 {
        return rgb565(@truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb));
    }
    pub const washi_light = fromAppearance(.{});
    pub const hacker_dark = fromAppearance(.{ .background = 0x121418, .foreground = 0xe6eaf0, .ruby_color = 0x8ab4f8, .cursor_color = 0xffa657, .status_background = 0x1e222a, .status_foreground = 0xa8dab5 });
};

pub const CursorRect = extern struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
};

/// Compute the visual caret rectangle for `cursor_byte_offset` in either horizontal
/// (vertical 2px bar) or vertical `縦書き` (horizontal 2px bar) orientation.
pub fn computeCursorRect(
    view: ViewStyle,
    placed_list: []const PlacedGlyph,
    cursor_byte_offset: u32,
) CursorRect {
    const is_vertical = view.axis != 0;
    const body_px: u16 = view.body_px;

    // Default origin if buffer is empty
    var cx: i32 = if (is_vertical)
        @as(i32, view.viewport_width_px) - @as(i32, view.margin_x_px) - @as(i32, view.ruby_px) - @as(i32, body_px)
    else
        @as(i32, view.margin_x_px);
    var cy: i32 = @as(i32, view.margin_y_px) + if (is_vertical) @as(i32, 0) else @as(i32, view.ruby_px);

    for (placed_list) |g| {
        if (g.run != 0) continue; // Only track body run for cursor placement
        if (g.cluster_byte_offset == cursor_byte_offset) {
            cx = g.cell_x_px;
            cy = g.cell_y_px;
            break;
        }
        if (g.cluster_byte_offset < cursor_byte_offset) {
            const advance = if (g.base_cp == 0) @as(i32, 0) else if (g.advance_px != 0) @as(i32, g.advance_px) else @as(i32, g.px_size);
            if (is_vertical) {
                cx = g.cell_x_px;
                cy = g.cell_y_px + advance;
            } else {
                cx = g.cell_x_px + advance;
                cy = g.cell_y_px;
            }
        }
    }

    return if (is_vertical) .{
        .x_px = cx,
        .y_px = cy,
        .width_px = body_px,
        .height_px = 2,
    } else .{
        .x_px = cx,
        .y_px = cy,
        .width_px = 2,
        .height_px = body_px,
    };
}

// ============================================================================
// Target A: Tab5 MIPI-DSI RGB565LE Framebuffer Adapter (`surface.Surface`)
// ============================================================================

pub const PaintStats = struct {
    glyphs_blitted: usize = 0,
    cursor: CursorRect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
    minibuffer_top_y: i32 = 0,
};

/// Render the `PlacedGlyph` Display List, cursor caret, and bottom minibuffer bar
/// onto a borrowed RGB565LE `surface.Surface`.
pub fn paintSurfaceRgb565(
    comptime CacheType: type,
    target: anytype,
    cache: *CacheType,
    family: ttf.Family,
    view: ViewStyle,
    theme: ThemePalette,
    placed_list: []const PlacedGlyph,
    cursor_byte_offset: ?u32,
    linear_blend: bool,
    glyf_scratch: []u8,
) ttf.Error!PaintStats {
    const minibuf_height: u32 = @as(u32, view.body_px) + 2 * @as(u32, theme.status_padding);
    const total_h: u32 = @intCast(target.height);
    const total_w: u32 = @intCast(target.width);
    const minibuf_y: i32 = if (total_h > minibuf_height)
        @intCast(total_h - minibuf_height)
    else
        0;

    // 1. Fill main viewport background and bottom minibuffer strip
    _ = target.fillRect(0, 0, total_w, @intCast(minibuf_y), theme.bg_rgb565);
    if (minibuf_y > 0) {
        _ = target.fillRect(0, minibuf_y, total_w, minibuf_height, theme.minibuf_bg_rgb565);
    }

    // 2. Blit each PlacedGlyph's 8bpp alpha mask from TwoTierCache
    var blitted: usize = 0;
    for (placed_list) |g| {
        if (g.base_cp == 0) continue;
        const cached = try cache.getOrRender(
            family,
            @intCast(g.style_id & 0x0F),
            @intCast(g.base_cp),
            @intCast(g.ivs_cp),
            g.px_size,
            g.vertical != 0,
            glyf_scratch,
        );
        if (cached.metrics.width == 0 or cached.metrics.height == 0) continue;

        const mask = surface.Mask{
            .bytes = cached.alpha,
            .width = cached.metrics.width,
            .height = cached.metrics.height,
            .stride = cached.metrics.width,
        };
        const color = if (g.run == 0) theme.body_rgb565 else theme.ruby_rgb565;
        const ok = if (linear_blend)
            target.blitLinear(mask, g.bitmap_x_px, g.bitmap_y_px, color)
        else
            target.blit(mask, g.bitmap_x_px, g.bitmap_y_px, color);
        if (ok) blitted += 1;
    }

    // 3. Draw cursor caret (vertical bar in horizontal mode, horizontal bar in vertical mode)
    var caret = if (cursor_byte_offset) |offset| computeCursorRect(view, placed_list, offset) else CursorRect{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 };
    if (cursor_byte_offset != null) {
        if (view.axis == 0) caret.width_px = theme.cursor_width else caret.height_px = theme.cursor_width;
    }
    _ = target.fillRect(caret.x_px, caret.y_px, caret.width_px, caret.height_px, theme.cursor_rgb565);

    return .{
        .glyphs_blitted = blitted,
        .cursor = caret,
        .minibuffer_top_y = minibuf_y,
    };
}

// ============================================================================
// Target B: macOS / PC GPUI C-ABI Display List & Texture Atlas Adapter
// ============================================================================

/// C-ABI glyph quad descriptor pairing a `PlacedGlyph` with its 8bpp alpha mask pointer.
pub const GpuiGlyphQuad = extern struct {
    glyph: PlacedGlyph,
    alpha_ptr: [*]const u8,
    alpha_len: u32,
    rgba8_color: u32,
};

/// C-ABI frame snapshot consumed by the Rust GPUI custom element on macOS/PC.
pub const GpuiFrameDescriptor = extern struct {
    viewport_width_px: u16,
    viewport_height_px: u16,
    axis: u8,
    style_id: u8,
    body_px: u8,
    ruby_px: u8,
    bg_rgba8: u32,
    cursor: CursorRect,
    cursor_rgba8: u32,
    quad_count: u32,
    minibuffer_ptr: [*]const u8,
    minibuffer_len: u16,
};

/// Build a complete C-ABI `GpuiFrameDescriptor` and populate `out_quads` with zero-copy
/// pointers into `cache`'s 8bpp alpha bitmaps.
pub fn buildGpuiFrame(
    comptime CacheType: type,
    cache: *CacheType,
    family: ttf.Family,
    view: ViewStyle,
    theme: ThemePalette,
    placed_list: []const PlacedGlyph,
    cursor_byte_offset: u32,
    minibuffer_line: []const u8,
    glyf_scratch: []u8,
    out_quads: []GpuiGlyphQuad,
) ttf.Error!GpuiFrameDescriptor {
    var q_count: usize = 0;
    for (placed_list) |g| {
        if (g.base_cp == 0) continue;
        if (q_count >= out_quads.len) break;
        const cached = try cache.getOrRender(
            family,
            @intCast(g.style_id & 0x0F),
            @intCast(g.base_cp),
            @intCast(g.ivs_cp),
            g.px_size,
            g.vertical != 0,
            glyf_scratch,
        );
        out_quads[q_count] = .{
            .glyph = g,
            .alpha_ptr = cached.alpha.ptr,
            .alpha_len = @intCast(cached.alpha.len),
            .rgba8_color = if (g.run == 0) theme.body_rgba8 else theme.ruby_rgba8,
        };
        q_count += 1;
    }

    var caret = computeCursorRect(view, placed_list, cursor_byte_offset);
    if (view.axis == 0) caret.width_px = theme.cursor_width else caret.height_px = theme.cursor_width;
    return .{
        .viewport_width_px = view.viewport_width_px,
        .viewport_height_px = view.viewport_height_px,
        .axis = view.axis,
        .style_id = view.style_id,
        .body_px = view.body_px,
        .ruby_px = view.ruby_px,
        .bg_rgba8 = theme.bg_rgba8,
        .cursor = caret,
        .cursor_rgba8 = theme.cursor_rgba8,
        .quad_count = @intCast(q_count),
        .minibuffer_ptr = minibuffer_line.ptr,
        .minibuffer_len = @intCast(minibuffer_line.len),
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Target A (RGB565 Surface) and Target B (GPUI C-ABI) render live horizontal/vertical frames" {
    const WsType = scheme_bridge.XyWorkspace(2048, 32, 512, 16, 256);
    var ws: WsType = .{};
    ws.style.viewport_width_px = 240;
    ws.style.viewport_height_px = 160;

    var font_buf: [512]u8 = undefined;
    const bytes = viewport_layout.ttf_test_helper(&font_buf);
    const face = try ttf.Face.init(ttf.SliceReader.fromSlice(&bytes));
    const family = ttf.Family{ .faces = &[_]ttf.Face{face} };

    const CacheType = ttf.TwoTierCache(16, 64, 32, 64 * 64);
    var cache: CacheType = .{};
    var scratch: [256]u8 = undefined;
    var dl: [32]PlacedGlyph = undefined;

    // 1. Insert "葛\u{E0100}か" + ruby "かつ" via Scheme S-expression
    _ = try ws.evalStr(
        "(begin (buffer/insert! \"葛\u{E0100}か\") (buffer/add-ruby! 0 7 \"かつ\"))",
    );

    const list_h = try ws.renderDisplayList(32, 64, 64, CacheType, &cache, family, &scratch, &dl);
    try std.testing.expectEqual(@as(usize, 4), list_h.len);

    // 2. Target A: Blit onto an RGB565LE `surface.Surface` (240x160)
    var fb_bytes: [240 * 160 * 2]u8 = @splat(0);
    const surf = surface.Surface.init(&fb_bytes, 240, 160, 240 * 2).?;
    const stats_h = try paintSurfaceRgb565(
        CacheType,
        surf,
        &cache,
        family,
        ws.style,
        ThemePalette.washi_light,
        list_h,
        ws.doc.cursor,
        false,
        &scratch,
    );
    try std.testing.expectEqual(@as(usize, 4), stats_h.glyphs_blitted);
    // Horizontal mode cursor is a 2px-wide vertical bar
    try std.testing.expectEqual(@as(u16, 2), stats_h.cursor.width_px);
    try std.testing.expectEqual(@as(u16, 24), stats_h.cursor.height_px);

    // Verify that non-background ink pixels were actually written into the RGB565 framebuffer
    var ink_pixels: usize = 0;
    for (0..(240 * 120)) |px_idx| {
        const p = std.mem.readInt(u16, fb_bytes[px_idx * 2 ..][0..2], .little);
        if (p != ThemePalette.washi_light.bg_rgb565) ink_pixels += 1;
    }
    try std.testing.expect(ink_pixels > 0);

    // 3. Switch live to Vertical mode via Scheme `(view/set! #:direction 'vertical #:size 28)`
    _ = try ws.evalStr("(view/set! #:direction 'vertical #:size 28)");
    const list_v = try ws.renderDisplayList(32, 64, 64, CacheType, &cache, family, &scratch, &dl);

    // 4. Target B: Build GPUI C-ABI Frame Descriptor & Quads in vertical mode
    const mb_view = ws.ime.formatMinibuffer();
    var quads: [32]GpuiGlyphQuad = undefined;
    const gpui_frame = try buildGpuiFrame(
        CacheType,
        &cache,
        family,
        ws.style,
        ThemePalette.hacker_dark,
        list_v,
        ws.doc.cursor,
        mb_view.line(),
        &scratch,
        &quads,
    );
    try std.testing.expectEqual(@as(u8, 1), gpui_frame.axis);
    try std.testing.expectEqual(@as(u32, 4), gpui_frame.quad_count);
    // Vertical mode cursor is a 28px-wide, 2px-tall horizontal bar!
    try std.testing.expectEqual(@as(u16, 28), gpui_frame.cursor.width_px);
    try std.testing.expectEqual(@as(u16, 2), gpui_frame.cursor.height_px);
    try std.testing.expect(quads[0].alpha_len > 0);
}

test "caret follows shaped spaces and trailing paragraph breaks" {
    const glyphs = [_]PlacedGlyph{
        .{ .base_cp = ' ', .cluster_byte_offset = 0, .px_size = 24, .cell_x_px = 24, .cell_y_px = 36, .advance_px = 12 },
        .{ .cluster_byte_offset = 2, .px_size = 24, .cell_x_px = 24, .cell_y_px = 84 },
    };
    const space = computeCursorRect(.{}, glyphs[0..1], 1);
    try std.testing.expectEqual(@as(i32, 36), space.x_px);
    const newline = computeCursorRect(.{}, &glyphs, 2);
    try std.testing.expectEqual(@as(i32, 24), newline.x_px);
    try std.testing.expectEqual(@as(i32, 84), newline.y_px);
}

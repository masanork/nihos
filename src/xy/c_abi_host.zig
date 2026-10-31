//! Freestanding C-ABI Host Export (`src/xy/c_abi_host.zig`)
//!
//! Exports `libxy` over a stable C ABI (`callconv(.c)`) with zero OS/libc dependencies:
//! - Accepts paged font reader callbacks (`CSliceReader`) so the host can back each
//!   Bunsen `.ttf` layer (`[Base, Ext, PUP]`) with `pread(fd, ...)` on macOS/PC or
//!   SD card block reads on `nihos` (Tab5).
//! - Accepts an external `COmniQueryFn` callback so the host can wire `gjs.db` / `sqld`
//!   queries directly into `OmniIme` (`?` dict, `~` IVS/variants, `&` IDS, `@` FTS5).
//! - Exposes both Target A (`xy_host_render_rgb565`) and Target B (`xy_host_render_gpui`
//!   + `xy_host_render_rgba8` quad compositor) alongside live Scheme evaluation (`xy_host_eval`).

pub const surface = @import("surface");
pub const viewport_layout = @import("viewport_layout");
pub const render_adapter = @import("render_adapter.zig");
pub const scheme_bridge = render_adapter.scheme_bridge;
pub const ime_omni = scheme_bridge.ime_omni;
pub const ttf = viewport_layout.ttf;

pub const PlacedGlyph = viewport_layout.PlacedGlyph;
pub const GpuiGlyphQuad = render_adapter.GpuiGlyphQuad;
pub const GpuiFrameDescriptor = render_adapter.GpuiFrameDescriptor;
pub const ThemePalette = render_adapter.ThemePalette;

/// C-ABI callback for offset-based `.ttf` slice reading (e.g. `pread` on host, SD read on Tab5).
/// Returns the number of bytes read into `out_buf[0..len]` (`0` on error/EOF).
pub const CSliceReaderFn = *const fn (
    ctx: ?*const anyopaque,
    offset: u32,
    out_buf: [*]u8,
    len: u32,
) callconv(.c) u32;

pub const CSliceReaderDesc = extern struct {
    ctx: ?*const anyopaque,
    read_fn: CSliceReaderFn,
};

/// C-ABI callback invoked by `OmniIme` when querying external dictionaries (`gjs.db`, `skk_dict`, etc.).
/// The callback calls `xy_host_add_candidate(insert_ptr, insert_len, ann_ptr, ann_len)` to populate results.
pub const COmniQueryFn = *const fn (
    ctx: ?*anyopaque,
    kind: u8,
    prefix_char: u8,
    query_ptr: [*]const u8,
    query_len: u32,
) callconv(.c) void;

const ReaderAdapter = struct {
    desc: CSliceReaderDesc,

    fn readBridge(ctx_raw: *const anyopaque, offset: u32, buf: []u8) ttf.Error![]const u8 {
        const self: *const ReaderAdapter = @ptrCast(@alignCast(ctx_raw));
        if (buf.len == 0) return buf[0..0];
        const n = self.desc.read_fn(self.desc.ctx, offset, buf.ptr, @intCast(buf.len));
        if (n < buf.len) return error.OutOfBounds;
        return buf[0..n];
    }

    fn toSliceReader(self: *const ReaderAdapter) ttf.SliceReader {
        return .{
            .context = self,
            .readFn = readBridge,
        };
    }
};

// Bounded static instance for the C-ABI host session:
// - 256 outline cache slots × 1024 CurvePoints
// - 256 bitmap cache slots × (96 × 96) 8bpp pixels
// - 16 KiB UTF-8 document buffer
const HostCacheType = ttf.TwoTierCache(256, 1024, 256, 96 * 96);
pub const live_workspace = @import("live_workspace.zig");
const HostWorkspaceType = scheme_bridge.XyWorkspace(16384, 64, 4096, 64, 1024);

var g_mincho_adapters: [4]ReaderAdapter = undefined;
var g_mincho_faces: [4]ttf.Face = undefined;
var g_mincho_count: usize = 0;

var g_gothic_adapters: [4]ReaderAdapter = undefined;
var g_gothic_faces: [4]ttf.Face = undefined;
var g_gothic_count: usize = 0;

var g_cache: HostCacheType = .{};
var g_ws: HostWorkspaceType = .{};
// SAFETY: every live API is guarded by g_live_ready; init writes runtime state.
var g_live: live_workspace.Session(HostWorkspaceType) = undefined;
var g_live_ready = false;
var g_live_error: []const u8 = "";
var g_render_error: []const u8 = "";
var g_saved_doc: HostWorkspaceType.DocType = .{};
var g_editing_source = false;
var g_glyf_scratch: [16384]u8 = undefined;
var g_placed_buf: [512]PlacedGlyph = undefined;
var g_quads_buf: [512]GpuiGlyphQuad = undefined;
// SAFETY: render_gpui assigns the complete minibuffer view before taking line().
var g_mb_view: ime_omni.MinibufferView = undefined;

var g_c_omni_ctx: ?*anyopaque = null;
var g_c_omni_fn: ?COmniQueryFn = null;
var g_active_cand_list: ?*ime_omni.CandidateList = null;

fn bridgeOmniQuery(
    ctx: *anyopaque,
    kind: ime_omni.PrefixKind,
    prefix_char: u8,
    query_key: []const u8,
    out: *ime_omni.CandidateList,
) void {
    _ = ctx;
    if (g_c_omni_fn) |cb| {
        g_active_cand_list = out;
        defer g_active_cand_list = null;
        cb(g_c_omni_ctx, @backingInt(kind), prefix_char, query_key.ptr, @intCast(query_key.len));
    }
}

fn activeFamily() ttf.Family {
    if (g_ws.style.style_id == 1 and g_gothic_count > 0) {
        return .{ .faces = g_gothic_faces[0..g_gothic_count] };
    }
    return .{ .faces = g_mincho_faces[0..g_mincho_count] };
}

pub export fn xy_host_init(
    mincho_descs: [*]const CSliceReaderDesc,
    mincho_count: u32,
    gothic_descs: ?[*]const CSliceReaderDesc,
    gothic_count: u32,
) callconv(.c) bool {
    if (mincho_count == 0 or mincho_count > 4 or gothic_count > 4) return false;
    if (!xy_host_live_init()) return false;
    g_cache = .{};
    g_mincho_count = 0;
    g_gothic_count = 0;

    for (0..mincho_count) |i| {
        g_mincho_adapters[i] = .{ .desc = mincho_descs[i] };
        g_mincho_faces[i] = ttf.Face.init(g_mincho_adapters[i].toSliceReader()) catch return false;
        g_mincho_count += 1;
    }

    if (gothic_descs) |g_ptr| {
        for (0..gothic_count) |i| {
            g_gothic_adapters[i] = .{ .desc = g_ptr[i] };
            g_gothic_faces[i] = ttf.Face.init(g_gothic_adapters[i].toSliceReader()) catch return false;
            g_gothic_count += 1;
        }
    }

    var dummy: u8 = 0;
    g_ws.ext_omni_provider = .{
        .ctx = &dummy,
        .queryFn = bridgeOmniQuery,
        .learnFn = null,
    };
    return true;
}

pub export fn xy_host_set_omni_callback(ctx: ?*anyopaque, cb: ?COmniQueryFn) callconv(.c) void {
    g_c_omni_ctx = ctx;
    g_c_omni_fn = cb;
}

pub export fn xy_host_add_candidate(
    insert_ptr: [*]const u8,
    insert_len: u32,
    ann_ptr: [*]const u8,
    ann_len: u32,
) callconv(.c) bool {
    if (g_active_cand_list) |list| {
        return list.append(insert_ptr[0..insert_len], ann_ptr[0..ann_len]);
    }
    return false;
}

pub export fn xy_host_set_viewport(width_px: u16, height_px: u16) callconv(.c) void {
    g_ws.style.viewport_width_px = width_px;
    g_ws.style.viewport_height_px = height_px;
    g_ws.layout_dirty = true;
}

pub export fn xy_host_eval(
    sexp_ptr: [*]const u8,
    sexp_len: u32,
    out_buf: [*]u8,
    out_cap: u32,
) callconv(.c) i32 {
    const val = g_ws.evalStr(sexp_ptr[0..sexp_len]) catch return -1;
    const formatted = g_ws.arena.formatValue(val, out_buf[0..out_cap]);
    return @intCast(formatted.len);
}

/// Initialize an editor session without requiring fonts (also used by the CLI).
pub export fn xy_host_live_init() callconv(.c) bool {
    g_ws = .{};
    g_live.init();
    g_live_ready = true;
    g_editing_source = false;
    var out: [256]u8 = undefined;
    _ = g_live.prepare(live_workspace.default_source, &out) catch return false;
    g_live_error = "";
    return g_live.activate();
}
pub export fn xy_host_default_source(out: [*]u8, cap: u32) callconv(.c) i32 {
    if (cap < live_workspace.default_source.len) return -1;
    @memcpy(out[0..live_workspace.default_source.len], live_workspace.default_source);
    return @intCast(live_workspace.default_source.len);
}
pub export fn xy_host_render_error(out: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(cap, g_render_error.len);
    @memcpy(out[0..n], g_render_error[0..n]);
    return @intCast(n);
}
pub export fn xy_host_live_error(out: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(cap, g_live_error.len);
    @memcpy(out[0..n], g_live_error[0..n]);
    return @intCast(n);
}
pub export fn xy_host_live_prepare(source: [*]const u8, len: u32) callconv(.c) bool {
    if (!g_live_ready) return false;
    var out: [256]u8 = undefined;
    _ = g_live.prepare(source[0..len], &out) catch |err| {
        g_live_error = live_workspace.scheme.message(err);
        return false;
    };
    g_live_error = "";
    return true;
}
pub export fn xy_host_live_activate() callconv(.c) bool {
    return g_live_ready and g_live.activate();
}
pub export fn xy_host_live_discard() callconv(.c) void {
    if (g_live_ready) g_live.discard();
}
pub export fn xy_host_live_run(source: [*]const u8, len: u32, named: bool, out: [*]u8, cap: u32) callconv(.c) i32 {
    if (!g_live_ready) return -1;
    const result = g_live.run(&g_ws, source[0..len], named, out[0..cap]) catch |err| {
        g_live_error = live_workspace.scheme.message(err);
        return -1;
    };
    g_live_error = "";
    return @intCast(result.len);
}
pub export fn xy_host_buffer_copy(out: [*]u8, cap: u32) callconv(.c) i32 {
    const text = g_ws.doc.slice();
    if (cap < text.len) return -1;
    @memcpy(out[0..text.len], text);
    return @intCast(text.len);
}
pub export fn xy_host_insert_text(text: [*]const u8, len: u32) callconv(.c) bool {
    g_ws.doc.insertUtf8(text[0..len]) catch return false;
    g_ws.layout_dirty = true;
    return true;
}
pub export fn xy_host_buffer_replace(text: [*]const u8, len: u32) callconv(.c) bool {
    _ = g_ws.doc.replaceRange(.{ .revision = g_ws.doc.revision, .start = 0, .end = g_ws.doc.len }, text[0..len]) catch return false;
    g_ws.layout_dirty = true;
    return true;
}
pub export fn xy_host_source_enter(source: [*]const u8, len: u32) callconv(.c) bool {
    if (g_editing_source or len > 16384) return false;
    var doc: HostWorkspaceType.DocType = .{};
    doc.insertUtf8(source[0..len]) catch return false;
    doc.cursor = 0;
    doc.undo_count = 0;
    doc.undo_bytes_used = 0;
    g_saved_doc = g_ws.doc;
    g_ws.doc = doc;
    g_ws.layout_dirty = true;
    g_editing_source = true;
    return true;
}
pub export fn xy_host_source_leave() callconv(.c) void {
    if (!g_editing_source) return;
    g_ws.doc = g_saved_doc;
    g_ws.layout_dirty = true;
    g_editing_source = false;
}

pub export fn xy_host_handle_key(key: u8) callconv(.c) bool {
    g_ws.handleKey(key) catch return false;
    return true;
}

pub export fn xy_host_feed_utf8_reading(utf8_ptr: [*]const u8, utf8_len: u32) callconv(.c) bool {
    g_ws.ime.feedUtf8ToReading(&g_ws.doc, utf8_ptr[0..utf8_len]) catch return false;
    return true;
}

pub export fn xy_host_cache_stats(out_outline_misses: *u32, out_bitmap_misses: *u32) callconv(.c) void {
    out_outline_misses.* = g_cache.outline_misses;
    out_bitmap_misses.* = g_cache.bitmap_misses;
}

/// Target B (GPUI C-ABI): Build `GpuiFrameDescriptor` and copy up to `max_quads` `GpuiGlyphQuad`s.
fn effectiveAppearance(theme_id: u8) @import("view_config").Appearance {
    var appearance = g_ws.appearance;
    if (theme_id == 1 and g_ws.config_generation == 1) appearance = .{ .background = 0x121418, .foreground = 0xe6eaf0, .ruby_color = 0x8ab4f8, .cursor_color = 0xffa657, .status_background = 0x1e222a, .status_foreground = 0xa8dab5 };
    return appearance;
}

pub export fn xy_host_render_gpui(
    theme_id: u8,
    out_frame: *GpuiFrameDescriptor,
    out_quads: [*]GpuiGlyphQuad,
    max_quads: u32,
) callconv(.c) i32 {
    const fam = activeFamily();
    const placed = g_ws.renderDisplayList(
        256,
        4096,
        1024,
        HostCacheType,
        &g_cache,
        fam,
        &g_glyf_scratch,
        &g_placed_buf,
    ) catch |err| {
        g_render_error = @errorName(err);
        return -1;
    };

    g_mb_view = g_ws.ime.formatMinibuffer();
    const theme = ThemePalette.fromAppearance(effectiveAppearance(theme_id));
    const cap = @min(@as(usize, max_quads), g_quads_buf.len);
    const frame = render_adapter.buildGpuiFrame(
        HostCacheType,
        &g_cache,
        fam,
        g_ws.style,
        theme,
        placed,
        g_ws.doc.cursor,
        g_mb_view.line(),
        &g_glyf_scratch,
        out_quads[0..cap],
    ) catch |err| {
        g_render_error = @errorName(err);
        return -2;
    };
    g_render_error = "";
    out_frame.* = frame;
    const count: usize = @intCast(frame.quad_count);
    return @intCast(count);
}

/// Target A (Tab5 RGB565LE): Render directly into a borrowed RGB565LE framebuffer.
pub export fn xy_host_render_rgb565(
    fb_ptr: [*]u8,
    width: u32,
    height: u32,
    stride: u32,
    theme_id: u8,
) callconv(.c) i32 {
    const total_bytes = @as(usize, stride) * @as(usize, height);
    const surf = surface.Surface.init(fb_ptr[0..total_bytes], width, height, stride) orelse return -1;
    const fam = activeFamily();
    const placed = g_ws.renderDisplayList(
        256,
        4096,
        1024,
        HostCacheType,
        &g_cache,
        fam,
        &g_glyf_scratch,
        &g_placed_buf,
    ) catch return -2;

    const theme = ThemePalette.fromAppearance(effectiveAppearance(theme_id));
    const stats = render_adapter.paintSurfaceRgb565(
        HostCacheType,
        surf,
        &g_cache,
        fam,
        g_ws.style,
        theme,
        placed,
        g_ws.doc.cursor,
        g_ws.appearance.linear_blend,
        &g_glyf_scratch,
    ) catch return -3;
    return @intCast(stats.glyphs_blitted);
}

/// Composite the Target B (`GpuiFrameDescriptor` + `GpuiGlyphQuad`) output directly into
/// a 32-bit RGBA8888 buffer (`[R, G, B, A]` per pixel) for macOS CoreGraphics/Metal display.
pub export fn xy_host_render_rgba8(
    rgba_ptr: [*]u8,
    width: u32,
    height: u32,
    stride: u32,
    theme_id: u8,
) callconv(.c) i32 {
    // SAFETY: a nonnegative render_gpui result initializes the whole descriptor;
    // the error return above any read prevents use of an incomplete frame.
    var frame: GpuiFrameDescriptor = undefined;
    const q_count = xy_host_render_gpui(theme_id, &frame, &g_quads_buf, g_quads_buf.len);
    if (q_count < 0) return q_count;

    const bg_r: u8 = @truncate(frame.bg_rgba8 >> 24);
    const bg_g: u8 = @truncate(frame.bg_rgba8 >> 16);
    const bg_b: u8 = @truncate(frame.bg_rgba8 >> 8);

    // 1. Clear background
    for (0..height) |y| {
        const row = rgba_ptr[y * stride .. y * stride + width * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            row[x * 4 + 0] = bg_r;
            row[x * 4 + 1] = bg_g;
            row[x * 4 + 2] = bg_b;
            row[x * 4 + 3] = 255;
        }
    }

    // 2. Blend each GpuiGlyphQuad's 8bpp alpha texture
    const count: usize = @intCast(q_count);
    for (g_quads_buf[0..count]) |quad| blendRgbaGlyph(rgba_ptr, width, height, stride, quad.glyph, quad.alpha_ptr[0..quad.alpha_len], quad.rgba8_color, g_ws.appearance.linear_blend);

    // 3. Draw caret rectangle
    const cur_r: u8 = @truncate(frame.cursor_rgba8 >> 24);
    const cur_g: u8 = @truncate(frame.cursor_rgba8 >> 16);
    const cur_b: u8 = @truncate(frame.cursor_rgba8 >> 8);
    var cy: i32 = 0;
    while (cy < frame.cursor.height_px) : (cy += 1) {
        const dy = frame.cursor.y_px + cy;
        if (dy < 0 or dy >= @as(i32, @intCast(height))) continue;
        var cx: i32 = 0;
        while (cx < frame.cursor.width_px) : (cx += 1) {
            const dx = frame.cursor.x_px + cx;
            if (dx < 0 or dx >= @as(i32, @intCast(width))) continue;
            const off = @as(usize, @intCast(dy)) * stride + @as(usize, @intCast(dx)) * 4;
            rgba_ptr[off + 0] = cur_r;
            rgba_ptr[off + 1] = cur_g;
            rgba_ptr[off + 2] = cur_b;
            rgba_ptr[off + 3] = 255;
        }
    }

    // Status/minibuffer uses the same typeface, sizing and palette as the body.
    const a = effectiveAppearance(theme_id);
    const bar_height = @min(height, @as(u32, g_ws.style.body_px) + 2 * @as(u32, a.status_padding));
    const top = height - bar_height;
    for (top..height) |y| for (0..width) |x| {
        const off = y * stride + x * 4;
        rgba_ptr[off] = @truncate(a.status_background >> 16);
        rgba_ptr[off + 1] = @truncate(a.status_background >> 8);
        rgba_ptr[off + 2] = @truncate(a.status_background);
        rgba_ptr[off + 3] = 255;
    };
    var status_style = g_ws.style;
    status_style.axis = 0;
    status_style.ruby_px = 0;
    status_style.margin_x_px = a.status_padding;
    status_style.margin_y_px = a.status_padding;
    const status_line = if (g_mb_view.line().len == 0) "xy / *scratch*" else g_mb_view.line();
    const status_list = viewport_layout.layoutParagraph(256, 512, 1, HostCacheType, &g_cache, activeFamily(), status_style, status_line, "", &.{}, &g_glyf_scratch, &g_placed_buf) catch return -4;
    for (status_list) |item| {
        if (item.cell_y_px > status_style.margin_y_px) break;
        var g = item;
        g.bitmap_y_px += @intCast(top);
        const cached = g_cache.getOrRender(activeFamily(), @intCast(g.style_id), @intCast(g.base_cp), @intCast(g.ivs_cp), g.px_size, false, &g_glyf_scratch) catch return -4;
        blendRgbaGlyph(rgba_ptr, width, height, stride, g, cached.alpha, a.status_foreground << 8 | 255, a.linear_blend);
    }
    return q_count;
}

fn blendRgbaGlyph(rgba_ptr: [*]u8, width: u32, height: u32, stride: u32, glyph: PlacedGlyph, alpha: []const u8, color: u32, linear: bool) void {
    const gw: i32 = glyph.bitmap_width;
    const gh: i32 = glyph.bitmap_height;
    if (gw <= 0 or gh <= 0) return;

    const fg_r: u16 = @intCast((color >> 24) & 0xff);
    const fg_g: u16 = @intCast((color >> 16) & 0xff);
    const fg_b: u16 = @intCast((color >> 8) & 0xff);
    const alpha_slice = alpha;

    var sy: i32 = 0;
    while (sy < gh) : (sy += 1) {
        const dy = glyph.bitmap_y_px + sy;
        if (dy < 0 or dy >= @as(i32, @intCast(height))) continue;
        var sx: i32 = 0;
        while (sx < gw) : (sx += 1) {
            const dx = glyph.bitmap_x_px + sx;
            if (dx < 0 or dx >= @as(i32, @intCast(width))) continue;
            const a: u16 = alpha_slice[@as(usize, @intCast(sy)) * @as(usize, @intCast(gw)) + @as(usize, @intCast(sx))];
            if (a == 0) continue;
            const off = @as(usize, @intCast(dy)) * stride + @as(usize, @intCast(dx)) * 4;
            const inv: u16 = 255 - a;
            rgba_ptr[off + 0] = if (linear) surface.blendChannelLinear8(rgba_ptr[off + 0], @intCast(fg_r), @intCast(a)) else @intCast((fg_r * a + @as(u16, rgba_ptr[off + 0]) * inv) / 255);
            rgba_ptr[off + 1] = if (linear) surface.blendChannelLinear8(rgba_ptr[off + 1], @intCast(fg_g), @intCast(a)) else @intCast((fg_g * a + @as(u16, rgba_ptr[off + 1]) * inv) / 255);
            rgba_ptr[off + 2] = if (linear) surface.blendChannelLinear8(rgba_ptr[off + 2], @intCast(fg_b), @intCast(a)) else @intCast((fg_b * a + @as(u16, rgba_ptr[off + 2]) * inv) / 255);
            rgba_ptr[off + 3] = 255;
        }
    }
}

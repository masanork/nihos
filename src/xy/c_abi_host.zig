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
const native_session = @import("render_session.zig");
const view_config = @import("view_config");
const rom_mincho: []const u8 = @embedFile("fonts/mincho.ttf");
const rom_gothic: []const u8 = @embedFile("fonts/gothic.ttf");
// SAFETY: render APIs check readiness; init writes the whole owner-held cache.
var g_render_session: native_session.SizedSession(1024) = undefined;
var g_render_ready = false;
var g_host_status: [256]u8 = @splat(0);
var g_host_status_len: usize = 0;
pub const pixel_transfer = @import("pixel_transfer");

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
// - 4 KiB UTF-8 document buffer (same bound as canonical rendering)
const HostCacheType = ttf.TwoTierCache(256, 1024, 256, 96 * 96);
pub const live_workspace = @import("live_workspace.zig");
const HostWorkspaceType = scheme_bridge.XyWorkspace(4096, 64, 4096, 64, 1024);

var g_mincho_adapters: [4]ReaderAdapter = undefined;
var g_mincho_faces: [5]ttf.Face = undefined;
var g_mincho_count: usize = 0;

var g_gothic_adapters: [4]ReaderAdapter = undefined;
var g_gothic_faces: [5]ttf.Face = undefined;
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
const reader = @import("reader.zig");
var g_reading = false;
const learning = @import("learning_session.zig");
// SAFETY: xy_host_live_init initializes this owner before any learning API.
var g_learning: learning.Session = undefined;
var g_learning_visible = false;
var g_reader_saved_doc: HostWorkspaceType.DocType = .{};
var g_reader_saved_ime: ime_omni.OmniIme = .{};
var g_glyf_scratch: [16384]u8 = undefined;
var g_placed_buf: [512]PlacedGlyph = undefined;
var g_quads_buf: [512]GpuiGlyphQuad = undefined;
var g_rgb565_transfer: [1280 * 720 * 2]u8 = @splat(0);
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
    if (mincho_count > 4 or gothic_count > 4) return false;
    g_render_ready = false;
    if (!xy_host_live_init()) return false;
    g_cache = .{};
    g_mincho_count = 0;
    g_gothic_count = 0;

    // Use the same embedded mono face in both targets; Japanese falls back to
    // the paged Bunsen layers. No CoreText/AppKit glyphs enter this family.
    const code_face = viewport_layout.code_font.face() catch return false;
    g_mincho_faces[0] = code_face;
    g_mincho_count = 1;
    for (0..mincho_count) |i| {
        g_mincho_adapters[i] = .{ .desc = mincho_descs[i] };
        g_mincho_faces[i + 1] = ttf.Face.init(g_mincho_adapters[i].toSliceReader()) catch return false;
        g_mincho_count += 1;
    }

    if (gothic_descs) |g_ptr| {
        if (gothic_count > 0) {
            g_gothic_faces[0] = code_face;
            g_gothic_count = 1;
        }
        for (0..gothic_count) |i| {
            g_gothic_adapters[i] = .{ .desc = g_ptr[i] };
            g_gothic_faces[i + 1] = ttf.Face.init(g_gothic_adapters[i].toSliceReader()) catch return false;
            g_gothic_count += 1;
        }
    }

    g_render_session.init(ttf.SliceReader.fromSlice(&rom_mincho), ttf.SliceReader.fromSlice(&rom_gothic)) catch return false;
    g_render_ready = true;
    if (mincho_count > 0) g_render_session.external_mincho = .{ .faces = g_mincho_faces[0..g_mincho_count] };
    if (gothic_count > 0) g_render_session.external_gothic = .{ .faces = g_gothic_faces[0..g_gothic_count] };
    if (mincho_count == 0) {
        g_mincho_faces[1] = ttf.Face.init(ttf.SliceReader.fromSlice(&rom_mincho)) catch return false;
        g_mincho_count = 2;
    }
    if (gothic_count == 0) {
        g_gothic_faces[0] = code_face;
        g_gothic_faces[1] = ttf.Face.init(ttf.SliceReader.fromSlice(&rom_gothic)) catch return false;
        g_gothic_count = 2;
    }
    return true;
}

pub export fn xy_host_set_status(text: [*]const u8, length: u32) callconv(.c) bool {
    if (length > g_host_status.len or !@import("std").unicode.utf8ValidateSlice(text[0..length])) return false;
    @memcpy(g_host_status[0..length], text[0..length]);
    g_host_status_len = length;
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
    if (g_reading and !@import("std").mem.startsWith(u8, sexp_ptr[0..sexp_len], "(view/set! ")) return -1;
    const val = g_ws.evalStr(sexp_ptr[0..sexp_len]) catch return -1;
    const formatted = g_ws.arena.formatValue(val, out_buf[0..out_cap]);
    return @intCast(formatted.len);
}

/// Initialize an editor session without requiring fonts (also used by the CLI).
pub export fn xy_host_live_init() callconv(.c) bool {
    g_ws = .{};
    g_ws.ext_omni_provider = .{ .ctx = &g_ws, .queryFn = bridgeOmniQuery, .learnFn = null };
    g_live.init();
    g_live_ready = true;
    g_editing_source = false;
    g_reading = false;
    g_learning.initInPlace();
    g_learning_visible = false;
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
    if (!g_live_ready or g_reading) return -1;
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
    if (g_reading) return false;
    g_ws.doc.insertUtf8(text[0..len]) catch return false;
    g_ws.layout_dirty = true;
    return true;
}
pub export fn xy_host_buffer_replace(text: [*]const u8, len: u32) callconv(.c) bool {
    if (g_reading) return false;
    _ = g_ws.doc.replaceRange(.{ .revision = g_ws.doc.revision, .start = 0, .end = g_ws.doc.len }, text[0..len]) catch return false;
    g_ws.layout_dirty = true;
    return true;
}
pub export fn xy_host_source_enter(source: [*]const u8, len: u32) callconv(.c) bool {
    if (g_editing_source or g_reading or len > 4096) return false;
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
    if (g_reading) return false;
    g_ws.handleKey(key) catch return false;
    return true;
}

pub export fn xy_host_feed_utf8_reading(utf8_ptr: [*]const u8, utf8_len: u32) callconv(.c) bool {
    if (g_reading) return false;
    g_ws.ime.feedUtf8ToReading(&g_ws.doc, utf8_ptr[0..utf8_len]) catch return false;
    return true;
}

pub export fn xy_host_cache_stats(out_outline_misses: *u32, out_bitmap_misses: *u32) callconv(.c) void {
    out_outline_misses.* = g_cache.outline_misses;
    out_bitmap_misses.* = g_cache.bitmap_misses;
}

/// Atlas/placement inspection API. Pixel-exact hosts present render_rgba8 instead.
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
    if (!g_render_ready) return -1;
    const total_bytes = @as(usize, stride) * @as(usize, height);
    const config = view_config.Config{ .style = g_ws.style, .appearance = effectiveAppearance(theme_id) };
    g_mb_view = g_ws.ime.formatMinibuffer();
    const status = if (g_ws.ime.phase != .idle) g_mb_view.line() else if (g_host_status_len > 0) g_host_status[0..g_host_status_len] else g_mb_view.line();
    const request = native_session.protocol.Request{
        .workspace = &g_render_session,
        .frame = fb_ptr,
        .frame_length = total_bytes,
        .config = &config,
        .text = g_ws.doc.slice().ptr,
        .text_length = g_ws.doc.len,
        .cursor = g_ws.doc.cursor,
        .status = status.ptr,
        .status_length = status.len,
        .show_cursor = @intFromBool(!g_reading),
        .page_mode = @intFromBool(g_reading),
        .ruby_text = &g_ws.doc.ruby_arena,
        .ruby_text_length = g_ws.doc.ruby_bytes_used,
        .ruby_spans = &g_ws.doc.ruby_spans,
        .ruby_count = g_ws.doc.ruby_count,
    };
    const rendering = if (g_learning_visible and width == 1280 and height == 720 and stride == 2560)
        @import("learning_view.zig").render(&g_render_session, &request, &g_learning, false, true)
    else
        g_render_session.renderLogical(&request, width, height, stride);
    rendering catch |err| {
        g_render_error = @errorName(err);
        return -2;
    };
    g_render_error = "";
    return @intCast(g_render_session.glyphs);
}

/// Present the canonical Target A framebuffer as opaque RGBA. GPUI or another
/// host uploads these pixels without reshaping text or redoing alpha blending.
pub export fn xy_host_render_rgba8(
    rgba_ptr: [*]u8,
    width: u32,
    height: u32,
    stride: u32,
    theme_id: u8,
) callconv(.c) i32 {
    const pixel_count = @as(u64, width) * height;
    if (width == 0 or height == 0 or pixel_count > g_rgb565_transfer.len / 2 or @as(u64, stride) < @as(u64, width) * 4) {
        g_render_error = "InvalidFramebufferGeometry";
        return -4;
    }
    const native_stride = width * 2;
    const count = xy_host_render_rgb565(&g_rgb565_transfer, width, height, native_stride, theme_id);
    if (count < 0) return count;
    const length = @as(usize, stride) * height;
    pixel_transfer.rgba8(&g_rgb565_transfer, width, height, native_stride, rgba_ptr[0..length], stride) catch {
        g_render_error = "InvalidFramebufferGeometry";
        return -4;
    };
    return count;
}

/// Preserve the entire editable document, including its undo and ruby tables.
pub export fn xy_host_reader_enter() callconv(.c) bool {
    if (g_reading or g_editing_source or !g_render_ready) return false;
    g_reader_saved_doc = g_ws.doc;
    g_reader_saved_ime = g_ws.ime;
    g_ws.ime = .{};
    g_reading = true;
    return true;
}
pub export fn xy_host_reader_leave() callconv(.c) void {
    g_learning_visible = false;
    if (!g_reading) return;
    g_ws.doc = g_reader_saved_doc;
    g_ws.ime = g_reader_saved_ime;
    g_reading = false;
}
/// Candidate is bounded by the caller. Return exact consumed UTF-8 bytes.
/// Validate and fit before replacing the current page; failure leaves it intact.
pub export fn xy_host_reader_load(text: [*]const u8, len: u32, readings: [*]const u8, reading_len: u32, spans: [*]const reader.RubySpan, span_count: u32) callconv(.c) i32 {
    if (!g_reading or g_learning_visible or len == 0) return -1;
    const body = text[0..len];
    const ruby_text = readings[0..reading_len];
    const annotations = spans[0..span_count];
    reader.validate(body, ruby_text, annotations) catch return -2;
    var style = g_ws.style;
    const bar: u16 = @as(u16, style.body_px) + 2 * @as(u16, g_ws.appearance.status_padding);
    if (style.viewport_height_px <= bar) return -3;
    style.viewport_height_px -= bar;
    var config = view_config.Config{ .style = style, .appearance = g_ws.appearance };
    config.validate() catch return -3;
    var end: usize = len;
    var ann_buf: [64]viewport_layout.ruby.Annotation = undefined;
    while (end > 0) {
        var count: usize = 0;
        var r_end: usize = 0;
        for (annotations) |span| {
            if (span.base_end > end) break;
            ann_buf[count] = .{ .base = .{ .start = span.base_start, .end = span.base_end }, .ruby = .{ .start = span.ruby_start, .end = span.ruby_end } };
            count += 1;
            r_end = @max(r_end, span.ruby_end);
        }
        const list = viewport_layout.layoutParagraphWithWordWrap(1024, 4096, 1024, native_session.Cache, &g_render_session.cache, activeFamily(), style, body[0..end], ruby_text[0..r_end], ann_buf[0..count], &g_render_session.scratch, &g_render_session.placed, true) catch |err| switch (err) {
            error.BlockFull, error.Capacity, error.SpanTooWide => {
                end = reader.shorter(body, end, annotations) catch return -4;
                continue;
            },
            else => {
                g_render_error = @errorName(err);
                return -4;
            },
        };
        const fit = reader.visibleEnd(end, annotations, list, style);
        if (fit < end) {
            end = fit;
            continue;
        }
        var doc: HostWorkspaceType.DocType = .{};
        doc.insertUtf8(body[0..end]) catch return -5;
        for (annotations[0..count]) |span| {
            doc.addRuby(span.base_start, span.base_end, ruby_text[span.ruby_start..span.ruby_end]) catch return -5;
        }
        doc.cursor = 0;
        doc.forgetUndoHistory();
        g_ws.doc = doc;
        g_ws.layout_dirty = true;
        return @intCast(end);
    }
    return -6;
}

/// A host file load starts a fresh undo history and never consumes the old one.
pub export fn xy_host_document_load(text: [*]const u8, len: u32) callconv(.c) bool {
    if (g_reading or g_editing_source or len > 4096) return false;
    var doc: HostWorkspaceType.DocType = .{};
    doc.insertUtf8(text[0..len]) catch return false;
    doc.forgetUndoHistory();
    g_ws.doc = doc;
    // A file replacement starts a new composition, retaining user IME settings.
    g_ws.ime = .{ .mode = g_ws.ime.mode, .custom_prefixes = g_ws.ime.custom_prefixes };
    g_ws.layout_dirty = true;
    return true;
}

// Learning operations never swap or edit the reader/editor Document.
pub export fn xy_host_learning_bind(data: [*]const u8, len: u32, library: [*]const u8, library_len: u32) callconv(.c) bool {
    if (!g_live_ready) return false;
    const pack = learning.catalog.Pack.init(data[0..len]) catch return false;
    var digest: [32]u8 = undefined;
    @import("std").crypto.hash.sha2.Sha256.hash(library[0..library_len], &digest, .{});
    if (!pack.matchesLibrary(&digest)) return false;
    g_learning.bind(data[0..len]) catch return false;
    return true;
}
pub export fn xy_host_learning_page(section: u32, start: u32, end: u32) callconv(.c) i32 {
    if (!g_reading or g_learning_visible) return -1;
    g_learning.setPage(section, start, end) catch return -1;
    return @intCast(g_learning.count() catch return -1);
}
fn learningCopy(text: []const u8, out: [*]u8, cap: u32) i32 {
    if (text.len > cap) return -1;
    @memcpy(out[0..text.len], text);
    return @intCast(text.len);
}
pub export fn xy_host_learning_choice(ordinal: u32, out: [*]u8, cap: u32) callconv(.c) i32 {
    if (!g_live_ready) return -1;
    const choice = (g_learning.choice(ordinal) catch return -1) orelse return -1;
    return learningCopy(choice.code, out, cap);
}
pub export fn xy_host_learning_open(ordinal: u32) callconv(.c) bool {
    if (!g_reading or !g_render_ready or g_learning_visible) return false;
    g_learning.open(ordinal) catch return false;
    g_learning_visible = true;
    return true;
}
pub export fn xy_host_learning_leave() callconv(.c) void {
    g_learning_visible = false;
}
pub export fn xy_host_learning_insert(text: [*]const u8, len: u32, replace: bool) callconv(.c) bool {
    if (!g_learning_visible) return false;
    if (replace) g_learning.replace(text[0..len]) catch |err| {
        g_learning.notice(err);
        return false;
    } else g_learning.insert(text[0..len]) catch |err| {
        g_learning.notice(err);
        return false;
    };
    return true;
}
pub export fn xy_host_learning_key(key: u8) callconv(.c) void {
    if (!g_learning_visible) return;
    const event: learning.navigation.Key = switch (key) {
        13, 10 => .enter,
        8, 127 => .backspace,
        4 => .eof,
        12 => .clear,
        26 => .undo,
        128 => .up,
        129 => .down,
        130 => .left,
        131 => .right,
        else => .{ .text = key },
    };
    var nav = learning.navigation.State{ .screen = .exercise };
    g_learning.handle(&nav, event);
}
pub export fn xy_host_learning_action(action: u32) callconv(.c) i32 {
    if (!g_learning_visible) return -1;
    g_learning.message_len = 0;
    switch (action) {
        0 => g_learning.run() catch |err| {
            g_learning.notice(err);
            return -1;
        },
        1 => g_learning.resetVm(),
        2 => g_learning.restore() catch return -1,
        3 => g_learning.editing_notes = !g_learning.editing_notes,
        4 => {
            _ = g_learning.doc().?.undo() catch return -1;
        },
        else => return -1,
    }
    const s = g_learning.slot() orelse return -1;
    return if (action == 0 and s.failed) -1 else 0;
}
pub export fn xy_host_learning_copy(field: u32, out: [*]u8, cap: u32) callconv(.c) i32 {
    if (!g_live_ready) return -1;
    const s = g_learning.slot() orelse return -1;
    const snippet = g_learning.pack.snippet(s.snippet) catch return -1;
    const text = switch (field) {
        0 => s.code.slice(),
        1 => s.notes.slice(),
        2 => s.result[0..s.result_len],
        3 => snippet.id,
        4 => g_learning.message[0..g_learning.message_len],
        5 => snippet.reference_output,
        else => return -1,
    };
    return learningCopy(text, out, cap);
}

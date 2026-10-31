//! Allocation-free paged OpenType/TrueType (`cmap`/`loca`/`hmtx`/`glyf`) reader
//! and quadratic Bézier scanline rasterizer.
//! Designed for multi-layer CJK font families (e.g. Base -> Ext -> PUP) with
//! 2-pass IVS resolution, depth-1 composite glyphs, and em-space vertical
//! typesetting transforms.
const std = @import("std");

pub const Error = error{
    InvalidFont,
    MissingTable,
    OutOfBounds,
    BufferTooSmall,
    GlyphNotFound,
    TooManyContours,
    TooManyPoints,
    TooManyComponents,
    UnsupportedCompositeTransform,
    InvalidScale,
};

pub const TableSpan = struct {
    offset: u32 = 0,
    length: u32 = 0,
};

/// Offset-based byte reader abstraction so both in-memory slices (Flash/tests)
/// and paged file/SD readers share the exact same parser.
pub const SliceReader = struct {
    context: *const anyopaque,
    readFn: *const fn (ctx: *const anyopaque, offset: u32, out: []u8) Error![]const u8,

    pub fn read(self: SliceReader, offset: u32, out: []u8) Error![]const u8 {
        return self.readFn(self.context, offset, out);
    }

    pub fn fromSlice(slice: *const []const u8) SliceReader {
        const Impl = struct {
            fn readSlice(ctx: *const anyopaque, offset: u32, out: []u8) Error![]const u8 {
                const bytes: *const []const u8 = @ptrCast(@alignCast(ctx));
                const start: usize = @intCast(offset);
                if (start > bytes.len or out.len > bytes.len - start) return error.OutOfBounds;
                return bytes.*[start .. start + out.len];
            }
        };
        return .{ .context = @ptrCast(slice), .readFn = Impl.readSlice };
    }
};

inline fn readU16BE(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}

inline fn readI16BE(bytes: []const u8, at: usize) i16 {
    return std.mem.readInt(i16, bytes[at..][0..2], .big);
}

inline fn readU24BE(bytes: []const u8, at: usize) u24 {
    return (@as(u24, bytes[at]) << 16) | (@as(u24, bytes[at + 1]) << 8) | @as(u24, bytes[at + 2]);
}

inline fn readU32BE(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}

pub const GlyphSpan = struct {
    advance_em: u16,
    lsb_em: i16,
    glyf_offset: u32,
    glyf_length: u32,
};

pub const Face = struct {
    reader: SliceReader,
    units_per_em: u16,
    ascent: i16,
    descent: i16,
    num_glyphs: u16,
    num_h_metrics: u16,
    index_to_loc_format: u1,
    cmap_format4: TableSpan = .{},
    cmap_format12: TableSpan = .{},
    cmap_format14: TableSpan = .{},
    loca: TableSpan = .{},
    glyf: TableSpan = .{},
    hmtx: TableSpan = .{},

    pub fn init(reader: SliceReader) Error!Face {
        var hdr_buf: [12]u8 = undefined;
        const hdr = try reader.read(0, &hdr_buf);
        const sfnt = readU32BE(hdr, 0);
        if (sfnt != 0x00010000 and sfnt != 0x74727565) return error.InvalidFont;
        const num_tables = readU16BE(hdr, 4);
        if (num_tables == 0 or num_tables > 64) return error.InvalidFont;

        var head_span: TableSpan = .{};
        var hhea_span: TableSpan = .{};
        var maxp_span: TableSpan = .{};
        var cmap_span: TableSpan = .{};
        var loca_span: TableSpan = .{};
        var glyf_span: TableSpan = .{};
        var hmtx_span: TableSpan = .{};

        var rec_buf: [16]u8 = undefined;
        var i: u16 = 0;
        while (i < num_tables) : (i += 1) {
            const rec = try reader.read(12 + @as(u32, i) * 16, &rec_buf);
            const tag = rec[0..4];
            const span = TableSpan{ .offset = readU32BE(rec, 8), .length = readU32BE(rec, 12) };
            if (std.mem.eql(u8, tag, "head")) head_span = span else if (std.mem.eql(u8, tag, "hhea")) hhea_span = span else if (std.mem.eql(u8, tag, "maxp")) maxp_span = span else if (std.mem.eql(u8, tag, "cmap")) cmap_span = span else if (std.mem.eql(u8, tag, "loca")) loca_span = span else if (std.mem.eql(u8, tag, "glyf")) glyf_span = span else if (std.mem.eql(u8, tag, "hmtx")) hmtx_span = span;
        }

        if (head_span.length < 54 or hhea_span.length < 36 or maxp_span.length < 6 or
            cmap_span.length < 4 or loca_span.length == 0 or glyf_span.length == 0 or hmtx_span.length == 0)
            return error.MissingTable;

        var head_buf: [54]u8 = undefined;
        const head = try reader.read(head_span.offset, &head_buf);
        const units_per_em = readU16BE(head, 18);
        if (units_per_em < 16 or units_per_em > 16384) return error.InvalidFont;
        const loc_fmt_raw = readI16BE(head, 50);
        if (loc_fmt_raw != 0 and loc_fmt_raw != 1) return error.InvalidFont;

        var hhea_buf: [36]u8 = undefined;
        const hhea = try reader.read(hhea_span.offset, &hhea_buf);
        const ascent = readI16BE(hhea, 4);
        const descent = readI16BE(hhea, 6);
        const num_h_metrics = readU16BE(hhea, 34);
        if (num_h_metrics == 0) return error.InvalidFont;

        var maxp_buf: [6]u8 = undefined;
        const maxp = try reader.read(maxp_span.offset, &maxp_buf);
        const num_glyphs = readU16BE(maxp, 4);
        if (num_glyphs == 0) return error.InvalidFont;

        var face = Face{
            .reader = reader,
            .units_per_em = units_per_em,
            .ascent = ascent,
            .descent = descent,
            .num_glyphs = num_glyphs,
            .num_h_metrics = num_h_metrics,
            .index_to_loc_format = @intCast(loc_fmt_raw),
            .loca = loca_span,
            .glyf = glyf_span,
            .hmtx = hmtx_span,
        };

        // Parse cmap encoding records
        var cmap_hdr_buf: [4]u8 = undefined;
        const cmap_hdr = try reader.read(cmap_span.offset, &cmap_hdr_buf);
        const num_cmap_tables = readU16BE(cmap_hdr, 2);
        if (num_cmap_tables > 32) return error.InvalidFont;

        var sub_idx: u16 = 0;
        while (sub_idx < num_cmap_tables) : (sub_idx += 1) {
            var enc_buf: [8]u8 = undefined;
            const enc = try reader.read(cmap_span.offset + 4 + @as(u32, sub_idx) * 8, &enc_buf);
            const platform_id = readU16BE(enc, 0);
            const encoding_id = readU16BE(enc, 2);
            const sub_rel = readU32BE(enc, 4);
            if (sub_rel >= cmap_span.length) return error.InvalidFont;
            const sub_abs = cmap_span.offset + sub_rel;

            var fmt_buf: [12]u8 = undefined;
            const avail = @min(@as(u32, 12), cmap_span.length - sub_rel);
            if (avail < 4) continue;
            const fmt_slice = try reader.read(sub_abs, fmt_buf[0..avail]);
            const fmt = readU16BE(fmt_slice, 0);

            const is_unicode_or_win = (platform_id == 0) or (platform_id == 3 and (encoding_id == 1 or encoding_id == 10));
            if (fmt == 12 and is_unicode_or_win and avail >= 12) {
                const sub_len = readU32BE(fmt_slice, 4);
                face.cmap_format12 = .{ .offset = sub_abs, .length = sub_len };
            } else if (fmt == 14 and platform_id == 0 and encoding_id == 5 and avail >= 10) {
                const sub_len = readU32BE(fmt_slice, 2);
                face.cmap_format14 = .{ .offset = sub_abs, .length = sub_len };
            } else if (fmt == 4 and is_unicode_or_win and face.cmap_format4.length == 0) {
                const sub_len = readU16BE(fmt_slice, 2);
                face.cmap_format4 = .{ .offset = sub_abs, .length = sub_len };
            }
        }

        if (face.cmap_format12.length == 0 and face.cmap_format4.length == 0)
            return error.MissingTable;

        return face;
    }

    /// Look up base codepoint in Format 12 (or Format 4 fallback) using binary search.
    pub fn lookupBaseGlyph(self: *const Face, cp: u21) Error!?u16 {
        if (self.cmap_format12.length >= 16) {
            var hdr_buf: [16]u8 = undefined;
            const hdr = try self.reader.read(self.cmap_format12.offset, &hdr_buf);
            const num_groups = readU32BE(hdr, 12);
            var lo: u32 = 0;
            var hi: u32 = num_groups;
            var grp_buf: [12]u8 = undefined;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const grp = try self.reader.read(self.cmap_format12.offset + 16 + mid * 12, &grp_buf);
                const start_code = readU32BE(grp, 0);
                const end_code = readU32BE(grp, 4);
                const start_gid = readU32BE(grp, 8);
                if (cp < start_code) {
                    hi = mid;
                } else if (cp > end_code) {
                    lo = mid + 1;
                } else {
                    const gid = start_gid + (cp - start_code);
                    if (gid == 0 or gid >= self.num_glyphs) return null;
                    return @intCast(gid);
                }
            }
            return null;
        }
        if (self.cmap_format4.length >= 16 and cp <= 0xFFFF) {
            const code: u16 = @intCast(cp);
            var hdr_buf: [14]u8 = undefined;
            const hdr = try self.reader.read(self.cmap_format4.offset, &hdr_buf);
            const seg_count = readU16BE(hdr, 6) / 2;
            const end_codes_off = self.cmap_format4.offset + 14;
            const start_codes_off = end_codes_off + @as(u32, seg_count) * 2 + 2;
            const id_delta_off = start_codes_off + @as(u32, seg_count) * 2;
            const id_range_off = id_delta_off + @as(u32, seg_count) * 2;

            var lo: u16 = 0;
            var hi: u16 = seg_count;
            var word_buf: [2]u8 = undefined;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const end_code = readU16BE(try self.reader.read(end_codes_off + @as(u32, mid) * 2, &word_buf), 0);
                if (code > end_code) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo >= seg_count) return null;
            const start_code = readU16BE(try self.reader.read(start_codes_off + @as(u32, lo) * 2, &word_buf), 0);
            if (code < start_code or code == 0xFFFF) return null;
            const id_delta = readI16BE(try self.reader.read(id_delta_off + @as(u32, lo) * 2, &word_buf), 0);
            const range_offset = readU16BE(try self.reader.read(id_range_off + @as(u32, lo) * 2, &word_buf), 0);
            if (range_offset == 0) {
                const gid: u16 = @bitCast(@as(i16, @bitCast(code)) +% id_delta);
                return if (gid == 0 or gid >= self.num_glyphs) null else gid;
            } else {
                const glyph_idx_addr = id_range_off + @as(u32, lo) * 2 + range_offset + @as(u32, code - start_code) * 2;
                const raw_gid = readU16BE(try self.reader.read(glyph_idx_addr, &word_buf), 0);
                if (raw_gid == 0) return null;
                const gid: u16 = @bitCast(@as(i16, @bitCast(raw_gid)) +% id_delta);
                return if (gid == 0 or gid >= self.num_glyphs) null else gid;
            }
        }
        return null;
    }

    /// Look up (base_cp, ivs_cp) in Format 14 (Variation Selector Subtable).
    /// Handles both Non-Default UVS (explicit glyph ID) and Default UVS (delegates to base cmap).
    pub fn lookupIvsGlyph(self: *const Face, base_cp: u21, ivs_cp: u21) Error!?u16 {
        if (ivs_cp == 0 or self.cmap_format14.length < 10) return null;
        var hdr_buf: [10]u8 = undefined;
        const hdr = try self.reader.read(self.cmap_format14.offset, &hdr_buf);
        const num_records = readU32BE(hdr, 6);

        var lo: u32 = 0;
        var hi: u32 = num_records;
        var rec_buf: [11]u8 = undefined;
        var default_uvs_off: u32 = 0;
        var non_default_uvs_off: u32 = 0;
        var found = false;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = try self.reader.read(self.cmap_format14.offset + 10 + mid * 11, &rec_buf);
            const vs = readU24BE(rec, 0);
            if (ivs_cp < vs) {
                hi = mid;
            } else if (ivs_cp > vs) {
                lo = mid + 1;
            } else {
                default_uvs_off = readU32BE(rec, 3);
                non_default_uvs_off = readU32BE(rec, 7);
                found = true;
                break;
            }
        }
        if (!found) return null;

        // 1. Check Non-Default UVS table (binary search on 24-bit unicodeValue + 16-bit glyphID)
        if (non_default_uvs_off != 0) {
            const tbl_abs = self.cmap_format14.offset + non_default_uvs_off;
            var cnt_buf: [4]u8 = undefined;
            const num_mappings = readU32BE(try self.reader.read(tbl_abs, &cnt_buf), 0);
            var m_lo: u32 = 0;
            var m_hi: u32 = num_mappings;
            var map_buf: [5]u8 = undefined;
            while (m_lo < m_hi) {
                const mid = m_lo + (m_hi - m_lo) / 2;
                const entry = try self.reader.read(tbl_abs + 4 + mid * 5, &map_buf);
                const uval = readU24BE(entry, 0);
                if (base_cp < uval) {
                    m_hi = mid;
                } else if (base_cp > uval) {
                    m_lo = mid + 1;
                } else {
                    const gid = readU16BE(entry, 3);
                    return if (gid == 0 or gid >= self.num_glyphs) null else gid;
                }
            }
        }

        // 2. Check Default UVS table (ranges where the base glyph in this font IS the IVS glyph)
        if (default_uvs_off != 0) {
            const tbl_abs = self.cmap_format14.offset + default_uvs_off;
            var cnt_buf: [4]u8 = undefined;
            const num_ranges = readU32BE(try self.reader.read(tbl_abs, &cnt_buf), 0);
            var r_lo: u32 = 0;
            var r_hi: u32 = num_ranges;
            var rng_buf: [4]u8 = undefined;
            while (r_lo < r_hi) {
                const mid = r_lo + (r_hi - r_lo) / 2;
                const entry = try self.reader.read(tbl_abs + 4 + mid * 4, &rng_buf);
                const start_uval: u32 = readU24BE(entry, 0);
                const end_uval: u32 = start_uval + entry[3];
                if (base_cp < start_uval) {
                    r_hi = mid;
                } else if (base_cp > end_uval) {
                    r_lo = mid + 1;
                } else {
                    return self.lookupBaseGlyph(base_cp);
                }
            }
        }
        return null;
    }

    pub fn glyphSpan(self: *const Face, glyph_id: u16) Error!GlyphSpan {
        if (glyph_id >= self.num_glyphs) return error.GlyphNotFound;

        // Read horizontal metrics from hmtx
        var advance_em: u16 = 0;
        var lsb_em: i16 = 0;
        if (glyph_id < self.num_h_metrics) {
            var m_buf: [4]u8 = undefined;
            const m = try self.reader.read(self.hmtx.offset + @as(u32, glyph_id) * 4, &m_buf);
            advance_em = readU16BE(m, 0);
            lsb_em = readI16BE(m, 2);
        } else {
            var adv_buf: [2]u8 = undefined;
            const adv = try self.reader.read(self.hmtx.offset + @as(u32, self.num_h_metrics - 1) * 4, &adv_buf);
            advance_em = readU16BE(adv, 0);
            const extra_idx = glyph_id - self.num_h_metrics;
            var lsb_buf: [2]u8 = undefined;
            const lsb = try self.reader.read(self.hmtx.offset + @as(u32, self.num_h_metrics) * 4 + @as(u32, extra_idx) * 2, &lsb_buf);
            lsb_em = readI16BE(lsb, 0);
        }

        // Read glyf offset and length from loca
        var off0: u32 = 0;
        var off1: u32 = 0;
        if (self.index_to_loc_format == 0) {
            var loc_buf: [4]u8 = undefined;
            const loc = try self.reader.read(self.loca.offset + @as(u32, glyph_id) * 2, &loc_buf);
            off0 = @as(u32, readU16BE(loc, 0)) * 2;
            off1 = @as(u32, readU16BE(loc, 2)) * 2;
        } else {
            var loc_buf: [8]u8 = undefined;
            const loc = try self.reader.read(self.loca.offset + @as(u32, glyph_id) * 4, &loc_buf);
            off0 = readU32BE(loc, 0);
            off1 = readU32BE(loc, 4);
        }
        if (off1 < off0 or off1 > self.glyf.length) return error.InvalidFont;

        return .{
            .advance_em = advance_em,
            .lsb_em = lsb_em,
            .glyf_offset = self.glyf.offset + off0,
            .glyf_length = off1 - off0,
        };
    }
};

/// Multi-layer font family (e.g. [Base, Ext, PUP]).
pub const Family = struct {
    faces: []const Face,
    // Styles 3/5 are source code in a mixed book page; other families keep the default.
    code_faces: ?[]const Face = null,
    pub inline fn forStyle(self: Family, style_id: u4) Family {
        return .{ .faces = if (style_id == 3 or style_id == 5) self.code_faces orelse self.faces else self.faces };
    }

    pub const ResolvedGlyph = struct {
        layer_index: u8,
        glyph_id: u16,
    };

    /// 2-pass resolution:
    /// 1. When `ivs_cp != 0`, searches Format 14 across ALL layers first so an IVS
    ///    defined in Ext is never shadowed by a bare base character in Base.
    /// 2. Falls back to Format 12 / Format 4 across layers.
    pub fn resolve(self: Family, base_cp: u21, ivs_cp: u21) Error!?ResolvedGlyph {
        if (ivs_cp != 0) {
            for (self.faces, 0..) |*face, i| {
                if (try face.lookupIvsGlyph(base_cp, ivs_cp)) |gid| {
                    return .{ .layer_index = @intCast(i), .glyph_id = gid };
                }
            }
        }
        for (self.faces, 0..) |*face, i| {
            if (try face.lookupBaseGlyph(base_cp)) |gid| {
                return .{ .layer_index = @intCast(i), .glyph_id = gid };
            }
        }
        return null;
    }
};

/// Vertical writing coordinate transformation rules in em-space.
pub const VerticalTransform = enum {
    none,
    sideways,
    rotate_cw_90,
    rotate_prolonged,
    shift_top_right,
    shift_small_kana,

    pub fn forCodepoint(cp: u21) VerticalTransform {
        if (isSideways(cp)) return .sideways;
        return switch (cp) {
            // Brackets, leader dots, dashes -> 90 deg clockwise rotation
            '(',
            ')',
            '[',
            ']',
            '{',
            '}',
            0x2014,
            0x2015,
            0x2025,
            0x2026,
            0x3008...0x301B,
            0xFF08,
            0xFF09,
            0xFF3B,
            0xFF3D,
            0xFF5B,
            0xFF5D,
            0xFF62,
            0xFF63,
            => .rotate_cw_90,
            // Prolonged sound mark & wave dash -> 90 deg rotation + reflection
            0x30FC, 0x301C, 0xFF5E, 0xFF70 => .rotate_prolonged,
            // Ideographic comma & full stop -> shift top-right
            0x3001, 0x3002, 0xFF0C, 0xFF0E, 0xFF61, 0xFF64 => .shift_top_right,
            // Small kana -> slight shift top-right
            0x3041,
            0x3043,
            0x3045,
            0x3047,
            0x3049,
            0x3063,
            0x3083,
            0x3085,
            0x3087,
            0x308E,
            0x3095,
            0x3096,
            0x30A1,
            0x30A3,
            0x30A5,
            0x30A7,
            0x30A9,
            0x30C3,
            0x30E3,
            0x30E5,
            0x30E7,
            0x30EE,
            0x30F5,
            0x30F6,
            => .shift_small_kana,
            else => .none,
        };
    }

    pub inline fn apply(self: VerticalTransform, x: i16, y: i16, upm: u16, ascent: i16, descent: i16) struct { x: i16, y: i16 } {
        const em: i32 = @intCast(upm);
        const center_x: i32 = @divTrunc(em, 2);
        const center_y: i32 = @divTrunc(@as(i32, ascent) + @as(i32, descent), 2);
        const dx = @as(i32, x) - center_x;
        const dy = @as(i32, y) - center_y;

        return switch (self) {
            .none => .{ .x = x, .y = y },
            // Rotate a horizontal cell about its top-left corner. The shared
            // renderer uses the same 880/1024 baseline, so consecutive glyphs
            // join at their horizontal advances instead of an em-box centre.
            .sideways => .{
                .x = @intCast(std.math.clamp(em - @divTrunc(em * 880, 1024) + @as(i32, y), -16384, 16383)),
                .y = @intCast(std.math.clamp(@divTrunc(em * 880, 1024) - @as(i32, x), -16384, 16383)),
            },
            // 90 deg clockwise in Y-up em coordinates: (dx, dy) -> (dy, -dx)
            .rotate_cw_90 => .{
                .x = @intCast(std.math.clamp(center_x + dy, -16384, 16383)),
                .y = @intCast(std.math.clamp(center_y - dx, -16384, 16383)),
            },
            // Prolonged sound mark (ー): rotate 90 deg and mirror X so stroke direction matches vertical writing
            .rotate_prolonged => .{
                .x = @intCast(std.math.clamp(center_x - dy, -16384, 16383)),
                .y = @intCast(std.math.clamp(center_y - dx, -16384, 16383)),
            },
            .shift_top_right => .{
                .x = @intCast(std.math.clamp(@as(i32, x) + @divTrunc(em * 55, 100), -16384, 16383)),
                .y = @intCast(std.math.clamp(@as(i32, y) + @divTrunc(em * 55, 100), -16384, 16383)),
            },
            .shift_small_kana => .{
                .x = @intCast(std.math.clamp(@as(i32, x) + @divTrunc(em, 10), -16384, 16383)),
                .y = @intCast(std.math.clamp(@as(i32, y) + @divTrunc(em, 10), -16384, 16383)),
            },
        };
    }
};

/// Bounded Latin/ASCII support for mixed Japanese book text (UAX #50 sideways).
/// Japanese punctuation and fullwidth forms retain their existing transforms.
pub inline fn isSideways(cp: u21) bool {
    return (cp >= 0x21 and cp <= 0x7e) or
        (cp >= 0xc0 and cp <= 0xd6) or (cp >= 0xd8 and cp <= 0xf6) or
        (cp >= 0xf8 and cp <= 0x24f) or (cp >= 0x1e00 and cp <= 0x1eff);
}

pub const CurvePoint = struct {
    x: i16,
    y: i16,
    on_curve: bool,
    contour_end: bool = false,
};

pub const max_raw_points = 512;
pub const max_contours = 96;
pub const max_composite_components = 4;

/// Decode a single simple `glyf` slice and append normalized points (with implicit
/// on-curve midpoints inserted between consecutive off-curve points) into `out_points`.
fn decodeSimpleGlyfSlice(
    glyf_bytes: []const u8,
    offset_dx: i16,
    offset_dy: i16,
    out_points: []CurvePoint,
    out_count: *usize,
) Error!void {
    if (glyf_bytes.len == 0) return;
    if (glyf_bytes.len < 10) return error.InvalidFont;
    const num_contours_signed = readI16BE(glyf_bytes, 0);
    if (num_contours_signed <= 0) return error.InvalidFont;
    const num_contours: usize = @intCast(num_contours_signed);
    if (num_contours > max_contours) return error.TooManyContours;

    const end_pts_off: usize = 10;
    if (glyf_bytes.len < end_pts_off + num_contours * 2 + 2) return error.InvalidFont;

    var end_pts: [max_contours]u16 = undefined;
    for (0..num_contours) |c| {
        end_pts[c] = readU16BE(glyf_bytes, end_pts_off + c * 2);
        if (c > 0 and end_pts[c] <= end_pts[c - 1]) return error.InvalidFont;
    }
    const total_pts: usize = @as(usize, end_pts[num_contours - 1]) + 1;
    if (total_pts > max_raw_points) return error.TooManyPoints;

    const insn_len_off = end_pts_off + num_contours * 2;
    const insn_len = readU16BE(glyf_bytes, insn_len_off);
    var cursor = insn_len_off + 2 + insn_len;
    if (cursor > glyf_bytes.len) return error.InvalidFont;

    var flags: [max_raw_points]u8 = undefined;
    var p: usize = 0;
    while (p < total_pts) {
        if (cursor >= glyf_bytes.len) return error.InvalidFont;
        const f = glyf_bytes[cursor];
        cursor += 1;
        flags[p] = f;
        p += 1;
        if ((f & 0x08) != 0) {
            if (cursor >= glyf_bytes.len) return error.InvalidFont;
            const repeat = glyf_bytes[cursor];
            cursor += 1;
            if (p + repeat > total_pts) return error.InvalidFont;
            for (0..repeat) |_| {
                flags[p] = f;
                p += 1;
            }
        }
    }

    var raw_x: [max_raw_points]i16 = undefined;
    var cur_x: i16 = offset_dx;
    for (0..total_pts) |idx| {
        const f = flags[idx];
        if ((f & 0x02) != 0) {
            if (cursor >= glyf_bytes.len) return error.InvalidFont;
            const d: i16 = glyf_bytes[cursor];
            cursor += 1;
            cur_x +%= if ((f & 0x10) != 0) d else -d;
        } else if ((f & 0x10) == 0) {
            if (cursor + 2 > glyf_bytes.len) return error.InvalidFont;
            cur_x +%= readI16BE(glyf_bytes, cursor);
            cursor += 2;
        }
        raw_x[idx] = cur_x;
    }

    var raw_y: [max_raw_points]i16 = undefined;
    var cur_y: i16 = offset_dy;
    for (0..total_pts) |idx| {
        const f = flags[idx];
        if ((f & 0x04) != 0) {
            if (cursor >= glyf_bytes.len) return error.InvalidFont;
            const d: i16 = glyf_bytes[cursor];
            cursor += 1;
            cur_y +%= if ((f & 0x20) != 0) d else -d;
        } else if ((f & 0x20) == 0) {
            if (cursor + 2 > glyf_bytes.len) return error.InvalidFont;
            cur_y +%= readI16BE(glyf_bytes, cursor);
            cursor += 2;
        }
        raw_y[idx] = cur_y;
    }

    // Normalize each contour: ensure starts on-curve and insert implicit midpoints
    var c_start: usize = 0;
    for (0..num_contours) |c| {
        const c_end: usize = end_pts[c];
        const c_len = c_end - c_start + 1;
        const base_out = out_count.*;

        for (0..c_len) |k| {
            const idx = c_start + k;
            const next_idx = c_start + (k + 1) % c_len;
            const on0 = (flags[idx] & 0x01) != 0;
            const on1 = (flags[next_idx] & 0x01) != 0;

            if (out_count.* >= out_points.len) return error.TooManyPoints;
            out_points[out_count.*] = .{
                .x = raw_x[idx],
                .y = raw_y[idx],
                .on_curve = on0,
                .contour_end = false,
            };
            out_count.* += 1;

            if (!on0 and !on1) {
                if (out_count.* >= out_points.len) return error.TooManyPoints;
                out_points[out_count.*] = .{
                    .x = @intCast(@divTrunc(@as(i32, raw_x[idx]) + @as(i32, raw_x[next_idx]), 2)),
                    .y = @intCast(@divTrunc(@as(i32, raw_y[idx]) + @as(i32, raw_y[next_idx]), 2)),
                    .on_curve = true,
                    .contour_end = false,
                };
                out_count.* += 1;
            }
        }
        if (out_count.* > base_out) {
            if (!out_points[base_out].on_curve and out_count.* - base_out >= 2) {
                const last_pt = out_points[out_count.* - 1];
                var rot_i = out_count.* - 1;
                while (rot_i > base_out) : (rot_i -= 1) {
                    out_points[rot_i] = out_points[rot_i - 1];
                }
                out_points[base_out] = last_pt;
            }
            out_points[out_count.* - 1].contour_end = true;
        }
        c_start = c_end + 1;
    }
}

/// Decode a glyph's contours (Simple or depth-1 Composite up to 4 components)
/// and apply optional vertical typesetting coordinate transforms.
pub fn decodeGlyphContours(
    face: *const Face,
    glyph_id: u16,
    v_transform: VerticalTransform,
    glyf_scratch: []u8,
    out_points: []CurvePoint,
) Error![]CurvePoint {
    const span = try face.glyphSpan(glyph_id);
    if (span.glyf_length == 0) return out_points[0..0];
    if (span.glyf_length > glyf_scratch.len) return error.BufferTooSmall;

    const main_bytes = try face.reader.read(span.glyf_offset, glyf_scratch[0..span.glyf_length]);
    if (main_bytes.len < 10) return error.InvalidFont;
    const num_contours = readI16BE(main_bytes, 0);

    var count: usize = 0;
    if (num_contours >= 0) {
        try decodeSimpleGlyfSlice(main_bytes, 0, 0, out_points, &count);
    } else {
        // Iterative depth-1 composite glyph decoding (max 4 components, no recursion)
        const Comp = struct { gid: u16, dx: i16, dy: i16 };
        var comps: [max_composite_components]Comp = undefined;
        var comp_count: usize = 0;
        var pos: usize = 10;
        var more = true;
        while (more) {
            if (comp_count >= max_composite_components) return error.TooManyComponents;
            if (pos + 4 > main_bytes.len) return error.InvalidFont;
            const c_flags = readU16BE(main_bytes, pos);
            const c_gid = readU16BE(main_bytes, pos + 2);
            pos += 4;
            if ((c_flags & 0x0002) == 0) return error.UnsupportedCompositeTransform; // ARGS_ARE_XY_VALUES required
            if ((c_flags & (0x0008 | 0x0040 | 0x0080)) != 0) return error.UnsupportedCompositeTransform;

            var dx: i16 = 0;
            var dy: i16 = 0;
            if ((c_flags & 0x0001) != 0) {
                if (pos + 4 > main_bytes.len) return error.InvalidFont;
                dx = readI16BE(main_bytes, pos);
                dy = readI16BE(main_bytes, pos + 2);
                pos += 4;
            } else {
                if (pos + 2 > main_bytes.len) return error.InvalidFont;
                dx = @as(i8, @bitCast(main_bytes[pos]));
                dy = @as(i8, @bitCast(main_bytes[pos + 1]));
                pos += 2;
            }
            comps[comp_count] = .{ .gid = c_gid, .dx = dx, .dy = dy };
            comp_count += 1;
            more = (c_flags & 0x0020) != 0;
        }

        for (comps[0..comp_count]) |comp| {
            const c_span = try face.glyphSpan(comp.gid);
            if (c_span.glyf_length == 0) continue;
            if (c_span.glyf_length > glyf_scratch.len) return error.BufferTooSmall;
            const c_bytes = try face.reader.read(c_span.glyf_offset, glyf_scratch[0..c_span.glyf_length]);
            try decodeSimpleGlyfSlice(c_bytes, comp.dx, comp.dy, out_points, &count);
        }
    }

    if (v_transform != .none) {
        for (out_points[0..count]) |*pt| {
            const tr = v_transform.apply(pt.x, pt.y, face.units_per_em, face.ascent, face.descent);
            pt.x = tr.x;
            pt.y = tr.y;
        }
    }
    return out_points[0..count];
}

pub const RasterMetrics = struct {
    width: u16,
    height: u16,
    left_px: i16,
    top_px: i16,
    /// 26.6 fixed-point horizontal advance (compatible with line_layout.zig)
    x_advance_26_6: i32,
    /// 26.6 fixed-point vertical advance (negative for top-to-bottom in line_layout.zig)
    y_advance_26_6: i32,
};

const Edge = struct {
    x0_fp: i32, // 16.16 fixed point in pixel space
    y0_sub: i32, // subpixel row index (4x vertical oversampling)
    x1_fp: i32,
    y1_sub: i32,
    dir: i8,
};

fn addLineSegment(edges: []Edge, edge_count: *usize, x0_fp: i32, y0_sub: i32, x1_fp: i32, y1_sub: i32) void {
    if (y0_sub == y1_sub or edge_count.* >= edges.len) return;
    if (y0_sub < y1_sub) {
        edges[edge_count.*] = .{ .x0_fp = x0_fp, .y0_sub = y0_sub, .x1_fp = x1_fp, .y1_sub = y1_sub, .dir = 1 };
    } else {
        edges[edge_count.*] = .{ .x0_fp = x1_fp, .y0_sub = y1_sub, .x1_fp = x0_fp, .y1_sub = y0_sub, .dir = -1 };
    }
    edge_count.* += 1;
}

/// Rasterize decoded contour points into an 8bpp anti-aliased alpha bitmap (`out_alpha`).
/// Uses 4x vertical subpixel scanline + horizontal analytical coverage with zero heap allocations.
pub fn rasterizeContours(
    face: *const Face,
    advance_em: u16,
    points: []const CurvePoint,
    px_size: u8,
    vertical: bool,
    out_alpha: []u8,
) Error!RasterMetrics {
    if (px_size < 6 or px_size > 200) return error.InvalidScale;
    const upm: i32 = @intCast(face.units_per_em);
    const scale_px: i32 = @intCast(px_size);

    const adv_26_6: i32 = @divTrunc(@as(i32, advance_em) * scale_px * 64 + @divTrunc(upm, 2), upm);
    const v_adv_26_6: i32 = -(@as(i32, scale_px) * 64);

    if (points.len == 0) {
        return .{
            .width = 0,
            .height = 0,
            .left_px = 0,
            .top_px = 0,
            .x_advance_26_6 = if (vertical) 0 else adv_26_6,
            .y_advance_26_6 = if (vertical) v_adv_26_6 else 0,
        };
    }

    // Compute bounding box in pixel space
    var min_em_x: i32 = points[0].x;
    var max_em_x: i32 = points[0].x;
    var min_em_y: i32 = points[0].y;
    var max_em_y: i32 = points[0].y;
    for (points[1..]) |pt| {
        min_em_x = @min(min_em_x, pt.x);
        max_em_x = @max(max_em_x, pt.x);
        min_em_y = @min(min_em_y, pt.y);
        max_em_y = @max(max_em_y, pt.y);
    }

    const left_px: i32 = @divFloor(min_em_x * scale_px, upm);
    const right_px: i32 = @divFloor(max_em_x * scale_px + upm - 1, upm) + 1;
    const bottom_px: i32 = @divFloor(min_em_y * scale_px, upm);
    const top_px: i32 = @divFloor(max_em_y * scale_px + upm - 1, upm) + 1;

    const width: usize = @intCast(@max(1, right_px - left_px));
    const height: usize = @intCast(@max(1, top_px - bottom_px));
    if (width * height > out_alpha.len) return error.BufferTooSmall;
    @memset(out_alpha[0 .. width * height], 0);

    // Flatten contours into edges (4x vertical subpixels, 16.16 X fixed point)
    var edges: [1536]Edge = undefined;
    var edge_count: usize = 0;

    const toXFp = struct {
        inline fn f(em_x: i32, l_px: i32, s_px: i32, u: i32) i32 {
            // The quotient fits 16.16 bitmap coordinates, but an ordinary
            // 1000-em glyph at 36 px already overflows an i32 numerator.
            return @intCast(@divTrunc((@as(i64, em_x) * s_px - @as(i64, l_px) * u) * 65536, u));
        }
    }.f;
    const toYSub = struct {
        inline fn f(em_y: i32, t_px: i32, s_px: i32, u: i32) i32 {
            return @divTrunc((t_px * u - em_y * s_px) * 4, u);
        }
    }.f;

    var c_start: usize = 0;
    while (c_start < points.len) {
        var c_end = c_start;
        while (c_end < points.len and !points[c_end].contour_end) : (c_end += 1) {}
        if (c_end >= points.len) break;
        const c_len = c_end - c_start + 1;

        var idx: usize = 0;
        while (idx < c_len) {
            const p0 = points[c_start + idx];
            const p1 = points[c_start + (idx + 1) % c_len];
            if (p1.on_curve) {
                addLineSegment(
                    &edges,
                    &edge_count,
                    toXFp(p0.x, left_px, scale_px, upm),
                    toYSub(p0.y, top_px, scale_px, upm),
                    toXFp(p1.x, left_px, scale_px, upm),
                    toYSub(p1.y, top_px, scale_px, upm),
                );
                idx += 1;
            } else {
                // p1 is off-curve quadratic control point, p2 is guaranteed on-curve
                const p2 = points[c_start + (idx + 2) % c_len];
                var prev_x = toXFp(p0.x, left_px, scale_px, upm);
                var prev_y = toYSub(p0.y, top_px, scale_px, upm);
                const x0 = prev_x;
                const y0 = prev_y;
                const x1 = toXFp(p1.x, left_px, scale_px, upm);
                const y1 = toYSub(p1.y, top_px, scale_px, upm);
                const x2 = toXFp(p2.x, left_px, scale_px, upm);
                const y2 = toYSub(p2.y, top_px, scale_px, upm);

                const steps = 4;
                var s: i32 = 1;
                while (s <= steps) : (s += 1) {
                    const inv = steps - s;
                    const w0 = inv * inv;
                    const w1 = 2 * inv * s;
                    const w2 = s * s;
                    const denom = steps * steps;
                    const nx: i32 = @intCast(@divTrunc(@as(i64, x0) * w0 + @as(i64, x1) * w1 + @as(i64, x2) * w2, denom));
                    const ny: i32 = @intCast(@divTrunc(@as(i64, y0) * w0 + @as(i64, y1) * w1 + @as(i64, y2) * w2, denom));
                    addLineSegment(&edges, &edge_count, prev_x, prev_y, nx, ny);
                    prev_x = nx;
                    prev_y = ny;
                }
                idx += 2;
            }
        }
        c_start = c_end + 1;
    }

    // Scanline Non-Zero Winding fill (4x vertical × 4x horizontal supersampled coverage)
    const sub_rows: i32 = @intCast(height * 4);
    var xs: [128]struct { x_fp: i32, dir: i8 } = undefined;

    var sy: i32 = 0;
    while (sy < sub_rows) : (sy += 1) {
        var x_count: usize = 0;
        for (edges[0..edge_count]) |e| {
            if (sy >= e.y0_sub and sy < e.y1_sub and x_count < xs.len) {
                const dy = e.y1_sub - e.y0_sub;
                const t = sy - e.y0_sub;
                const x_at: i32 = @intCast(@as(i64, e.x0_fp) + @divTrunc(@as(i64, e.x1_fp - e.x0_fp) * (2 * t + 1), 2 * dy));
                xs[x_count] = .{ .x_fp = x_at, .dir = e.dir };
                x_count += 1;
            }
        }
        if (x_count < 2) continue;

        // Insertion sort intersections by x_fp
        var i: usize = 1;
        while (i < x_count) : (i += 1) {
            const key = xs[i];
            var j = i;
            while (j > 0 and xs[j - 1].x_fp > key.x_fp) : (j -= 1) {
                xs[j] = xs[j - 1];
            }
            xs[j] = key;
        }

        const py: usize = @intCast(@divTrunc(sy, 4));
        const row_slice = out_alpha[py * width .. (py + 1) * width];

        var winding: i32 = 0;
        var span_start_fp: i32 = 0;
        for (xs[0..x_count]) |hit| {
            const prev_w = winding;
            winding += hit.dir;
            if (prev_w == 0 and winding != 0) {
                span_start_fp = hit.x_fp;
            } else if (prev_w != 0 and winding == 0) {
                const x_start = @max(0, span_start_fp);
                const x_end = @min(@as(i32, @intCast(width)) * 65536, hit.x_fp);
                if (x_end > x_start) {
                    const px0: usize = @intCast(@divTrunc(x_start, 65536));
                    const px1: usize = @intCast(@min(@as(i32, @intCast(width)) - 1, @divTrunc(x_end - 1, 65536)));
                    for (px0..px1 + 1) |px| {
                        const cell_l: i32 = @as(i32, @intCast(px)) * 65536;
                        const cell_r: i32 = cell_l + 65536;
                        const ov_l = @max(x_start, cell_l);
                        const ov_r = @min(x_end, cell_r);
                        if (ov_r > ov_l) {
                            const add_alpha: u16 = @intCast(@divTrunc((ov_r - ov_l) * 64, 65536));
                            const cur: u16 = row_slice[px];
                            row_slice[px] = @intCast(@min(255, cur + add_alpha));
                        }
                    }
                }
            }
        }
    }

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .left_px = @intCast(left_px),
        .top_px = @intCast(top_px),
        .x_advance_26_6 = if (vertical) 0 else adv_26_6,
        .y_advance_26_6 = if (vertical) v_adv_26_6 else 0,
    };
}

// ============================================================================
// 2-Tier Cache (Outline Cache + Bitmap Cache) for Zero-I/O Style/Size Changes
// ============================================================================

pub const OutlineKey = packed struct(u32) {
    style_id: u4 = 0,
    layer_index: u4 = 0,
    glyph_id: u16 = 0,
    reserved: u8 = 0,
};

pub const BitmapKey = packed struct(u64) {
    base_cp: u21,
    ivs_cp: u21 = 0,
    px_size: u8,
    style_id: u4 = 0,
    vertical: bool = false,
    reserved: u9 = 0,
};

/// Bounded 2-tier cache:
/// - Tier 1 (Outline Cache): caches decoded base (horizontal) `CurvePoint` slices
///   and `advance_em` keyed by `(style_id, layer_index, glyph_id)`. Independent of
///   `px_size` and `vertical`, so live font-size or horizontal/vertical toggling
///   requires zero media/SD reads.
/// - Tier 2 (Bitmap Cache): caches 8bpp anti-aliased bitmaps and `RasterMetrics`
///   keyed by `BitmapKey`.
pub fn TwoTierCache(
    comptime outline_slots: usize,
    comptime max_pts_per_outline: usize,
    comptime bitmap_slots: usize,
    comptime max_bytes_per_bitmap: usize,
) type {
    return struct {
        const Self = @This();

        pub const OutlineSlot = struct {
            valid: bool = false,
            stamp: u32 = 0,
            key: OutlineKey = .{},
            resolved_key: u64 = 0, // caches (style_id, base_cp, ivs_cp) -> OutlineKey mapping
            advance_em: u16 = 0,
            point_count: u16 = 0,
            points: [max_pts_per_outline]CurvePoint,
        };

        pub const BitmapSlot = struct {
            valid: bool = false,
            stamp: u32 = 0,
            key: BitmapKey = .{ .base_cp = 0, .px_size = 0 },
            metrics: RasterMetrics = .{ .width = 0, .height = 0, .left_px = 0, .top_px = 0, .x_advance_26_6 = 0, .y_advance_26_6 = 0 },
            pixels: [max_bytes_per_bitmap]u8,
        };

        pub const CachedGlyph = struct {
            metrics: RasterMetrics,
            alpha: []const u8,
        };

        clock: u32 = 0,
        outline_misses: u32 = 0,
        bitmap_misses: u32 = 0,
        outlines: [outline_slots]OutlineSlot = emptyOutlines(),
        bitmaps: [bitmap_slots]BitmapSlot = emptyBitmaps(),

        fn emptyOutlines() [outline_slots]OutlineSlot {
            // SAFETY: invalid slots have zero point_count; decoding writes
            // the populated prefix before setting valid and publishing it.
            return @splat(.{ .points = undefined });
        }

        fn emptyBitmaps() [bitmap_slots]BitmapSlot {
            // SAFETY: invalid slots expose no pixels; rasterization writes
            // the bitmap before setting valid and publishing its metrics.
            return @splat(.{ .pixels = undefined });
        }

        inline fn makeResolvedTag(style_id: u4, base_cp: u21, ivs_cp: u21) u64 {
            return (@as(u64, style_id) << 42) | (@as(u64, ivs_cp) << 21) | @as(u64, base_cp);
        }

        pub fn getOrRender(
            self: *Self,
            input_family: Family,
            style_id: u4,
            base_cp: u21,
            ivs_cp: u21,
            px_size: u8,
            vertical: bool,
            glyf_scratch: []u8,
        ) Error!CachedGlyph {
            const family = input_family.forStyle(style_id);
            // Some CJK subset fonts omit whitespace from cmap entirely. Whitespace
            // still participates in layout and must not abort a source-code frame.
            if (base_cp == ' ' or base_cp == '\t' or base_cp == 0x3000) {
                if (px_size < 6 or px_size > 200) return error.InvalidScale;
                var space_advance: i32 = @as(i32, px_size) * 32;
                if (base_cp != 0x3000) {
                    if (try family.resolve(' ', 0)) |resolved| {
                        const face = &family.faces[resolved.layer_index];
                        const span = try face.glyphSpan(resolved.glyph_id);
                        space_advance = @divTrunc(@as(i32, span.advance_em) * px_size * 64 + @divTrunc(@as(i32, face.units_per_em), 2), face.units_per_em);
                    }
                }
                const advance = if (base_cp == '\t') space_advance * 4 else if (base_cp == 0x3000) @as(i32, px_size) * 64 else space_advance;
                return .{ .metrics = .{
                    .width = 0,
                    .height = 0,
                    .left_px = 0,
                    .top_px = 0,
                    .x_advance_26_6 = if (vertical) 0 else advance,
                    .y_advance_26_6 = if (vertical) -advance else 0,
                }, .alpha = &.{} };
            }
            const bkey = BitmapKey{
                .base_cp = base_cp,
                .ivs_cp = ivs_cp,
                .px_size = px_size,
                .style_id = style_id,
                .vertical = vertical,
            };

            // 1. Check Tier 2 (Bitmap Cache)
            for (&self.bitmaps) |*slot| {
                if (slot.valid and slot.key == bkey) {
                    self.clock +%= 1;
                    slot.stamp = self.clock;
                    const len = @as(usize, slot.metrics.width) * slot.metrics.height;
                    return .{ .metrics = slot.metrics, .alpha = slot.pixels[0..len] };
                }
            }
            self.bitmap_misses += 1;

            // 2. Check Tier 1 (Outline Cache) by (style_id, base_cp, ivs_cp) tag first
            const rtag = makeResolvedTag(style_id, base_cp, ivs_cp);
            var o_idx: ?usize = null;
            for (&self.outlines, 0..) |*slot, i| {
                if (slot.valid and slot.resolved_key == rtag) {
                    o_idx = i;
                    break;
                }
            }

            if (o_idx == null) {
                self.outline_misses += 1;
                const resolved = (try family.resolve(base_cp, ivs_cp)) orelse
                    (try family.resolve(0xfffd, 0)) orelse
                    (try family.resolve(0x25a1, 0)) orelse return error.GlyphNotFound;
                const okey = OutlineKey{
                    .style_id = style_id,
                    .layer_index = @intCast(resolved.layer_index),
                    .glyph_id = resolved.glyph_id,
                };
                const face = &family.faces[resolved.layer_index];
                const span = try face.glyphSpan(resolved.glyph_id);

                // Pick LRU outline slot
                var victim: usize = 0;
                for (&self.outlines, 0..) |*slot, i| {
                    if (!slot.valid) {
                        victim = i;
                        break;
                    }
                    if (slot.stamp < self.outlines[victim].stamp) victim = i;
                }

                var o_slot = &self.outlines[victim];
                const decoded = try decodeGlyphContours(face, resolved.glyph_id, .none, glyf_scratch, &o_slot.points);
                self.clock +%= 1;
                o_slot.valid = true;
                o_slot.stamp = self.clock;
                o_slot.key = okey;
                o_slot.resolved_key = rtag;
                o_slot.advance_em = span.advance_em;
                o_slot.point_count = @intCast(decoded.len);
                o_idx = victim;
            } else {
                self.clock +%= 1;
                self.outlines[o_idx.?].stamp = self.clock;
            }

            const o_slot = &self.outlines[o_idx.?];
            const face = &family.faces[o_slot.key.layer_index];

            // Apply vertical transform on a stack copy of the cached outline points if needed
            var transformed_pts: [max_pts_per_outline]CurvePoint = undefined;
            const pt_count: usize = o_slot.point_count;
            @memcpy(transformed_pts[0..pt_count], o_slot.points[0..pt_count]);
            if (vertical) {
                const v_tr = VerticalTransform.forCodepoint(base_cp);
                if (v_tr != .none) {
                    for (transformed_pts[0..pt_count]) |*pt| {
                        const tr = v_tr.apply(pt.x, pt.y, face.units_per_em, face.ascent, face.descent);
                        pt.x = tr.x;
                        pt.y = tr.y;
                    }
                }
            }

            // Pick LRU bitmap slot
            var b_victim: usize = 0;
            for (&self.bitmaps, 0..) |*slot, i| {
                if (!slot.valid) {
                    b_victim = i;
                    break;
                }
                if (slot.stamp < self.bitmaps[b_victim].stamp) b_victim = i;
            }

            var b_slot = &self.bitmaps[b_victim];
            var metrics = try rasterizeContours(
                face,
                o_slot.advance_em,
                transformed_pts[0..pt_count],
                px_size,
                vertical,
                &b_slot.pixels,
            );
            if (vertical and isSideways(base_cp)) {
                metrics.y_advance_26_6 = -@divTrunc(@as(i32, o_slot.advance_em) * px_size * 64 + @divTrunc(@as(i32, face.units_per_em), 2), face.units_per_em);
            }
            self.clock +%= 1;
            b_slot.valid = true;
            b_slot.stamp = self.clock;
            b_slot.key = bkey;
            b_slot.metrics = metrics;

            const len = @as(usize, metrics.width) * metrics.height;
            return .{ .metrics = metrics, .alpha = b_slot.pixels[0..len] };
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

/// Build a minimal valid TrueType font binary in comptime/test buffer with:
/// - Glyph 0: .notdef (empty)
/// - Glyph 1: Base Kanji/Bracket (e.g. U+845B '葛' or U+300C '「') - Simple rectangular/quadratic contour
/// - Glyph 2: IVS variant (U+845B + U+E0100) or Composite Glyph referencing Glyph 1
fn buildTestFont(buf: []u8, base_cp: u32, ivs_cp: u24, include_ivs: bool) []const u8 {
    @memset(buf, 0);
    // 7 tables: cmap, glyf, head, hhea, hmtx, loca, maxp
    const num_tables: u16 = 7;
    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, buf[4..6], num_tables, .big);

    const head_off: u32 = 12 + @as(u32, num_tables) * 16; // 124
    const hhea_off: u32 = head_off + 56; // 180
    const maxp_off: u32 = hhea_off + 36; // 216
    const hmtx_off: u32 = maxp_off + 8; // 224
    const loca_off: u32 = hmtx_off + 12; // 236 (3 glyphs * 4)
    const cmap_off: u32 = loca_off + 16; // 252 (4 offsets * 4)
    const glyf_off: u32 = cmap_off + 128; // 380

    // Glyph 1: simple contour with 4 points (3 on-curve, 1 off-curve control point)
    // Header (10B) + endPts(2B) + insnLen(2B) + flags(4B) + X(8B) + Y(8B) = 34B, padded to 36B
    const g1_off: u32 = 0;
    const g1_len: u32 = 36;
    // Glyph 2: composite glyph referencing Glyph 1 shifted by (+100, +50) -> 10B hdr + 8B comp = 18B, padded to 20B
    const g2_off: u32 = g1_off + g1_len;
    const g2_len: u32 = 20;
    const glyf_total: u32 = g2_off + g2_len;

    const writeEntry = struct {
        fn f(b: []u8, idx: usize, tag: *const [4]u8, off: u32, len: u32) void {
            const p = 12 + idx * 16;
            @memcpy(b[p .. p + 4], tag);
            std.mem.writeInt(u32, b[p + 8 ..][0..4], off, .big);
            std.mem.writeInt(u32, b[p + 12 ..][0..4], len, .big);
        }
    }.f;
    writeEntry(buf, 0, "cmap", cmap_off, 128);
    writeEntry(buf, 1, "glyf", glyf_off, glyf_total);
    writeEntry(buf, 2, "head", head_off, 54);
    writeEntry(buf, 3, "hhea", hhea_off, 36);
    writeEntry(buf, 4, "hmtx", hmtx_off, 12);
    writeEntry(buf, 5, "loca", loca_off, 16);
    writeEntry(buf, 6, "maxp", maxp_off, 6);

    // head: unitsPerEm = 1000, indexToLocFormat = 1 (offset32)
    std.mem.writeInt(u16, buf[head_off + 18 ..][0..2], 1000, .big);
    std.mem.writeInt(i16, buf[head_off + 50 ..][0..2], 1, .big);

    // hhea: ascent = 880, descent = -120, numOfLongHorMetrics = 3
    std.mem.writeInt(i16, buf[hhea_off + 4 ..][0..2], 880, .big);
    std.mem.writeInt(i16, buf[hhea_off + 6 ..][0..2], -120, .big);
    std.mem.writeInt(u16, buf[hhea_off + 34 ..][0..2], 3, .big);

    // maxp: numGlyphs = 3
    std.mem.writeInt(u16, buf[maxp_off + 4 ..][0..2], 3, .big);

    // hmtx: 3 glyphs, advance = 1000, lsb = 100
    for (0..3) |g| {
        std.mem.writeInt(u16, buf[hmtx_off + g * 4 ..][0..2], 1000, .big);
        std.mem.writeInt(i16, buf[hmtx_off + g * 4 + 2 ..][0..2], 100, .big);
    }

    // loca: [0, 0, g1_len, g1_len + g2_len]
    std.mem.writeInt(u32, buf[loca_off + 0 ..][0..4], 0, .big);
    std.mem.writeInt(u32, buf[loca_off + 4 ..][0..4], g1_off, .big);
    std.mem.writeInt(u32, buf[loca_off + 8 ..][0..4], g2_off, .big);
    std.mem.writeInt(u32, buf[loca_off + 12 ..][0..4], glyf_total, .big);

    // cmap: 2 subtables (Format 12 at +20, Format 14 at +48)
    std.mem.writeInt(u16, buf[cmap_off + 2 ..][0..2], if (include_ivs) 2 else 1, .big);
    // Encoding record 0: platform 3, encoding 10 -> offset 20
    std.mem.writeInt(u16, buf[cmap_off + 4 ..][0..2], 3, .big);
    std.mem.writeInt(u16, buf[cmap_off + 6 ..][0..2], 10, .big);
    std.mem.writeInt(u32, buf[cmap_off + 8 ..][0..4], 20, .big);
    if (include_ivs) {
        // Encoding record 1: platform 0, encoding 5 -> offset 48
        std.mem.writeInt(u16, buf[cmap_off + 12 ..][0..2], 0, .big);
        std.mem.writeInt(u16, buf[cmap_off + 14 ..][0..2], 5, .big);
        std.mem.writeInt(u32, buf[cmap_off + 16 ..][0..4], 48, .big);
    }

    // Format 12 at cmap_off + 20 (length 28, 1 group: base_cp -> glyph 1)
    const f12 = cmap_off + 20;
    std.mem.writeInt(u16, buf[f12 + 0 ..][0..2], 12, .big);
    std.mem.writeInt(u32, buf[f12 + 4 ..][0..4], 28, .big);
    std.mem.writeInt(u32, buf[f12 + 12 ..][0..4], 1, .big);
    std.mem.writeInt(u32, buf[f12 + 16 ..][0..4], base_cp, .big);
    std.mem.writeInt(u32, buf[f12 + 20 ..][0..4], base_cp, .big);
    std.mem.writeInt(u32, buf[f12 + 24 ..][0..4], 1, .big);

    // Format 14 at cmap_off + 48 (1 VS record -> Non-Default UVS mapping base_cp -> glyph 2)
    if (include_ivs) {
        const f14 = cmap_off + 48;
        std.mem.writeInt(u16, buf[f14 + 0 ..][0..2], 14, .big);
        std.mem.writeInt(u32, buf[f14 + 2 ..][0..4], 30, .big);
        std.mem.writeInt(u32, buf[f14 + 6 ..][0..4], 1, .big);
        // 24-bit ivs_cp
        buf[f14 + 10] = @intCast((ivs_cp >> 16) & 0xFF);
        buf[f14 + 11] = @intCast((ivs_cp >> 8) & 0xFF);
        buf[f14 + 12] = @intCast(ivs_cp & 0xFF);
        std.mem.writeInt(u32, buf[f14 + 13 ..][0..4], 0, .big); // defaultUVSOffset = 0
        std.mem.writeInt(u32, buf[f14 + 17 ..][0..4], 21, .big); // nonDefaultUVSOffset = 21
        // Non-Default UVS at f14 + 21: numUVSMappings = 1, (base_cp -> glyph 2)
        std.mem.writeInt(u32, buf[f14 + 21 ..][0..4], 1, .big);
        buf[f14 + 25] = @intCast((base_cp >> 16) & 0xFF);
        buf[f14 + 26] = @intCast((base_cp >> 8) & 0xFF);
        buf[f14 + 27] = @intCast(base_cp & 0xFF);
        std.mem.writeInt(u16, buf[f14 + 28 ..][0..2], 2, .big);
    }

    // Glyph 1 at glyf_off + g1_off: 1 contour, 4 points: (100,100) on, (100,800) on, (500,850) off-curve, (800,100) on
    const g1 = glyf_off + g1_off;
    std.mem.writeInt(i16, buf[g1 + 0 ..][0..2], 1, .big); // numberOfContours = 1
    std.mem.writeInt(i16, buf[g1 + 2 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 4 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 6 ..][0..2], 800, .big);
    std.mem.writeInt(i16, buf[g1 + 8 ..][0..2], 850, .big);
    std.mem.writeInt(u16, buf[g1 + 10 ..][0..2], 3, .big); // endPtsOfContours[0] = 3
    std.mem.writeInt(u16, buf[g1 + 12 ..][0..2], 0, .big); // instructionLength = 0
    // 4 flags (all 16-bit signed deltas, point 2 is off-curve = 0x00, others on-curve = 0x01)
    buf[g1 + 14] = 0x01;
    buf[g1 + 15] = 0x01;
    buf[g1 + 16] = 0x00;
    buf[g1 + 17] = 0x01;
    // X deltas: +100, +0, +400, +300
    std.mem.writeInt(i16, buf[g1 + 18 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 20 ..][0..2], 0, .big);
    std.mem.writeInt(i16, buf[g1 + 22 ..][0..2], 400, .big);
    std.mem.writeInt(i16, buf[g1 + 24 ..][0..2], 300, .big);
    // Y deltas: +100, +700, +50, -750
    std.mem.writeInt(i16, buf[g1 + 26 ..][0..2], 100, .big);
    std.mem.writeInt(i16, buf[g1 + 28 ..][0..2], 700, .big);
    std.mem.writeInt(i16, buf[g1 + 30 ..][0..2], 50, .big);
    std.mem.writeInt(i16, buf[g1 + 32 ..][0..2], -750, .big);

    // Glyph 2 at glyf_off + g2_off: Composite glyph (-1 contours) referencing Glyph 1 with (+100, +50)
    const g2 = glyf_off + g2_off;
    std.mem.writeInt(i16, buf[g2 + 0 ..][0..2], -1, .big);
    std.mem.writeInt(u16, buf[g2 + 10 ..][0..2], 0x0003, .big); // ARG_1_AND_2_ARE_WORDS | ARGS_ARE_XY_VALUES
    std.mem.writeInt(u16, buf[g2 + 12 ..][0..2], 1, .big); // component glyph 1
    std.mem.writeInt(i16, buf[g2 + 14 ..][0..2], 100, .big); // dx = +100
    std.mem.writeInt(i16, buf[g2 + 16 ..][0..2], 50, .big); // dy = +50

    return buf[0 .. glyf_off + glyf_total];
}

test "2-pass IVS resolution across multi-layer Family does not shadow Ext IVS with Base glyph" {
    var base_buf: [512]u8 = undefined;
    var ext_buf: [512]u8 = undefined;
    // Layer 0 (Base) has bare U+845B ('葛') as glyph 1, but NO IVS U+E0100
    const base_bytes = buildTestFont(&base_buf, 0x845B, 0xE0100, false);
    // Layer 1 (Ext) has U+845B + U+E0100 mapped to glyph 2
    const ext_bytes = buildTestFont(&ext_buf, 0x845B, 0xE0100, true);

    const base_face = try Face.init(SliceReader.fromSlice(&base_bytes));
    const ext_face = try Face.init(SliceReader.fromSlice(&ext_bytes));
    const family = Family{ .faces = &[_]Face{ base_face, ext_face } };

    // Bare U+845B resolves to Layer 0 (Base), glyph 1
    const bare = (try family.resolve(0x845B, 0)).?;
    try std.testing.expectEqual(@as(u8, 0), bare.layer_index);
    try std.testing.expectEqual(@as(u16, 1), bare.glyph_id);

    // U+845B + IVS U+E0100 resolves to Layer 1 (Ext), glyph 2!
    const ivs = (try family.resolve(0x845B, 0xE0100)).?;
    try std.testing.expectEqual(@as(u8, 1), ivs.layer_index);
    try std.testing.expectEqual(@as(u16, 2), ivs.glyph_id);
}

test "simple and composite glyph contour decoding vertical rotation and 8bpp rasterization" {
    var font_buf: [512]u8 = undefined;
    const font_bytes = buildTestFont(&font_buf, 0x300C, 0xE0100, true);
    const face = try Face.init(SliceReader.fromSlice(&font_bytes));

    var scratch: [256]u8 = undefined;
    var pts_h: [64]CurvePoint = undefined;
    const decoded_h = try decodeGlyphContours(&face, 1, .none, &scratch, &pts_h);
    try std.testing.expectEqual(@as(usize, 4), decoded_h.len);
    try std.testing.expect(decoded_h[3].contour_end);

    // Composite glyph 2 shifts glyph 1 by (+100, +50)
    var pts_comp: [64]CurvePoint = undefined;
    const decoded_comp = try decodeGlyphContours(&face, 2, .none, &scratch, &pts_comp);
    try std.testing.expectEqual(@as(usize, 4), decoded_comp.len);
    try std.testing.expectEqual(decoded_h[0].x + 100, decoded_comp[0].x);
    try std.testing.expectEqual(decoded_h[0].y + 50, decoded_comp[0].y);

    // Vertical bracket U+300C ('「') rotates 90 deg clockwise in em space
    var pts_v: [64]CurvePoint = undefined;
    const v_tr = VerticalTransform.forCodepoint(0x300C);
    try std.testing.expectEqual(VerticalTransform.rotate_cw_90, v_tr);
    const decoded_v = try decodeGlyphContours(&face, 1, v_tr, &scratch, &pts_v);
    try std.testing.expect(decoded_v[0].x != decoded_h[0].x or decoded_v[0].y != decoded_h[0].y);

    // Rasterize at 24px horizontal and vertical
    var alpha: [64 * 64]u8 = undefined;
    const span = try face.glyphSpan(1);
    const m_h = try rasterizeContours(&face, span.advance_em, decoded_h, 24, false, &alpha);
    try std.testing.expect(m_h.width > 0 and m_h.height > 0);
    try std.testing.expectEqual(@as(i32, 24 * 64), m_h.x_advance_26_6);
    try std.testing.expectEqual(@as(i32, 0), m_h.y_advance_26_6);

    var non_zero: usize = 0;
    for (alpha[0 .. @as(usize, m_h.width) * m_h.height]) |px| {
        if (px > 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 10);

    const m_v = try rasterizeContours(&face, span.advance_em, decoded_v, 24, true, &alpha);
    try std.testing.expectEqual(@as(i32, 0), m_v.x_advance_26_6);
    try std.testing.expectEqual(@as(i32, -24 * 64), m_v.y_advance_26_6);
}

test "TwoTierCache re-rasterizes across size and vertical changes with zero media reads" {
    const CountingSource = struct {
        bytes: []const u8,
        reads: usize = 0,
        fn readFn(ctx: *const anyopaque, offset: u32, out: []u8) Error![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            self.reads += 1;
            const start: usize = @intCast(offset);
            if (start > self.bytes.len or out.len > self.bytes.len - start) return error.OutOfBounds;
            return self.bytes[start .. start + out.len];
        }
    };

    var font_buf: [512]u8 = undefined;
    const font_bytes = buildTestFont(&font_buf, 0x300C, 0xE0100, true);
    var src = CountingSource{ .bytes = font_bytes };
    const reader = SliceReader{ .context = &src, .readFn = CountingSource.readFn };

    const face = try Face.init(reader);
    const family = Family{ .faces = &[_]Face{face} };

    const CacheType = TwoTierCache(8, 64, 16, 64 * 64);
    var cache: CacheType = .{};
    var scratch: [256]u8 = undefined;

    src.reads = 0;
    // 1. Cold render at 20px horizontal: populates both Tier 1 (Outline) and Tier 2 (Bitmap)
    const g20h = try cache.getOrRender(family, 0, 0x300C, 0, 20, false, &scratch);
    try std.testing.expect(g20h.alpha.len > 0);
    const cold_reads = src.reads;
    try std.testing.expect(cold_reads > 0);
    try std.testing.expectEqual(@as(u32, 1), cache.outline_misses);
    try std.testing.expectEqual(@as(u32, 1), cache.bitmap_misses);

    // 2. Repeat exact same request (20px horizontal): hits Tier 2 (Bitmap Cache), 0 media reads
    src.reads = 0;
    _ = try cache.getOrRender(family, 0, 0x300C, 0, 20, false, &scratch);
    try std.testing.expectEqual(@as(usize, 0), src.reads);
    try std.testing.expectEqual(@as(u32, 1), cache.bitmap_misses);

    // 3. Live font size change (20px -> 32px) and vertical toggle (false -> true):
    //    Misses Tier 2 (Bitmap), hits Tier 1 (Outline Cache) -> ZERO media reads!
    src.reads = 0;
    const g32h = try cache.getOrRender(family, 0, 0x300C, 0, 32, false, &scratch);
    const g32v = try cache.getOrRender(family, 0, 0x300C, 0, 32, true, &scratch);
    try std.testing.expectEqual(@as(usize, 0), src.reads);
    try std.testing.expectEqual(@as(u32, 1), cache.outline_misses);
    try std.testing.expectEqual(@as(u32, 3), cache.bitmap_misses);
    try std.testing.expect(g32h.metrics.width >= g20h.metrics.width);
    try std.testing.expectEqual(@as(i32, -32 * 64), g32v.metrics.y_advance_26_6);
}

test "36px em-square scaling retains full coverage without fixed-point overflow" {
    var font_buf: [512]u8 = undefined;
    const font_bytes = buildTestFont(&font_buf, 0x300C, 0xE0100, true);
    const face = try Face.init(SliceReader.fromSlice(&font_bytes));
    const square = [_]CurvePoint{
        .{ .x = 0, .y = 0, .on_curve = true, .contour_end = false },
        .{ .x = 1000, .y = 0, .on_curve = true, .contour_end = false },
        .{ .x = 1000, .y = 1000, .on_curve = true, .contour_end = false },
        .{ .x = 0, .y = 1000, .on_curve = true, .contour_end = true },
    };
    var pixels: [64 * 64]u8 = @splat(0);
    const metrics = try rasterizeContours(&face, 1000, &square, 36, true, &pixels);
    var full: usize = 0;
    for (pixels[0 .. @as(usize, metrics.width) * metrics.height]) |alpha| {
        try std.testing.expect(alpha == 0 or alpha == 255);
        if (alpha == 255) full += 1;
    }
    try std.testing.expectEqual(@as(usize, 36 * 36), full);
    try std.testing.expectEqual(@as(i32, -36 * 64), metrics.y_advance_26_6);
}

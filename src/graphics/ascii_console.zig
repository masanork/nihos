//! RGB565 raster for the diagnostic grid, in the existing landscape buffer.
const std = @import("std");
pub const width: usize = 720;
pub const height: usize = 1280;
pub const cell_width: usize = 15;
pub const cell_height: usize = 30;
pub const Face = enum(u32) { jetbrains = 1, source_code = 2 };
pub const Palette = enum(u32) { neutral, green, blue };
pub const Colors = struct { foreground: u16, accent: u16, background: u16 = 0x1082 };
pub fn colors(palette: Palette) Colors {
    return .{ .foreground = switch (palette) {
        .neutral => 0xe71c,
        .green => 0xa5f5,
        .blue => 0xadd9,
    }, .accent = 0x85b5 };
}
pub const margin_x: usize = 40;
pub const margin_y: usize = 24;
pub const columns: usize = 80;
pub const rows: usize = 22;
pub fn paint(comptime section: ?[]const u8, frame: []u8, stride: usize, grid: anytype) bool {
    return paintFace(section, .jetbrains, frame, stride, grid, .neutral);
}
pub fn paintPalette(comptime section: ?[]const u8, frame: []u8, stride: usize, grid: anytype, palette: Palette) bool {
    return paintFace(section, .jetbrains, frame, stride, grid, palette);
}
pub noinline fn paintFace(comptime section: ?[]const u8, comptime face: Face, frame: []u8, stride: usize, grid: anytype, palette: Palette) bool {
    const T = @TypeOf(grid.*);
    if (T.width > columns or T.height > rows) return false;
    const size = std.math.mul(usize, stride, height) catch return false;
    if (stride < width * 2 or frame.len < size) return false;
    const Font = switch (face) {
        .jetbrains => @import("ascii/jetbrains.zig"),
        .source_code => @import("ascii/source_code.zig"),
    };
    if (Font.cell_width != cell_width or Font.cell_height != cell_height) @compileError("font geometry differs from console cells");
    const Store = if (section) |name| struct {
        const masks linksection(name) = Font.masks.*;
        const glyphs linksection(name) = Font.glyphs;
    } else struct {
        const masks = Font.masks.*;
        const glyphs = Font.glyphs;
    };
    const selected = colors(palette);
    // Physical row padding belongs to the caller and is never touched.
    for (0..height) |y| for (0..width) |x| pixel(frame, stride, x, y, selected.background);
    var normal: [16]u16 = undefined;
    var accent: [16]u16 = undefined;
    for (0..16) |alpha| {
        normal[alpha] = blend(selected.background, selected.foreground, @intCast(alpha));
        accent[alpha] = blend(selected.background, selected.accent, @intCast(alpha));
    }
    for (0..T.height) |row| for (0..T.width) |col| {
        const byte = grid.cells[row * T.width + col];
        const character: usize = if (byte >= 32 and byte <= 126) byte else '?';
        const glyph = Store.glyphs[character - 32];
        var decoded: usize = 0;
        for (Store.masks[glyph.offset..][0..glyph.length]) |run| {
            const alpha: u4 = @truncate(run >> 4);
            const count: usize = @as(usize, run & 15) + 1;
            if (alpha != 0) for (decoded..decoded + count) |index| {
                const lx = margin_x + col * cell_width + index % cell_width;
                const ly = margin_y + row * cell_height + index / cell_width;
                pixel(frame, stride, ly, 1279 - lx, if (row == 0) accent[alpha] else normal[alpha]);
            };
            decoded += count;
        }
    };

    return true;
}
fn blend(background: u16, foreground: u16, alpha: u4) u16 {
    const a: u32 = alpha;
    const b: u32 = background;
    const f: u32 = foreground;
    const r = ((b >> 11) * (15 - a) + (f >> 11) * a + 7) / 15;
    const g = (((b >> 5) & 63) * (15 - a) + ((f >> 5) & 63) * a + 7) / 15;
    const blue = ((b & 31) * (15 - a) + (f & 31) * a + 7) / 15;
    return @intCast((r << 11) | (g << 5) | blue);
}
fn pixel(frame: []u8, stride: usize, x: usize, y: usize, color: u16) void {
    const offset = y * stride + x * 2;
    frame[offset] = @truncate(color);
    frame[offset + 1] = @truncate(color >> 8);
}

test "landscape raster preserves guards and padding and rejects short buffers" {
    const Grid = @import("../console/ascii.zig").Grid;
    var grid = Grid(columns, rows){};
    grid.write("nihos console\r\nMEMORY complete; CORES running\n");
    const stride = width * 2 + 8;
    const size = stride * height;
    const bytes = try std.testing.allocator.alloc(u8, size + 32);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xab);
    const frame = bytes[16..][0..size];
    try std.testing.expect(paint(null, frame, stride, &grid));
    for (bytes[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    for (bytes[size + 16 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    for (0..height) |row| for (frame[row * stride + width * 2 ..][0..8]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xab), byte);
    };
    var small: [32]u8 = @splat(0xab);
    try std.testing.expect(!paint(null, &small, width * 2, &grid));
    try std.testing.expect(!paint(null, &small, std.math.maxInt(usize), &grid));
    for (small) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
    // First glyph starts at logical (40,24), in the keyboard landscape mapping.
    var lit: usize = 0;
    for (1225..1240) |y| for (24..54) |x| {
        const offset = y * stride + x * 2;
        if (frame[offset] == 0xb5 and frame[offset + 1] == 0x85) lit += 1;
    };
    try std.testing.expect(lit > 0);
}

test "both original-size console faces decode exact bounded cells" {
    inline for (.{ @import("ascii/jetbrains.zig"), @import("ascii/source_code.zig") }) |Font| {
        try std.testing.expectEqual(@as(usize, 95), Font.glyphs.len);
        for (Font.glyphs) |glyph| {
            try std.testing.expect(@as(usize, glyph.offset) + glyph.length <= Font.masks.len);
            var decoded: usize = 0;
            for (Font.masks[glyph.offset..][0..glyph.length]) |run| decoded += @as(usize, run & 15) + 1;
            try std.testing.expectEqual(cell_width * cell_height, decoded);
        }
    }
    try std.testing.expectEqual(@as(usize, 1280), margin_x * 2 + columns * cell_width);
    try std.testing.expect(margin_y + rows * cell_height <= 720);
    try std.testing.expectEqual(@as(u16, 0xa5f5), blend(0x1082, 0xa5f5, 15));
    try std.testing.expectEqual(@as(u16, 0x1082), blend(0x1082, 0xa5f5, 0));
}

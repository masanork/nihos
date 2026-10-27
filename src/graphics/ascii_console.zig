//! Rotated console raster with incremental cells and bounded pixel scrolling.
const std = @import("std");
const Grid = @import("../console/ascii.zig").Grid;
pub const width = 720;
pub const height = 1280;
pub const Face = enum(u32) { basic, jetbrains, source_code, basic_light };
pub const default_face: Face = .basic_light;
pub fn Layout(comptime face: Face) type {
    const small = face == .basic or face == .basic_light;
    return struct {
        pub const cell_width: usize = if (small) 16 else 15;
        pub const cell_height: usize = if (small) 16 else 30;
        pub const margin_x: usize = if (small) 16 else 40;
        pub const margin_y: usize = if (small) 16 else 24;
        pub const columns: usize = if (small) 78 else 80;
        pub const rows: usize = if (small) 43 else 22;
    };
}
pub const cell_width = Layout(default_face).cell_width;
pub const cell_height = Layout(default_face).cell_height;
pub const columns = Layout(default_face).columns;
pub const rows = Layout(default_face).rows;
pub const Palette = enum(u32) { neutral, green, blue, forest, matrix };
pub const Colors = struct { foreground: u16, accent: u16, background: u16 = 0x1082 };
pub fn colors(palette: Palette) Colors {
    return .{ .foreground = switch (palette) {
        .neutral => 0xe71c,
        .green => 0xa5f5,
        .blue => 0xadd9,
        .forest => 0x5dcf,
        .matrix => 0x07e8,
    }, .accent = switch (palette) {
        .forest => 0x4d6d,
        .matrix => 0x05a6,
        else => 0x85b5,
    } };
}
pub const Damage = struct {
    left: usize = 1280,
    top: usize = 720,
    right: usize = 0,
    bottom: usize = 0,
    pub fn empty(self: Damage) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }
    pub fn include(self: *Damage, left: usize, top: usize, right: usize, bottom: usize) void {
        self.left = @min(self.left, left);
        self.top = @min(self.top, top);
        self.right = @max(self.right, right);
        self.bottom = @max(self.bottom, bottom);
    }
};
fn valid(frame: []u8, stride: usize) bool {
    const size = std.math.mul(usize, stride, height) catch return false;
    return stride >= width * 2 and frame.len >= size;
}
pub fn paint(comptime section: ?[]const u8, frame: []u8, stride: usize, grid: anytype) bool {
    return paintFace(section, default_face, frame, stride, grid, .neutral);
}
pub fn paintPalette(comptime section: ?[]const u8, frame: []u8, stride: usize, grid: anytype, palette: Palette) bool {
    return paintFace(section, default_face, frame, stride, grid, palette);
}
pub noinline fn paintFace(comptime section: ?[]const u8, comptime face: Face, frame: []u8, stride: usize, grid: anytype, palette: Palette) bool {
    const L = Layout(face);
    const T = @TypeOf(grid.*);
    if (T.width > L.columns or T.height > L.rows or !valid(frame, stride)) return false;
    for (0..height) |y| for (0..width) |x| pixel(frame, stride, x, y, colors(palette).background);
    for (0..T.height) |row| for (0..T.width) |col| cell(section, face, frame, stride, grid.cells[row * T.width + col], row, col, 0, L.cell_height, L.margin_y + row * L.cell_height, palette);
    return true;
}
noinline fn cell(comptime section: ?[]const u8, comptime face: Face, frame: []u8, stride: usize, byte: u8, row: usize, col: usize, clip_top: usize, clip_bottom: usize, destination: usize, palette: Palette) void {
    const L = Layout(face);
    const selected = colors(palette);
    const foreground = if (row == 0) selected.accent else selected.foreground;
    const half = blend(selected.background, foreground, 8);
    const quarter = blend(selected.background, foreground, 4);
    const character: usize = if (byte >= 32 and byte <= 126) byte else '?';
    if (face == .basic or face == .basic_light) {
        const Store = if (section) |name| struct {
            const masks linksection(name) = @embedFile("ascii/basic.bin").*;
        } else struct {
            const masks = @embedFile("ascii/basic.bin").*;
        };
        const bits = Store.masks[(character - 32) * 8 ..][0..8];
        // Traverse contiguous physical rows and write background/ink together.
        // Never expose a cleared cell while its glyph is being rasterized.
        for (0..16) |x| {
            const physical_y = 1279 - (L.margin_x + col * 16 + x);
            const start = physical_y * stride + destination * 2;
            for (clip_top..clip_bottom) |y| {
                const bx: u3 = @intCast(x / 2);
                const by = y / 2;
                var color = selected.background;
                if (bits[by] & (@as(u8, 1) << bx) != 0) {
                    const right = x % 2 == 1 and (bx == 7 or bits[by] & (@as(u8, 1) << @as(u3, @intCast(bx + 1))) == 0);
                    const bottom = y % 2 == 1 and (by == 7 or bits[by + 1] & (@as(u8, 1) << bx) == 0);
                    color = if (face == .basic) foreground else if (right and bottom) quarter else if (right or bottom) half else foreground;
                }
                const offset = start + (y - clip_top) * 2;
                if ((@intFromPtr(frame.ptr) + offset) & 1 == 0) {
                    const output: *u16 = @ptrCast(@alignCast(frame.ptr + offset));
                    output.* = color;
                } else pixel(frame, stride, destination + y - clip_top, physical_y, color);
            }
        }
    } else {
        for (clip_top..clip_bottom) |y| for (0..L.cell_width) |x| pixel(frame, stride, destination + y - clip_top, 1279 - (L.margin_x + col * L.cell_width + x), selected.background);
        const Font = if (face == .jetbrains) @import("ascii/jetbrains.zig") else @import("ascii/source_code.zig");
        const Store = if (section) |name| struct {
            const masks linksection(name) = Font.masks.*;
            const glyphs linksection(name) = Font.glyphs;
        } else struct {
            const masks = Font.masks.*;
            const glyphs = Font.glyphs;
        };
        const glyph = Store.glyphs[character - 32];
        var decoded: usize = 0;
        for (Store.masks[glyph.offset..][0..glyph.length]) |run| {
            const alpha: u4 = @truncate(run >> 4);
            const count = @as(usize, run & 15) + 1;
            if (alpha != 0) for (decoded..decoded + count) |index| {
                const y = index / L.cell_width;
                if (y >= clip_top and y < clip_bottom) pixel(frame, stride, destination + y - clip_top, 1279 - (L.margin_x + col * L.cell_width + index % L.cell_width), blend(selected.background, foreground, alpha));
            };
            decoded += count;
        }
    }
}
pub fn Renderer(comptime section: ?[]const u8, comptime face: Face) type {
    const L = Layout(face);
    const Text = Grid(L.columns, L.rows);
    return struct {
        const Self = @This();
        shown: Text = .{},
        target: Text = .{},
        initialized: bool = false,
        distance: usize = 0,
        advanced: usize = 0,
        quantum: usize = 0,
        damage: Damage = .{},
        full_paints: u32 = 0,
        partial_updates: u32 = 0,
        scrolls: u32 = 0,
        steps: u32 = 0,
        pub fn moving(self: *const Self) bool {
            if (face == .jetbrains or face == .source_code) return false;
            return self.advanced < self.distance;
        }
        pub fn invalidate(self: *Self) void {
            self.initialized = false;
            self.distance = 0;
            self.advanced = 0;
        }
        pub fn takeDamage(self: *Self) Damage {
            const result = self.damage;
            self.damage = .{};
            return result;
        }
        pub fn submit(self: *Self, frame: []u8, stride: usize, next: *const Text, palette: Palette) bool {
            if (!valid(frame, stride) or self.moving()) return false;
            self.target = next.*;
            if (!self.initialized) {
                if (!paintFace(section, face, frame, stride, next, palette)) return false;
                self.shown = next.*;
                self.initialized = true;
                self.full_paints +|= 1;
                self.damage.include(0, 0, 1280, 720);
                return true;
            }
            const header = @import("../console/snapshot.zig").header_rows;
            const body = L.rows - header;
            var shift: usize = 0;
            if ((face == .basic or face == .basic_light) and next.scrolls > self.shown.scrolls) {
                const lines = next.scrolls - self.shown.scrolls;
                // The previous cursor row may have received more characters
                // before scrolling; repaint it with the incoming strip.
                if (lines < body - 1 and std.mem.eql(u8, self.shown.cells[(header + lines) * L.columns .. (L.rows - 1) * L.columns], next.cells[header * L.columns .. (L.rows - lines - 1) * L.columns])) shift = lines;
            }
            const limit = if (shift != 0) header else L.rows;
            for (0..limit) |row| for (0..L.columns) |col| {
                const index = row * L.columns + col;
                if (self.shown.cells[index] == next.cells[index]) continue;
                cell(section, face, frame, stride, next.cells[index], row, col, 0, L.cell_height, L.margin_y + row * L.cell_height, palette);
                self.damage.include(L.margin_x + col * L.cell_width, L.margin_y + row * L.cell_height, L.margin_x + (col + 1) * L.cell_width, L.margin_y + (row + 1) * L.cell_height);
                self.shown.cells[index] = next.cells[index];
            };
            self.partial_updates +|= 1;
            if (shift != 0) {
                self.distance = shift * L.cell_height;
                self.advanced = 0;
                // Complete a line advance in one copy/presentation. Four
                // interpolated copies magnified latency under boot load.
                self.quantum = self.distance;
                self.scrolls +|= 1;
            } else self.shown = next.*;
            return true;
        }
        pub fn finish(self: *Self, frame: []u8, stride: usize, palette: Palette) bool {
            self.quantum = self.distance - self.advanced;
            return self.step(frame, stride, palette);
        }
        pub fn step(self: *Self, frame: []u8, stride: usize, palette: Palette) bool {
            if (!valid(frame, stride)) return false;
            if (!self.moving()) return true;
            const header = @import("../console/snapshot.zig").header_rows;
            const top = L.margin_y + header * L.cell_height;
            const bottom = L.margin_y + L.rows * L.cell_height;
            const count = @min(self.quantum, self.distance - self.advanced);
            // Logical upward motion is a contiguous left shift in each
            // physical scanline. No clearing or repainting of existing glyphs.
            for (1280 - L.margin_x - L.columns * L.cell_width..1280 - L.margin_x) |y| {
                const begin = y * stride + top * 2;
                const length = (bottom - top - count) * 2;
                if ((begin | length | (count * 2)) & 3 == 0 and @intFromPtr(frame.ptr) & 3 == 0) {
                    const dest: [*]u32 = @ptrCast(@alignCast(frame.ptr + begin));
                    const source: [*]const u32 = @ptrCast(@alignCast(frame.ptr + begin + count * 2));
                    var index: usize = 0;
                    while (index + 8 <= length / 4) : (index += 8) {
                        inline for (0..8) |word| dest[index + word] = source[index + word];
                    }
                    while (index < length / 4) : (index += 1) dest[index] = source[index];
                } else std.mem.copyForwards(u8, frame[begin..][0..length], frame[begin + count * 2 ..][0..length]);
            }
            self.advanced += count;
            const band = L.cell_height + self.advanced;
            const source_top = bottom - self.distance - L.cell_height;
            var offset: usize = 0;
            while (offset < band) {
                const source = source_top + offset - L.margin_y;
                const row = source / L.cell_height;
                const within = source % L.cell_height;
                const part = @min(band - offset, L.cell_height - within);
                for (0..L.columns) |col| cell(section, face, frame, stride, self.target.cells[row * L.columns + col], row, col, within, within + part, bottom - band + offset, palette);
                offset += part;
            }
            self.steps +|= 1;
            self.damage.include(L.margin_x, top, L.margin_x + L.columns * L.cell_width, bottom);
            if (!self.moving()) self.shown = self.target;
            return true;
        }
    };
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

test "incremental cells and single-pass scroll equal a fresh raster, with fixed header and guards" {
    inline for (.{ Face.basic, Face.basic_light, Face.jetbrains, Face.source_code }) |face| {
        const L = Layout(face);
        const stride = width * 2 + 8;
        const size = stride * height;
        const bytes = try std.testing.allocator.alloc(u8, size + 32);
        defer std.testing.allocator.free(bytes);
        const reference = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(reference);
        @memset(bytes, 0xab);
        @memset(reference, 0xab);
        const frame = bytes[16..][0..size];
        var text = Grid(L.columns, L.rows){};
        text.write("nihos header\n");
        for (1..7) |_| text.write("fixed header\n");
        try std.testing.expect(text.setScrollTop(7));
        for (7..L.rows - 1) |row| {
            text.write(&.{@intCast('A' + row % 26)});
            text.write(" stable text\n");
        }
        var renderer = Renderer(null, face){};
        try std.testing.expect(renderer.submit(frame, stride, &text, .green));
        _ = renderer.takeDamage();
        // Exercise unfinished last row, wrap, CRLF, and multi-line scroll.
        for ([_][]const u8{ "partial", " tail\r\n", "next line\nthird line\n", "another\n" }) |message| {
            text.write(message);
            try std.testing.expect(renderer.submit(frame, stride, &text, .green));
            var steps: usize = 0;
            while (renderer.moving()) {
                var pending = text;
                pending.write("queued while moving\n");
                try std.testing.expect(!renderer.submit(frame, stride, &pending, .green));
                try std.testing.expect(renderer.step(frame, stride, .green));
                steps += 1;
                try std.testing.expectEqual(@as(usize, 1), steps);
                const damage = renderer.takeDamage();
                try std.testing.expect(damage.top >= L.margin_y + 7 * L.cell_height);
            }
            try std.testing.expect(paintFace(null, face, reference, stride, &text, .green));
            try std.testing.expectEqualSlices(u8, reference, frame);
            for (bytes[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
            for (bytes[size + 16 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
            _ = renderer.takeDamage();
        }
        try std.testing.expectEqual(@as(u32, 1), renderer.full_paints);
        if (face == .basic or face == .basic_light) try std.testing.expect(renderer.scrolls >= 3) else try std.testing.expectEqual(@as(u32, 0), renderer.scrolls);
        try std.testing.expect(!renderer.submit(&.{}, stride, &text, .green));
        try std.testing.expect(!paintFace(null, face, frame, std.math.maxInt(usize), &text, .green));
        try std.testing.expect(renderer.submit(frame, stride, &text, .green));
        try std.testing.expect(renderer.takeDamage().empty());
        renderer.invalidate();
        text.write("failure detail\n");
        try std.testing.expect(renderer.submit(frame, stride, &text, .green));
        try std.testing.expectEqual(@as(u32, 2), renderer.full_paints);
        try std.testing.expect(paintFace(null, face, reference, stride, &text, .green));
        try std.testing.expectEqualSlices(u8, reference, frame);
    }
}

test "thin basic face uses the original masks and large faces decode bounded cells" {
    try std.testing.expectEqual(@as(usize, 760), @embedFile("ascii/basic.bin").len);
    inline for (.{ @import("ascii/jetbrains.zig"), @import("ascii/source_code.zig") }) |Font| {
        try std.testing.expectEqual(@as(usize, 95), Font.glyphs.len);
        for (Font.glyphs) |glyph| {
            try std.testing.expect(@as(usize, glyph.offset) + glyph.length <= Font.masks.len);
            var decoded: usize = 0;
            for (Font.masks[glyph.offset..][0..glyph.length]) |run| decoded += @as(usize, run & 15) + 1;
            try std.testing.expectEqual(@as(usize, 450), decoded);
        }
    }
}

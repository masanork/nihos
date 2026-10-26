//! Fixed ASCII diagnostic grid; not the Unicode document or input model.
const std = @import("std");
pub fn Grid(comptime columns: usize, comptime rows: usize) type {
    if (columns == 0 or rows == 0) @compileError("console geometry must be nonzero");
    return struct {
        const Self = @This();
        pub const width = columns;
        pub const height = rows;
        cells: [columns * rows]u8 = @splat(' '),
        x: usize = 0,
        y: usize = 0,
        wrap_pending: bool = false,
        scroll_top: usize = 0,
        scrolls: usize = 0,
        pub fn setScrollTop(self: *Self, top: usize) bool {
            if (top >= rows) return false;
            self.scroll_top = top;
            return true;
        }
        fn newline(self: *Self) void {
            self.x = 0;
            self.wrap_pending = false;
            if (self.y + 1 < rows) {
                self.y += 1;
                return;
            }
            std.mem.copyForwards(u8, self.cells[self.scroll_top * columns .. columns * (rows - 1)], self.cells[(self.scroll_top + 1) * columns ..]);
            @memset(self.cells[columns * (rows - 1) ..], ' ');
            self.scrolls +|= 1;
        }
        fn glyph(self: *Self, byte: u8) void {
            if (self.wrap_pending) self.newline();
            self.cells[self.y * columns + self.x] = if (byte >= 32 and byte <= 126) byte else '?';
            if (self.x + 1 == columns) self.wrap_pending = true else self.x += 1;
        }
        pub noinline fn write(self: *Self, message: []const u8) void {
            for (message) |byte| switch (byte) {
                '\r' => {
                    self.x = 0;
                    self.wrap_pending = false;
                },
                '\n' => self.newline(),
                '\x08' => {
                    if (self.wrap_pending) self.wrap_pending = false else if (self.x != 0) {
                        self.x -= 1;
                    } else continue;
                    self.cells[self.y * columns + self.x] = ' ';
                },
                '\t' => {
                    const count = 4 - self.x % 4;
                    for (0..count) |_| self.glyph(' ');
                },
                else => self.glyph(byte),
            };
        }
    };
}

test "CRLF at the right edge consumes exactly one new line" {
    var grid = Grid(4, 3){};
    grid.write("abcd\r\nef");
    try std.testing.expectEqualStrings("abcdef      ", &grid.cells);
    try std.testing.expectEqual(@as(usize, 1), grid.y);
}

test "scrolling, backspace, and controls cannot escape the fixed grid" {
    var grid = Grid(4, 2){};
    grid.write("abcdEFGHij\x08K");
    try std.testing.expectEqualStrings("EFGHiK  ", &grid.cells);
    grid.write("\r\t\xff\x1b");
    try std.testing.expectEqualStrings("    ??  ", &grid.cells);
}

test "a scrolling body preserves its header and counts pixel-scroll deltas" {
    var grid = Grid(4, 4){};
    grid.write("HEAD\n");
    try std.testing.expect(grid.setScrollTop(1));
    grid.write("one\ntwo\nthree\n");
    try std.testing.expectEqualStrings("HEADthree       ", &grid.cells);
    try std.testing.expectEqual(@as(usize, 2), grid.scrolls);
    try std.testing.expect(!grid.setScrollTop(4));
    try std.testing.expectEqual(@as(usize, 1), grid.scroll_top);
}

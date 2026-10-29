//! Allocation-free ASCII row edit primitive shared by native UI and fixtures.
const std = @import("std");
pub const Action = union(enum) { insert: u8, left, right, backspace };

/// Edits a bounded row. Cursor movement alone does not request a redraw.
pub fn Editor(comptime Grid: type) type {
    return struct {
        row: usize,
        column: usize,

        pub fn apply(self: *@This(), grid: *Grid, action: Action) bool {
            if (self.row >= Grid.height or self.column > Grid.width) return false;
            const row = grid.cells[self.row * Grid.width ..][0..Grid.width];
            switch (action) {
                .left => {
                    if (self.column != 0) self.column -= 1;
                    return false;
                },
                .right => {
                    if (self.column < Grid.width) self.column += 1;
                    return false;
                },
                .insert => |ch| {
                    if (ch < 32 or ch > 126 or self.column == Grid.width or row[Grid.width - 1] != ' ') return false;
                    std.mem.copyBackwards(u8, row[self.column + 1 ..], row[self.column .. Grid.width - 1]);
                    row[self.column] = ch;
                    self.column += 1;
                    return true;
                },
                .backspace => {
                    if (self.column == 0) return false;
                    self.column -= 1;
                    std.mem.copyForwards(u8, row[self.column .. Grid.width - 1], row[self.column + 1 ..]);
                    row[Grid.width - 1] = ' ';
                    return true;
                },
            }
        }
    };
}

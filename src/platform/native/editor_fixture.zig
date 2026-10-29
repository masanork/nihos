//! Emulator-only bounded ASCII edit scenario; not an editor, document model or input ABI.
const std = @import("std");
const console = @import("text_console");

pub const Action = union(enum) { insert: u8, left, right, backspace };

/// Fixture adapter for Tab5 HID press events. Layout is the existing ASCII
/// shell mapping. Modified arrows are ignored because selection is unsupported.
pub const Keyboard = struct {
    decoder: console.session.input.Hid = .{},

    pub fn press(self: *Keyboard, event: console.keyboard.Event) ?Action {
        if (event.usage == 0x4f or event.usage == 0x50) {
            if (event.modifiers != 0) return null;
            return if (event.usage == 0x4f) .right else .left;
        }
        const key = self.decoder.feed(event.modifiers, event.usage) orelse return null;
        return switch (key) {
            .text => |byte| .{ .insert = byte },
            .backspace => .backspace,
            else => null,
        };
    }
};

/// Edits one row in an existing host-owned console grid. Cursor movement alone
/// does not request a redraw because this fixture does not render a caret.
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

test "bounded row edits and cursor moves preserve other rows" {
    const Grid = console.Grid(8, 2);
    var grid: Grid = .{};
    @memcpy(grid.cells[0..8], "HEADER  ");
    @memcpy(grid.cells[8..16], "abc     ");
    var editor = Editor(Grid){ .row = 1, .column = 0 };
    try std.testing.expect(!editor.apply(&grid, .left));
    try std.testing.expect(!editor.apply(&grid, .backspace));
    try std.testing.expect(editor.apply(&grid, .{ .insert = '>' }));
    try std.testing.expect(!editor.apply(&grid, .right));
    try std.testing.expect(editor.apply(&grid, .{ .insert = '#' }));
    try std.testing.expect(editor.apply(&grid, .backspace));
    try std.testing.expect(!editor.apply(&grid, .left));
    try std.testing.expect(editor.apply(&grid, .{ .insert = ' ' }));
    try std.testing.expectEqualStrings("HEADER  > abc   ", &grid.cells);
    try std.testing.expect(!editor.apply(&grid, .{ .insert = 0 }));
    @memset(grid.cells[8..16], 'X');
    try std.testing.expect(!editor.apply(&grid, .{ .insert = 'Z' }));
    try std.testing.expectEqualStrings("HEADER  XXXXXXXX", &grid.cells);
    @memset(grid.cells[8..16], ' ');
    editor.column = Grid.width - 1;
    try std.testing.expect(editor.apply(&grid, .{ .insert = 'Z' }));
    try std.testing.expectEqual(@as(usize, Grid.width), editor.column);
    try std.testing.expect(editor.apply(&grid, .backspace));
    try std.testing.expectEqualStrings("HEADER          ", &grid.cells);
}

test "each incremental edit equals a full console repaint" {
    const L = console.raster.Layout(.basic_light);
    const Grid = console.Grid(L.columns, L.rows);
    const Renderer = console.raster.Renderer(null, .basic_light);
    const size = 720 * 1280 * 2;
    const actual = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(actual);
    const expected = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(expected);
    var grid: Grid = .{};
    grid.write("HEADER\nExample text");
    var renderer: Renderer = .{};
    try std.testing.expect(renderer.submit(actual, 1440, &grid, .green));
    var editor = Editor(Grid){ .row = 1, .column = 0 };
    const actions = [_]Action{ .{ .insert = '>' }, .right, .{ .insert = '#' }, .backspace, .left, .{ .insert = ' ' } };
    for (actions) |action| {
        if (!editor.apply(&grid, action)) continue;
        try std.testing.expect(renderer.submit(actual, 1440, &grid, .green));
        try std.testing.expect(console.raster.paintPalette(null, expected, 1440, &grid, .green));
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    try std.testing.expectEqual(@as(u32, 4), renderer.partial_updates);
}

test "synthetic Tab5 HID presses decode text, arrows and deletion without control leaks" {
    var keyboard = Keyboard{};
    const Event = console.keyboard.Event;
    try std.testing.expectEqual(Action{ .insert = '>' }, keyboard.press(Event{ .modifiers = 2, .usage = 0x37 }).?);
    try std.testing.expectEqual(Action.right, keyboard.press(Event{ .modifiers = 0, .usage = 0x4f }).?);
    try std.testing.expectEqual(Action.left, keyboard.press(Event{ .modifiers = 0, .usage = 0x50 }).?);
    try std.testing.expectEqual(Action.backspace, keyboard.press(Event{ .modifiers = 0, .usage = 0x2a }).?);
    try std.testing.expect(keyboard.press(Event{ .modifiers = 2, .usage = 0x50 }) == null);
    try std.testing.expect(keyboard.press(Event{ .modifiers = 1, .usage = 0x06 }) == null);
    try std.testing.expect(keyboard.press(Event{ .modifiers = 4, .usage = 0x04 }) == null);
    try std.testing.expect(keyboard.press(Event{ .modifiers = 0, .usage = 0 }) == null);
    try std.testing.expect(keyboard.press(Event{ .modifiers = 0, .usage = 0x39 }) == null);
    try std.testing.expectEqual(Action{ .insert = 'A' }, keyboard.press(Event{ .modifiers = 0, .usage = 4 }).?);
    try std.testing.expectEqual(Action{ .insert = 'a' }, keyboard.press(Event{ .modifiers = 2, .usage = 4 }).?);
}

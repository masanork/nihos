//! Emulator-only bounded ASCII edit scenario; not an editor, document model or input ABI.
const std = @import("std");
const console = @import("text_console");

pub const Action = console.line_edit.Action;
pub const Editor = console.line_edit.Editor;

/// Fixture adapter for Tab5 HID press events. Layout is the existing ASCII
/// shell mapping. Modified arrows are ignored because selection is unsupported.
pub const Keyboard = struct {
    decoder: console.session.input.Hid = .{},

    pub fn press(self: *Keyboard, event: console.keyboard.Event) ?Action {
        const key = self.decoder.feed(event.modifiers, event.usage) orelse return null;
        return switch (key) {
            .text => |byte| .{ .insert = byte },
            .backspace => .backspace,
            .left => .left,
            .right => .right,
            else => null,
        };
    }
};

/// Deterministic I2C register model for the Tab5 keyboard driver, used only by
/// the fixture. It supplies FIFO bytes; it is not a physical bus simulation.
pub const InputBus = struct {
    events: []const console.keyboard.Event,
    next: usize = 0,

    pub fn transfer(self: *InputBus, address: u8, write: []const u8, read: []u8) error{InvalidTransfer}!void {
        if (address != 0x6d or write.len != 1) return error.InvalidTransfer;
        switch (write[0]) {
            0xfe, 0x10 => {
                if (read.len != 1) return error.InvalidTransfer;
                read[0] = 1;
            },
            0xff => {
                if (read.len != 1) return error.InvalidTransfer;
                read[0] = 0x6d;
            },
            0x02 => {
                if (read.len != 1 or self.events.len - self.next > 32) return error.InvalidTransfer;
                read[0] = @intCast(self.events.len - self.next);
            },
            0x30 => {
                if (read.len != 2 or self.next >= self.events.len) return error.InvalidTransfer;
                const event = self.events[self.next];
                self.next += 1;
                read[0] = event.modifiers;
                read[1] = event.usage;
            },
            else => return error.InvalidTransfer,
        }
    }
};

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

test "keyboard driver drains bounded model FIFO and filters releases and malformed usages" {
    const Event = console.keyboard.Event;
    const events = [_]Event{
        .{ .modifiers = 0, .usage = 0 },
        .{ .modifiers = 0, .usage = 1 },
        .{ .modifiers = 2, .usage = 0x37 },
        .{ .modifiers = 0, .usage = 0x4f },
        .{ .modifiers = 0, .usage = 0x2a },
    };
    var bus = InputBus{ .events = &events };
    var driver = console.keyboard.Keyboard(InputBus){ .bus = &bus };
    try std.testing.expect(try driver.begin());
    var output: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), try driver.poll(&output));
    try std.testing.expectEqual(@as(u8, 0x37), output[0].usage);
    try std.testing.expectEqual(@as(u8, 0x4f), output[1].usage);
    try std.testing.expectEqual(@as(usize, 1), try driver.poll(&output));
    try std.testing.expectEqual(@as(u8, 0x2a), output[0].usage);
    try std.testing.expectEqual(@as(u32, 1), driver.report.releases);
    try std.testing.expectEqual(@as(u32, 1), driver.report.malformed);
    try std.testing.expectEqual(@as(u32, 3), driver.report.presses);
}

test "Tab5 keyboard driver events reach the native launcher editor" {
    const Event = console.keyboard.Event;
    const events = [_]Event{
        .{ .modifiers = 0, .usage = 0x22 }, // 5
        .{ .modifiers = 0, .usage = 0x28 }, // Enter
        .{ .modifiers = 0, .usage = 0x0b }, // h
        .{ .modifiers = 0, .usage = 0 }, // release
        .{ .modifiers = 0, .usage = 0x0c }, // i
        .{ .modifiers = 0, .usage = 0x50 }, // left
        .{ .modifiers = 2, .usage = 0x1e }, // !
    };
    const Sink = struct {
        pub fn write(_: *@This(), _: []const u8) void {}
    };
    var sink: Sink = .{};
    var session: console.session.Model = .{};
    session.begin(&sink);
    var decoder: console.session.input.Hid = .{};
    var bus = InputBus{ .events = &events };
    var driver = console.keyboard.Keyboard(InputBus){ .bus = &bus };
    try std.testing.expect(try driver.begin());
    while (bus.next < events.len) {
        var batch: [4]Event = undefined;
        const count = try driver.poll(&batch);
        for (batch[0..count]) |event| {
            const key = decoder.feed(event.modifiers, event.usage) orelse continue;
            _ = session.handle(key, &sink);
        }
    }
    try std.testing.expectEqual(console.session.View.editor, session.view);
    try std.testing.expectEqualStrings("h!i", session.editor_grid.cells[0..3]);
    try std.testing.expectEqual(@as(u32, 1), driver.report.releases);
}

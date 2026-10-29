//! Emulator-only interactive bounded ASCII editor rendering probe.
const std = @import("std");
const console = @import("text_console");
const fixture = @import("editor_fixture.zig");
const face: console.raster.Face = .basic_light;
const Layout = console.raster.Layout(face);
const Text = console.Grid(Layout.columns, Layout.rows);
const Renderer = console.raster.Renderer(null, face);
pub const Result = enum { ignored, unchanged, moved, edited };

/// Owned in the emulator's reserved scratch memory; frame ownership stays with host.
pub const Live = struct {
    text: Text = .{},
    visible: Text = .{},
    renderer: Renderer = .{},
    editor: fixture.Editor(Text) = .{ .row = 1, .column = 0 },
    keyboard: fixture.Keyboard = .{},

    pub fn start(self: *Live, frame: []u8) bool {
        self.* = .{};
        self.text.write("EDITOR DEMO\n\nASCII ONLY - NO SAVE");
        return self.render(frame);
    }
    fn render(self: *Live, frame: []u8) bool {
        self.visible = self.text;
        // A visible cell cursor deliberately covers the underlying character;
        // it is restored when the cursor moves because the document is separate.
        const col = @min(self.editor.column, Text.width - 1);
        self.visible.cells[self.editor.row * Text.width + col] = '|';
        return self.renderer.submit(frame, 1440, &self.visible, .green);
    }
    pub fn press(self: *Live, frame: []u8, event: console.keyboard.Event) error{InvalidFrame}!Result {
        const action = self.keyboard.press(event) orelse return .ignored;
        const previous = self.editor.column;
        const changed = self.editor.apply(&self.text, action);
        if (!changed and previous == self.editor.column) return .unchanged;
        if (!self.render(frame)) return error.InvalidFrame;
        return if (changed) .edited else .moved;
    }
};

test "live edit keeps document separate from visible caret and renders each state" {
    const size = 720 * 1280 * 2;
    const actual = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(actual);
    const reference = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(reference);
    var live: Live = .{};
    try std.testing.expect(live.start(actual));
    const events = [_]console.keyboard.Event{
        .{ .modifiers = 0, .usage = 0x0b }, // h
        .{ .modifiers = 0, .usage = 0x0c }, // i
        .{ .modifiers = 0, .usage = 0x50 }, // left
        .{ .modifiers = 2, .usage = 0x1e }, // !
        .{ .modifiers = 0, .usage = 0x2a }, // backspace
    };
    for (events) |event| {
        _ = try live.press(actual, event);
        try std.testing.expect(console.raster.paintFace(null, face, reference, 1440, &live.visible, .green));
        try std.testing.expectEqualSlices(u8, reference, actual);
    }
    try std.testing.expectEqualStrings("hi", live.text.cells[Text.width..][0..2]);
    try std.testing.expectEqual(@as(usize, 1), live.editor.column);
    try std.testing.expectEqual(@as(u8, '|'), live.visible.cells[Text.width + 1]);
    try std.testing.expectEqual(Result.ignored, try live.press(actual, .{ .modifiers = 2, .usage = 0x50 }));
}

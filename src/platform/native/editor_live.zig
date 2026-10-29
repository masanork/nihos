//! Emulator-only interactive bounded ASCII editor rendering probe.
const std = @import("std");
const console = @import("text_console");
const fixture = @import("editor_fixture.zig");
const face: console.raster.Face = .jetbrains;
const Layout = console.raster.Layout(face);
const Text = console.Grid(Layout.columns, Layout.rows);
pub const Result = enum { ignored, unchanged, moved, edited };

/// Owned in the emulator's reserved scratch memory; frame ownership stays with host.
pub fn Live(comptime section: ?[]const u8) type {
    const Renderer = console.raster.Renderer(section, face);
    return struct {
        text: Text = .{},
        visible: Text = .{},
        renderer: Renderer = .{},
        editor: fixture.Editor(Text) = .{ .row = 1, .column = 0 },
        keyboard: fixture.Keyboard = .{},
        length: usize = 0,

        const Self = @This();
        pub fn start(self: *Self, frame: []u8) bool {
            self.* = .{};
            self.text.write("EDITOR DEMO\n\nASCII ONLY - HOST FILES");
            return self.render(frame);
        }
        fn render(self: *Self, frame: []u8) bool {
            self.visible = self.text;
            // A visible cell cursor deliberately covers the underlying character;
            // it is restored when the cursor moves because the document is separate.
            const col = @min(self.editor.column, Text.width - 1);
            self.visible.cells[self.editor.row * Text.width + col] = '|';
            return self.renderer.submit(frame, 1440, &self.visible, .green);
        }
        /// A bounded ASCII document, with trailing spaces preserved.
        pub fn document(self: *const Self) []const u8 {
            return self.text.cells[self.editor.row * Text.width ..][0..self.length];
        }
        /// Reject invalid data before mutating the document.
        pub fn load(self: *Self, frame: []u8, content: []const u8) bool {
            if (frame.len < 720 * 1280 * 2 or content.len > Text.width) return false;
            for (content) |byte| if (byte < 32 or byte > 126) {
                return false;
            };
            const row = self.text.cells[self.editor.row * Text.width ..][0..Text.width];
            @memset(row, ' ');
            @memcpy(row[0..content.len], content);
            self.length = content.len;
            self.editor.column = content.len;
            return self.render(frame);
        }
        pub fn press(self: *Self, frame: []u8, event: console.keyboard.Event) error{InvalidFrame}!Result {
            const action = self.keyboard.press(event) orelse return .ignored;
            const previous = self.editor.column;
            if (action == .insert and self.length == Text.width) return .unchanged;
            const changed = self.editor.apply(&self.text, action);
            if (changed) switch (action) {
                .insert => self.length = @max(self.length, previous) + 1,
                .backspace => if (previous <= self.length) {
                    self.length -= 1;
                },
                else => {},
            };
            if (!changed and previous == self.editor.column) return .unchanged;
            if (!self.render(frame)) return error.InvalidFrame;
            return if (changed) .edited else .moved;
        }
    };
}

test "live edit keeps document separate from visible caret and renders each state" {
    const size = 720 * 1280 * 2;
    const actual = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(actual);
    const reference = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(reference);
    var live: Live(null) = .{};
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
    try std.testing.expect(live.load(actual, "xy  "));
    try std.testing.expectEqualStrings("xy  ", live.document());
    try std.testing.expect(!live.load(actual, "bad\n"));
    try std.testing.expectEqualStrings("xy  ", live.document());
    try std.testing.expect(live.load(actual, ""));
    try std.testing.expectEqualStrings("", live.document());
    const full: [Text.width]u8 = @splat(' ');
    try std.testing.expect(live.load(actual, &full));
    try std.testing.expectEqual(Result.unchanged, try live.press(actual, .{ .modifiers = 0, .usage = 4 }));
    try std.testing.expectEqualSlices(u8, &full, live.document());
}

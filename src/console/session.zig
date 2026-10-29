//! Bounded post-boot launcher and ASCII shell, independent of board/allocator.
const std = @import("std");
pub const input = @import("session_input.zig");
const Journal = @import("../diagnostics/boot_journal.zig").Journal;
pub const View = enum(u8) { launcher, shell, logs, editor };
pub const Command = enum { shell, help, clear, log, mem, tasks, launcher, exit, editor };
const Entry = struct { command: Command, name: []const u8, help: []const u8 };
pub const commands = [_]Entry{
    .{ .command = .shell, .name = "shell", .help = "Open the command prompt" },
    .{ .command = .help, .name = "help", .help = "List commands" },
    .{ .command = .clear, .name = "clear", .help = "Clear shell output" },
    .{ .command = .log, .name = "log", .help = "Show retained boot log" },
    .{ .command = .mem, .name = "mem", .help = "Show CPU0 memory usage" },
    .{ .command = .tasks, .name = "tasks", .help = "Show published runtime counters" },
    .{ .command = .launcher, .name = "launcher", .help = "Return to the launcher" },
    .{ .command = .exit, .name = "exit", .help = "Return to the launcher" },
    .{ .command = .editor, .name = "edit", .help = "Open the unsaved ASCII editor" },
};
pub const menu = [_]struct { label: []const u8, command: Command }{
    .{ .label = "Shell", .command = .shell },
    .{ .label = "Boot log", .command = .log },
    .{ .label = "Memory", .command = .mem },
    .{ .label = "Tasks", .command = .tasks },
    .{ .label = "Editor (not saved)", .command = .editor },
};
const EditGrid = @import("ascii.zig").Grid(64, 1);
const row_edit = @import("line_edit.zig");
pub const Model = struct {
    view: View = .launcher,
    selected: usize = 0,
    revision: u32 = 0,
    line: [64]u8 = @splat(0),
    length: usize = 0,
    output: Journal(2048) = .{},
    editor_grid: EditGrid = .{},
    editor_cursor: row_edit.Editor(EditGrid) = .{ .row = 0, .column = 0 },

    pub fn begin(self: *Model, sink: anytype) void {
        self.view = .launcher;
        self.length = 0;
        self.revision +%= 1;
        self.announce(sink);
    }
    fn announce(self: *const Model, sink: anytype) void {
        sink.write("\r\nnihos launcher\r\n");
        for (menu, 0..) |entry, index| {
            sink.write(if (index == self.selected) "> " else "  ");
            sink.write(&.{ @as(u8, @intCast(index)) + '1', '.', ' ' });
            sink.write(entry.label);
            sink.write("\r\n");
        }
        sink.write("Up/Down or 1-5: select | Enter: open | Esc: shell\r\n");
    }
    pub fn write(self: *Model, sink: anytype, bytes: []const u8) void {
        self.output.append(bytes);
        sink.write(bytes);
        self.revision +%= 1;
    }
    pub fn number(self: *Model, sink: anytype, value: u32) void {
        var buffer: [10]u8 = undefined;
        var rest = value;
        var start: usize = buffer.len;
        while (true) {
            start -= 1;
            buffer[start] = @as(u8, @intCast(rest % 10)) + '0';
            rest /= 10;
            if (rest == 0) break;
        }
        self.write(sink, buffer[start..]);
    }
    pub fn prompt(self: *const Model, sink: anytype) void {
        if (self.view == .shell) sink.write("nihos> ");
    }
    /// Call after service results and diagnostic records, so the editable
    /// prompt is always the last serial output for this key event.
    pub fn finishInput(self: *const Model, key: input.Key, before: View, sink: anytype) void {
        if (self.view == .shell and (before != .shell or key == .enter or key == .escape or key == .cancel or key == .clear)) {
            self.prompt(sink);
            if (key == .clear) sink.write(self.line[0..self.length]);
        }
    }
    fn clearOutput(self: *Model) void {
        self.output.head = 0;
        self.output.length = 0;
        self.output.dropped = 0;
    }
    fn shell(self: *Model, sink: anytype) void {
        if (self.view != .shell) self.write(sink, "\r\nnihos shell | help: commands | exit: launcher\r\n");
        self.view = .shell;
        self.length = 0;
    }
    fn execute(self: *Model, command: Command, sink: anytype) ?Command {
        switch (command) {
            .shell => self.shell(sink),
            .help => for (commands) |entry| {
                self.write(sink, entry.name);
                self.write(sink, " - ");
                self.write(sink, entry.help);
                self.write(sink, "\r\n");
            },
            .clear => {
                self.clearOutput();
                sink.write("\x1b[2J\x1b[H");
            },
            .log => {
                self.view = .logs;
                sink.write("\r\nBoot log | Esc: launcher\r\n");
            },
            .mem, .tasks => {
                self.shell(sink);
                return command;
            },
            .editor => {
                self.view = .editor;
                sink.write("\r\nEditor | ASCII | not saved | Esc: launcher\r\n");
            },
            .launcher, .exit => self.begin(sink),
        }
        return null;
    }
    /// mem/tasks return a bounded service request. Caller writes its result
    /// and any telemetry before emitting the serial prompt.
    pub fn handle(self: *Model, key: input.Key, sink: anytype) ?Command {
        if (self.view != .editor and (key == .left or key == .right)) return null;
        self.revision +%= 1;
        switch (self.view) {
            .launcher => {
                switch (key) {
                    .up => {
                        self.selected = if (self.selected == 0) menu.len - 1 else self.selected - 1;
                        self.announce(sink);
                    },
                    .down => {
                        self.selected = (self.selected + 1) % menu.len;
                        self.announce(sink);
                    },
                    .text => |byte| if (byte >= '1' and byte <= '5') {
                        self.selected = byte - '1';
                        self.announce(sink);
                    },
                    .enter, .escape => {
                        return self.execute(if (key == .escape) .shell else menu[self.selected].command, sink);
                    },
                    else => {},
                }
            },
            .logs => switch (key) {
                .escape, .cancel, .eof => self.begin(sink),
                else => {},
            },
            .editor => {
                const action: ?row_edit.Action = switch (key) {
                    .text => |byte| .{ .insert = byte },
                    .backspace => .backspace,
                    .left => .left,
                    .right => .right,
                    .escape, .cancel => {
                        self.begin(sink);
                        return null;
                    },
                    else => null,
                };
                if (action) |value| _ = self.editor_cursor.apply(&self.editor_grid, value);
            },
            .shell => switch (key) {
                .text => |byte| if (byte >= 32 and byte <= 126 and self.length < self.line.len) {
                    self.line[self.length] = byte;
                    self.length += 1;
                    sink.write(&.{byte});
                },
                .backspace => if (self.length > 0) {
                    self.length -= 1;
                    sink.write("\x08 \x08");
                },
                .escape, .cancel => {
                    self.length = 0;
                    self.write(sink, "^C\r\n");
                },
                .clear => {
                    // Keep an in-progress command while clearing the screen.
                    self.clearOutput();
                    sink.write("\x1b[2J\x1b[H");
                },
                .eof => if (self.length == 0) self.begin(sink),
                .enter => {
                    self.output.append("nihos> ");
                    self.output.append(self.line[0..self.length]);
                    self.output.append("\r\n");
                    sink.write("\r\n");
                    const line = std.mem.trim(u8, self.line[0..self.length], " \t");
                    self.length = 0;
                    var request: ?Command = null;
                    if (line.len != 0) {
                        var found = false;
                        for (commands) |entry| if (std.mem.eql(u8, line, entry.name)) {
                            request = self.execute(entry.command, sink);
                            found = true;
                            break;
                        };
                        if (!found) self.write(sink, "Unknown command. Type help.\r\n");
                    }
                    return request;
                },
                else => {},
            },
        }
        return null;
    }
    pub fn render(self: *const Model, grid: anytype) void {
        const header = @import("snapshot.zig").header_rows;
        @memset(&grid.cells, ' ');
        grid.x = 0;
        grid.y = 0;
        grid.wrap_pending = false;
        grid.scrolls = 0;
        _ = grid.setScrollTop(header);
        if (self.view == .editor) {
            grid.write("nihos / editor\n\nASCII | arrows | Backspace | Esc: launcher | NOT SAVED\n");
            while (grid.y < header) grid.write("\n");
            const position = self.editor_cursor.column;
            grid.write(self.editor_grid.cells[0..position]);
            grid.write("|");
            grid.write(self.editor_grid.cells[position..]);
            return;
        }
        grid.write(if (self.view == .launcher) "nihos / launcher\n\n" else "nihos / shell\n\n");
        grid.write(if (self.view == .launcher) "Up/Down or 1-5: select | Enter: open | Esc: shell\n" else "help: commands | exit: launcher | Ctrl-C: cancel | ASCII input\n");
        if (self.view == .shell and self.output.dropped != 0) grid.write("[older shell output discarded]\n");
        while (grid.y < header) grid.write("\n");
        if (self.view == .launcher) {
            for (menu, 0..) |entry, index| {
                grid.write(if (index == self.selected) "  > " else "    ");
                grid.write(&.{ @as(u8, @intCast(index)) + '1', '.', ' ' });
                grid.write(entry.label);
                grid.write("\n\n");
            }
        } else {
            for (self.output.spans()) |part| grid.write(part);
            grid.write("nihos> ");
            grid.write(self.line[0..self.length]);
            grid.write("_");
        }
    }
};

const Sink = struct {
    bytes: Journal(8192) = .{},
    pub fn write(self: *Sink, bytes: []const u8) void {
        self.bytes.append(bytes);
    }
};
fn typeLine(model: *Model, sink: *Sink, text: []const u8) ?Command {
    for (text) |byte| _ = model.handle(.{ .text = byte }, sink);
    return model.handle(.enter, sink);
}
test "launcher, shell and log round trips share the command registry" {
    var model = Model{};
    var sink = Sink{};
    model.begin(&sink);
    _ = model.handle(.escape, &sink);
    try std.testing.expectEqual(View.shell, model.view);
    _ = typeLine(&model, &sink, "help");
    var grid = @import("ascii.zig").Grid(78, 43){};
    model.render(&grid);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "exit - Return") != null);
    _ = typeLine(&model, &sink, "exit");
    try std.testing.expectEqual(View.launcher, model.view);
    _ = model.handle(.down, &sink);
    _ = model.handle(.enter, &sink);
    try std.testing.expectEqual(View.logs, model.view);
    _ = model.handle(.escape, &sink);
    _ = model.handle(.down, &sink);
    try std.testing.expectEqual(Command.mem, model.handle(.enter, &sink).?);
    try std.testing.expectEqual(View.shell, model.view);
    try std.testing.expectEqual(Command.tasks, typeLine(&model, &sink, "tasks").?);
    _ = typeLine(&model, &sink, "launcher");
    try std.testing.expectEqual(View.launcher, model.view);
}
test "bounded editing, unknown commands, cancellation and clear retain a usable prompt" {
    var model = Model{};
    var sink = Sink{};
    _ = model.handle(.escape, &sink);
    for (0..1000) |_| _ = model.handle(.{ .text = 'a' }, &sink);
    try std.testing.expectEqual(model.line.len, model.length);
    _ = model.handle(.cancel, &sink);
    try std.testing.expectEqual(@as(usize, 0), model.length);
    for ("helpx") |byte| _ = model.handle(.{ .text = byte }, &sink);
    _ = model.handle(.backspace, &sink);
    _ = model.handle(.enter, &sink);
    _ = typeLine(&model, &sink, "exit now");
    try std.testing.expectEqual(View.shell, model.view);
    for (0..30) |_| _ = typeLine(&model, &sink, "help");
    try std.testing.expect(model.output.dropped > 0);
    _ = typeLine(&model, &sink, "clear");
    try std.testing.expectEqual(@as(usize, 0), model.output.length);
    var grid = @import("ascii.zig").Grid(80, 22){};
    model.render(&grid);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "nihos> _") != null);
    _ = model.handle(.eof, &sink);
    try std.testing.expectEqual(View.launcher, model.view);
}
test "serial navigation and CRLF enter one shell command" {
    var model = Model{};
    var serial = input.Serial{};
    var sink = Sink{};
    for ("\x1b[B\x1b[B\r\n") |byte| if (serial.feed(byte, 0)) |key| {
        if (model.handle(key, &sink)) |command| try std.testing.expectEqual(Command.mem, command);
    };
    try std.testing.expectEqual(View.shell, model.view);
    for ("exit\r\n") |byte| {
        if (serial.feed(byte, 1)) |key| _ = model.handle(key, &sink);
    }
    try std.testing.expectEqual(View.launcher, model.view);
}

test "physical HID typing, cancellation and both display geometries stay usable" {
    var model = Model{};
    var hid = input.Hid{};
    var sink = Sink{};
    model.begin(&sink);
    _ = model.handle(hid.feed(0, 0x29).?, &sink);
    _ = model.handle(hid.feed(0, 4).?, &sink);
    _ = model.handle(hid.feed(1, 7).?, &sink); // Ctrl-D with input does not exit.
    try std.testing.expectEqual(View.shell, model.view);
    _ = model.handle(hid.feed(1, 6).?, &sink);
    for ([_]u8{ 8, 27, 12, 23, 0x28 }) |usage| _ = model.handle(hid.feed(0, usage).?, &sink);
    try std.testing.expectEqual(View.launcher, model.view);
    _ = model.handle(.up, &sink); // wrap to Editor
    _ = model.handle(.up, &sink); // move to Tasks
    var small = @import("ascii.zig").Grid(78, 43){};
    var large = @import("ascii.zig").Grid(80, 22){};
    model.render(&small);
    model.render(&large);
    try std.testing.expect(std.mem.indexOf(u8, &small.cells, "> 4. Tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, &large.cells, "> 4. Tasks") != null);
    try std.testing.expectEqual(Command.tasks, model.handle(.enter, &sink).?);
    model.write(&sink, "runtime report\r\n");
    model.prompt(&sink);
    model.render(&large);
    try std.testing.expect(std.mem.indexOf(u8, &large.cells, "runtime report") != null);
    try std.testing.expect(std.mem.indexOf(u8, &large.cells, "nihos> _") != null);
}

test "serial prompt follows view telemetry and Ctrl-L restores partial input" {
    var model = Model{};
    var sink = Sink{};
    const before = model.view;
    _ = model.handle(.escape, &sink);
    sink.write("VIEW EVENT\r\n");
    model.finishInput(.escape, before, &sink);
    try std.testing.expect(std.mem.endsWith(u8, sink.bytes.spans()[0], "VIEW EVENT\r\nnihos> "));
    for ("hel") |byte| _ = model.handle(.{ .text = byte }, &sink);
    _ = model.handle(.clear, &sink);
    model.finishInput(.clear, .shell, &sink);
    try std.testing.expect(std.mem.endsWith(u8, sink.bytes.spans()[0], "\x1b[2J\x1b[Hnihos> hel"));
    try std.testing.expectEqual(@as(usize, 3), model.length);
}

test "launcher editor accepts real HID decoder events and preserves unsaved text on return" {
    var model: Model = .{};
    var sink: Sink = .{};
    var hid = input.Hid{};
    model.begin(&sink);
    _ = model.handle(hid.feed(0, 0x22).?, &sink); // 5
    _ = model.handle(hid.feed(0, 0x28).?, &sink); // Enter
    try std.testing.expectEqual(View.editor, model.view);
    _ = model.handle(hid.feed(0, 0x0b).?, &sink); // h
    _ = model.handle(hid.feed(0, 0x0c).?, &sink); // i
    _ = model.handle(hid.feed(0, 0x50).?, &sink); // left
    _ = model.handle(hid.feed(2, 0x1e).?, &sink); // !
    try std.testing.expectEqualStrings("h!i", model.editor_grid.cells[0..3]);
    try std.testing.expectEqual(@as(usize, 2), model.editor_cursor.column);
    try std.testing.expect(hid.feed(2, 0x50) == null); // selection not implemented
    const Grid = @import("ascii.zig").Grid(78, 43);
    var grid: Grid = .{};
    model.render(&grid);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "h!|i") != null);
    _ = model.handle(.escape, &sink);
    try std.testing.expectEqual(View.launcher, model.view);
    _ = model.handle(.{ .text = '5' }, &sink);
    _ = model.handle(.enter, &sink);
    try std.testing.expectEqual(View.editor, model.view);
    try std.testing.expectEqualStrings("h!i", model.editor_grid.cells[0..3]);
}

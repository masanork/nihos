//! RAM workspace over the shared xy Document. The first native presentation
//! uses the existing fixed-cell raster; non-ASCII clusters are shown as '?'.
//! Text remains UTF-8. No shell dispatch, persistence or Scheme VM is implied.
const std = @import("std");
pub const input = @import("../console/session_input.zig");
pub const document = @import("document.zig");
// Immutable presentation text follows the existing diagnostic font placement;
// host targets retain their ordinary read-only segment.
const help_text linksection(if (@import("builtin").os.tag == .freestanding) ".flash.rodata.display" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata") = "Type directly into *scratch*.\n\nArrows: move   Backspace: delete before\nCtrl-D: delete after   Ctrl-Z: undo\nEsc: minibuffer   Ctrl-C: cancel\n\nMinibuffer: help, undo, forget-undo\nSystem buffers: log, mem, tasks\n\nRAM only: this buffer is not saved.\n\nEnter or Esc: return to *scratch*".*;
pub const Doc = document.Document(4096, 256, 2048, 1, 64);
pub const system = @import("system_buffer.zig");
pub const Mode = enum { edit, command, help, system };
pub const Status = enum { none, buffer_full, undo_full, invalid_input, unknown_command, scheme_unavailable, read_only };

pub const Model = struct {
    doc: Doc,
    snapshot: system.Snapshot,
    request: system.Request,
    mode: Mode,
    status: Status,
    revision: u32,
    command: [64]u8,
    command_length: usize,
    top_row: usize,
    serial: input.Serial,
    hid: input.Hid,
    utf8: [4]u8,
    utf8_length: u3,
    utf8_needed: u3,

    pub fn initInPlace(self: *Model) void {
        @memset(std.mem.asBytes(self), 0);
        self.doc.revision = 1;
        self.doc.next_group_id = 1;
        self.revision = 1;
    }
    fn changed(self: *Model) void {
        self.revision +%= 1;
    }
    fn failed(self: *Model, err: document.Error) void {
        self.status = switch (err) {
            error.BufferFull => .buffer_full,
            error.UndoFull => .undo_full,
            else => .invalid_input,
        };
    }
    fn accept(self: *Model, result: anytype) void {
        _ = result catch |err| {
            self.failed(err);
            return;
        };
    }
    pub fn insert(self: *Model, text: []const u8) void {
        if (self.mode == .system) {
            self.status = .read_only;
            self.changed();
            return;
        }
        self.status = .none;
        self.doc.insertUtf8(text) catch |err| self.failed(err);
        self.changed();
    }
    pub fn handle(self: *Model, key: input.Key) void {
        self.status = .none;
        self.changed();
        if (self.mode == .help) {
            if (key == .escape or key == .cancel or key == .enter) self.mode = .edit;
            return;
        }
        if (self.mode == .system) {
            switch (key) {
                .escape, .cancel => {
                    self.mode = .edit;
                    self.request = .none;
                },
                .up => self.snapshot.scroll(false),
                .down => self.snapshot.scroll(true),
                .clear => self.openSystem(self.snapshot.kind),
                else => self.status = .read_only,
            }
            return;
        }
        if (self.mode == .command) {
            switch (key) {
                .escape, .cancel => self.mode = .edit,
                .backspace => self.command_length -|= 1,
                .text => |byte| if (self.command_length < self.command.len) {
                    self.command[self.command_length] = byte;
                    self.command_length += 1;
                },
                .enter => {
                    const text = std.mem.trim(u8, self.command[0..self.command_length], " ");
                    self.mode = .edit;
                    if (std.mem.eql(u8, text, "help")) self.mode = .help else if (std.mem.eql(u8, text, "undo")) {
                        self.accept(self.doc.undo());
                    } else if (std.mem.eql(u8, text, "log")) self.openSystem(.log) else if (std.mem.eql(u8, text, "mem")) self.openSystem(.memory) else if (std.mem.eql(u8, text, "tasks")) self.openSystem(.tasks) else if (std.mem.eql(u8, text, "forget-undo")) self.doc.forgetUndoHistory() else if (text.len != 0) {
                        self.status = if (text[0] == '(') .scheme_unavailable else .unknown_command;
                    }
                },
                else => {},
            }
            return;
        }
        switch (key) {
            .text => |byte| self.insert(&.{byte}),
            .enter => self.insert("\n"),
            .backspace => {
                self.accept(self.doc.deleteBackwardGrapheme());
            },
            .eof => {
                self.accept(self.doc.deleteForwardGrapheme());
            },
            .left => {
                self.accept(self.doc.moveGraphemes(-1));
            },
            .right => {
                self.accept(self.doc.moveGraphemes(1));
            },
            .up => {
                self.accept(self.doc.moveLines(-1));
            },
            .down => {
                self.accept(self.doc.moveLines(1));
            },
            .undo => {
                self.accept(self.doc.undo());
            },
            .escape => {
                self.mode = .command;
                self.command_length = 0;
            },
            .cancel, .clear => {},
        }
    }
    fn openSystem(self: *Model, kind: system.Kind) void {
        self.snapshot.begin(kind);
        self.request = switch (kind) {
            .log => .log,
            .memory => .memory,
            .tasks => .tasks,
        };
        self.mode = .system;
    }
    pub fn takeSystemRequest(self: *Model) system.Request {
        const request = self.request;
        self.request = .none;
        return request;
    }
    pub fn feedHid(self: *Model, modifiers: u8, usage: u8) void {
        if (self.hid.feed(modifiers, usage)) |key| self.handle(key);
    }
    pub fn feedSerial(self: *Model, byte: u8, now: u64) void {
        if (self.utf8_length != 0 or byte >= 128) {
            if (self.utf8_length == 0) {
                self.serial.cr = false;
                const count = std.unicode.utf8ByteSequenceLength(byte) catch {
                    self.status = .invalid_input;
                    self.changed();
                    return;
                };
                self.utf8_needed = @intCast(count);
            } else if (byte & 0xc0 != 0x80) {
                self.utf8_length = 0;
                self.status = .invalid_input;
                self.changed();
                if (byte < 128) {
                    if (self.serial.feed(byte, now)) |key| self.handle(key);
                    self.status = .invalid_input;
                }
                return;
            }
            self.utf8[self.utf8_length] = byte;
            self.utf8_length += 1;
            if (self.utf8_length == self.utf8_needed) {
                const text = self.utf8[0..self.utf8_length];
                if (self.mode == .edit) self.insert(text) else {
                    self.status = .invalid_input;
                    self.changed();
                }
                self.utf8_length = 0;
            }
            return;
        }
        if (self.serial.feed(byte, now)) |key| self.handle(key);
    }
    pub fn expireSerial(self: *Model, now: u64) void {
        if (self.serial.expire(now)) |key| self.handle(key);
    }
    fn advance(text: []const u8, offset: usize, columns: usize, row: *usize, column: *usize) usize {
        const end = document.nextClusterEnd(text, offset) catch text.len;
        if (text[offset] == '\n') {
            row.* += 1;
            column.* = 0;
        } else {
            column.* += 1;
            if (column.* == columns) {
                row.* += 1;
                column.* = 0;
            }
        }
        return end;
    }
    pub inline fn render(self: *Model, grid: anytype) void {
        if (self.mode == .system) {
            self.snapshot.render(grid);
            return;
        }
        const Grid = @TypeOf(grid.*);
        const columns = Grid.width;
        const body_rows = Grid.height - 2;
        @memset(&grid.cells, ' ');
        grid.x = 0;
        grid.y = 0;
        grid.wrap_pending = false;
        grid.scrolls = 0;
        _ = grid.setScrollTop(1);
        grid.write(if (self.mode == .help) "xy / *help*\n" else "xy / *scratch* [RAM]\n");
        if (self.mode == .help) {
            grid.write(&help_text);
            return;
        }
        const text = self.doc.slice();
        var row: usize = 0;
        var col: usize = 0;
        var offset: usize = 0;
        while (offset < self.doc.cursor) offset = advance(text, offset, columns, &row, &col);
        const cursor_row = row;
        const cursor_col = col;
        if (cursor_row < self.top_row) self.top_row = cursor_row;
        if (cursor_row >= self.top_row + body_rows) self.top_row = cursor_row - body_rows + 1;
        row = 0;
        col = 0;
        offset = 0;
        while (offset < text.len and row < self.top_row + body_rows) {
            if (row >= self.top_row and text[offset] != '\n') grid.cells[(row - self.top_row + 1) * columns + col] = if (text[offset] >= 32 and text[offset] < 127) text[offset] else '?';
            offset = advance(text, offset, columns, &row, &col);
        }
        grid.cells[(cursor_row - self.top_row + 1) * columns + cursor_col] = '|';
        grid.x = 0;
        grid.y = Grid.height - 1;
        grid.wrap_pending = false;
        if (self.mode == .command) {
            grid.write(": ");
            grid.write(self.command[0..self.command_length]);
        } else grid.write(switch (self.status) {
            .none => "",
            .buffer_full => "Buffer full",
            .undo_full => "Undo full: Esc, forget-undo releases history",
            .invalid_input => "Invalid input",
            .unknown_command => "Unknown command: Esc, help",
            .scheme_unavailable => "Scheme evaluation is not connected yet",
            .read_only => "Read-only system buffer",
        });
    }
};

test "scratch editing uses shared Document cursor deletion and undo" {
    // SAFETY: all fields are initialized in place before use.
    var model: Model = undefined;
    model.initInPlace();
    for ("ab\r\ncd") |byte| model.feedSerial(byte, 0);
    try std.testing.expectEqualStrings("ab\ncd", model.doc.slice());
    model.feedHid(0, 0x50);
    model.handle(.{ .text = 'X' });
    try std.testing.expectEqualStrings("ab\ncXd", model.doc.slice());
    model.feedHid(1, 0x1d);
    try std.testing.expectEqualStrings("ab\ncd", model.doc.slice());
    model.handle(.up);
    try std.testing.expectEqual(@as(u32, 1), model.doc.cursor);
    model.handle(.eof);
    try std.testing.expectEqualStrings("a\ncd", model.doc.slice());
}

test "UTF8 serial input preserves IVS and combining clusters and colon text" {
    // SAFETY: all fields are initialized in place before use.
    var model: Model = undefined;
    model.initInPlace();
    for ("葛\u{e0100}か\u{3099}") |byte| model.feedSerial(byte, 0);
    model.handle(.backspace);
    try std.testing.expectEqualStrings("葛\u{e0100}", model.doc.slice());
    model.handle(.left);
    try std.testing.expectEqual(@as(u32, 0), model.doc.cursor);
    for (":storage\r\n") |byte| model.feedSerial(byte, 0);
    try std.testing.expectEqualStrings(":storage\n葛\u{e0100}", model.doc.slice());
    model.feedSerial(0xf0, 0);
    model.feedSerial('x', 0);
    try std.testing.expectEqual(Status.invalid_input, model.status);
    try std.testing.expect(std.unicode.utf8ValidateSlice(model.doc.slice()));
}

test "help and unavailable evaluation preserve scratch text" {
    // SAFETY: all fields are initialized in place before use.
    var model: Model = undefined;
    model.initInPlace();
    model.insert("notes");
    model.feedSerial(0x1b, 0);
    model.expireSerial(31_000);
    for ("help\r") |byte| model.feedSerial(byte, 32_000);
    try std.testing.expectEqual(Mode.help, model.mode);
    model.handle(.escape);
    model.handle(.escape);
    for ("(+ 1 2)\r") |byte| model.feedSerial(byte, 40_000);
    try std.testing.expectEqual(Status.scheme_unavailable, model.status);
    try std.testing.expectEqualStrings("notes", model.doc.slice());
}

test "bounded undo exhaustion and explicit discard retain document identity" {
    // SAFETY: all fields are initialized in place before use.
    var model: Model = undefined;
    model.initInPlace();
    for (0..256) |_| model.insert("x");
    model.insert("y");
    try std.testing.expectEqual(Status.undo_full, model.status);
    try std.testing.expectEqual(@as(u32, 256), model.doc.len);
    const revision = model.doc.revision;
    const cursor = model.doc.cursor;
    model.handle(.escape);
    for ("forget-undo\r") |byte| model.feedSerial(byte, 0);
    try std.testing.expectEqual(revision, model.doc.revision);
    try std.testing.expectEqual(cursor, model.doc.cursor);
    model.insert("y");
    model.handle(.undo);
    try std.testing.expectEqual(@as(u32, 256), model.doc.len);
}

test "viewport follows cursor and presentation never modifies UTF8 source" {
    // SAFETY: all fields are initialized in place before use.
    var model: Model = undefined;
    model.initInPlace();
    for (0..30) |_| model.insert("line\n");
    model.insert("日本");
    var grid = @import("../console/ascii.zig").Grid(24, 8){};
    model.render(&grid);
    try std.testing.expect(std.mem.startsWith(u8, &grid.cells, "xy / *scratch* [RAM]"));
    try std.testing.expect(model.top_row > 0);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "??|") != null);
    try std.testing.expect(std.mem.endsWith(u8, model.doc.slice(), "日本"));
    model.doc.cursor = 0;
    model.render(&grid);
    try std.testing.expectEqual(@as(usize, 0), model.top_row);
    try std.testing.expectEqual(@as(u8, '|'), grid.cells[24]);
}

test "read only system buffers preserve scratch cursor revision and undo" {
    // SAFETY: initialized before use.
    var model: Model = undefined;
    model.initInPlace();
    model.insert("葛\u{e0100} draft");
    model.handle(.left);
    const cursor = model.doc.cursor;
    const revision = model.doc.revision;
    const undo_count = model.doc.undo_count;
    for ([_][]const u8{ "log", "mem", "tasks" }, [_]system.Request{ .log, .memory, .tasks }) |command, expected| {
        model.handle(.escape);
        for (command) |byte| model.handle(.{ .text = byte });
        model.handle(.enter);
        try std.testing.expectEqual(Mode.system, model.mode);
        try std.testing.expectEqual(expected, model.takeSystemRequest());
        try std.testing.expectEqual(system.Request.none, model.takeSystemRequest());
        model.snapshot.write("captured observation\n");
        for ([_]input.Key{ .{ .text = 'X' }, .enter, .backspace, .eof, .undo, .left, .right, .up, .down }) |key| model.handle(key);
        model.insert("blocked");
        for ("日本") |byte| model.feedSerial(byte, 0);
        try std.testing.expectEqualStrings("葛\u{e0100} draft", model.doc.slice());
        try std.testing.expectEqual(cursor, model.doc.cursor);
        try std.testing.expectEqual(revision, model.doc.revision);
        try std.testing.expectEqual(undo_count, model.doc.undo_count);
        model.handle(.clear);
        try std.testing.expectEqual(expected, model.takeSystemRequest());
        model.handle(.escape);
        try std.testing.expectEqual(Mode.edit, model.mode);
    }
    model.handle(.undo);
    try std.testing.expectEqualStrings("", model.doc.slice());
}

//! RAM workspace over the shared xy Document and bounded Scheme runtime.
//! Normal boot uses render_session; render() retains a fixed-cell projection
//! for console fixtures. The runtime has no storage or shell access.
const std = @import("std");
pub const input = @import("../console/session_input.zig");
pub const scheme = @import("scheme_runtime.zig");
pub const document = @import("document.zig");
// Immutable presentation text follows the existing diagnostic font placement;
// host targets retain their ordinary read-only segment.
pub const help_text linksection(if (@import("builtin").os.tag == .freestanding) ".flash.rodata.display" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata") = "Type directly into *scratch*.\n\nArrows: move   Backspace: delete before\nCtrl-D: delete after   Ctrl-Z: undo\nEsc: minibuffer   Ctrl-C: cancel\n\nMinibuffer: Scheme expression or command\nCommands: log, mem, tasks, undo, forget-undo\nEval source: eval-buffer   Reset VM: reset-scheme\n\nRAM only: this buffer is not saved.\n\nEnter or Esc: return to *scratch*".*;
pub const Doc = document.Document(4096, 256, 2048, 1, 64);
pub const system = @import("system_buffer.zig");
pub const navigation = @import("navigation.zig");
pub const Mode = enum { edit, command, help, system };
pub const Status = enum { none, buffer_full, undo_full, invalid_input, unknown_command, scheme_result, scheme_error, command_full, read_only };

const default_commands linksection(scheme.data_section) = ("(command/register! \"log\" (lambda () (system/log))) " ++
    "(command/register! \"mem\" (lambda () (system/memory))) " ++
    "(command/register! \"tasks\" (lambda () (system/tasks))) " ++
    "(command/register! \"undo\" (lambda () (buffer/undo!))) " ++
    "(command/register! \"forget-undo\" (lambda () (buffer/forget-undo!)))").*;

const status_0 linksection(scheme.data_section) = "Buffer full".*;

const status_1 linksection(scheme.data_section) = "Undo full: Esc, forget-undo releases history".*;

const status_2 linksection(scheme.data_section) = "Invalid input".*;

const status_3 linksection(scheme.data_section) = "Unknown command: Esc, help".*;

const status_4 linksection(scheme.data_section) = "Command too long; cancel or edit before evaluating".*;

const status_5 linksection(scheme.data_section) = "Read-only system buffer".*;

pub const Model = struct {
    doc: Doc,
    nav: navigation.State,
    vm: scheme.Runtime,
    reply: [128]u8,
    reply_length: usize,
    command_overflow: bool,
    snapshot: system.Snapshot,
    request: system.Request,
    mode: Mode,
    status: Status,
    revision: u32,
    command: [256]u8,
    command_length: usize,
    top_row: usize,
    serial: input.Serial,
    hid: input.Hid,
    utf8: [4]u8,
    utf8_length: u3,
    utf8_needed: u3,

    pub fn initInPlace(self: *Model) linksection(scheme.code_section) void {
        @memset(std.mem.asBytes(self), 0);
        self.nav.chapter_count = .{ 3, 13, 3, 32 };
        self.doc.revision = 1;
        self.doc.next_group_id = 1;
        self.revision = 1;
        self.resetScheme();
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
    pub fn insert(self: *Model, text: []const u8) linksection(scheme.code_section) void {
        if (self.mode == .system or self.nav.screen != .document) {
            self.status = .read_only;
            self.changed();
            return;
        }
        self.status = .none;
        self.doc.insertUtf8(text) catch |err| self.failed(err);
        self.changed();
    }
    pub fn handle(self: *Model, key: input.Key) linksection(scheme.code_section) void {
        self.status = .none;
        self.changed();
        if (self.nav.screen != .document) {
            const nav_key: navigation.Key = switch (key) {
                inline else => |value, tag| @unionInit(navigation.Key, @tagName(tag), value),
            };
            self.nav.handle(nav_key, &self.vm.view);
            return;
        }
        if (key == .cancel and self.mode == .edit) {
            self.nav.home();
            return;
        }
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
                .backspace => {
                    self.command_length = document.prevClusterStart(self.command[0..self.command_length], self.command_length) catch 0;
                    self.command_overflow = false;
                },
                .text => |byte| self.appendCommand(&.{byte}),
                .enter => {
                    const text = std.mem.trim(u8, self.command[0..self.command_length], " ");
                    self.mode = .edit;
                    if (self.command_overflow) {
                        self.status = .command_full;
                        return;
                    }
                    if (std.mem.eql(u8, text, "home")) self.nav.home() else if (std.mem.eql(u8, text, "help")) self.mode = .help else if (std.mem.eql(u8, text, "reset-scheme")) self.resetScheme() else if (std.mem.eql(u8, text, "eval-buffer")) self.evaluate(self.doc.slice(), false) else if (text.len != 0) self.evaluate(text, text[0] != '(' and text[0] != '\'');
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
                self.command_overflow = false;
            },
            .cancel, .clear => {},
        }
    }
    fn appendCommand(self: *Model, bytes: []const u8) linksection(scheme.code_section) void {
        if (self.command_overflow or self.command_length + bytes.len > self.command.len) {
            self.command_overflow = true;
            self.status = .command_full;
            return;
        }
        @memcpy(self.command[self.command_length..][0..bytes.len], bytes);
        self.command_length += bytes.len;
    }
    pub fn resetScheme(self: *Model) linksection(scheme.code_section) void {
        self.vm.initInPlace();
        const result = self.vm.evaluate(&default_commands, self, &self.reply) catch |err| {
            self.schemeError(err);
            return;
        };
        self.reply_length = result.len;
    }
    fn schemeError(self: *Model, err: scheme.Error) linksection(scheme.code_section) void {
        const text = scheme.message(err);
        @memcpy(self.reply[0..text.len], text);
        self.reply_length = text.len;
        self.status = if (err == error.UnknownCommand) .unknown_command else .scheme_error;
    }
    pub fn evaluate(self: *Model, source: []const u8, named: bool) linksection(scheme.code_section) void {
        _ = self.doc.beginUndoGroup();
        defer self.doc.endUndoGroup();
        self.changed();
        const reply = (if (named) self.vm.runCommand(source, self, &self.reply) else self.vm.evaluate(source, self, &self.reply)) catch |err| {
            self.schemeError(err);
            return;
        };
        self.reply_length = reply.len;
        self.status = .scheme_result;
    }
    pub fn schemeCall(self: *Model, op: scheme.EditorOp, text: []const u8, number: i32) linksection(scheme.code_section) scheme.Error!void {
        if ((self.mode == .system or self.nav.screen != .document) and (op == .insert or op == .move or op == .undo or op == .forget)) return error.EditorFailure;
        switch (op) {
            .insert => self.doc.insertUtf8(text) catch return error.EditorFailure,
            .move => {
                _ = self.doc.moveGraphemes(number) catch return error.EditorFailure;
            },
            .undo => {
                _ = self.doc.undo() catch return error.EditorFailure;
            },
            .forget => self.doc.forgetUndoHistory(),
            .log => self.openSystem(.log),
            .memory => self.openSystem(.memory),
            .tasks => self.openSystem(.tasks),
        }
    }
    fn openSystem(self: *Model, kind: system.Kind) linksection(scheme.code_section) void {
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
    pub fn feedHid(self: *Model, modifiers: u8, usage: u8) linksection(scheme.code_section) void {
        if (self.hid.feed(modifiers, usage)) |key| self.handle(key);
    }
    pub fn feedSerial(self: *Model, byte: u8, now: u64) linksection(scheme.code_section) void {
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
                if (!std.unicode.utf8ValidateSlice(text)) {
                    self.status = .invalid_input;
                    self.changed();
                } else if (self.mode == .edit) self.insert(text) else if (self.mode == .command) {
                    self.appendCommand(text);
                    self.changed();
                } else {
                    self.status = .invalid_input;
                    self.changed();
                }
                self.utf8_length = 0;
            }
            return;
        }
        if (self.serial.feed(byte, now)) |key| self.handle(key);
    }
    pub fn expireSerial(self: *Model, now: u64) linksection(scheme.code_section) void {
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
    pub fn statusText(self: *const Model) linksection(scheme.code_section) []const u8 {
        return switch (self.status) {
            .none => "",
            .buffer_full => &status_0,
            .undo_full => &status_1,
            .invalid_input => &status_2,
            .unknown_command => &status_3,
            .scheme_result, .scheme_error => "",
            .command_full => &status_4,
            .read_only => &status_5,
        };
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
            var start = self.command_length -| (columns - 3);
            while (start < self.command_length and !document.isClusterBoundary(self.command[0..self.command_length], start)) start += 1;
            var index = start;
            while (index < self.command_length) {
                grid.write(&.{if (self.command[index] < 128) self.command[index] else @as(u8, '?')});
                index = document.nextClusterEnd(self.command[0..self.command_length], index) catch self.command_length;
            }
        } else if (self.status == .scheme_result or self.status == .scheme_error) {
            grid.write(if (self.status == .scheme_error) "Scheme error: " else "Scheme: ");
            var index: usize = 0;
            var available = columns - grid.x - 1;
            while (index < self.reply_length and available > 0) : (available -= 1) {
                grid.write(&.{if (self.reply[index] >= 32 and self.reply[index] < 127) self.reply[index] else @as(u8, '?')});
                index = document.nextClusterEnd(self.reply[0..self.reply_length], index) catch self.reply_length;
            }
        } else grid.write(self.statusText());
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

test "help and Scheme evaluation preserve scratch text" {
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
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expectEqualStrings("3", model.reply[0..model.reply_length]);
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

fn enterCommand(model: *Model, source: []const u8) void {
    model.handle(.escape);
    for (source) |byte| model.feedSerial(byte, 0);
    model.handle(.enter);
}
test "minibuffer registers programmable commands with grouped undo and UTF8 names" {
    // SAFETY: initialized before use.
    var model: Model = undefined;
    model.initInPlace();
    model.insert("notes:");
    enterCommand(&model, "(define (挨拶) (buffer/insert! \"葛\u{e0100}\") (buffer/insert! \"!\"))");
    try std.testing.expectEqual(Status.scheme_result, model.status);
    enterCommand(&model, "挨拶");
    try std.testing.expectEqualStrings("notes:葛\u{e0100}!", model.doc.slice());
    model.handle(.undo);
    try std.testing.expectEqualStrings("notes:", model.doc.slice());
    enterCommand(&model, "(buffer/move-graphemes! -2147483648)");
    try std.testing.expectEqual(@as(u32, 0), model.doc.cursor);
    enterCommand(&model, "(buffer/move-graphemes! 2147483647)");
    enterCommand(&model, "(command/register! \"log\" (lambda () (buffer/insert! \"custom\")))");
    enterCommand(&model, "log");
    try std.testing.expectEqual(Mode.edit, model.mode);
    try std.testing.expectEqualStrings("notes:custom", model.doc.slice());
    enterCommand(&model, "reset-scheme");
    enterCommand(&model, "log");
    try std.testing.expectEqual(Mode.system, model.mode);
    model.handle(.escape);
    try std.testing.expectEqualStrings("notes:custom", model.doc.slice());
}
test "eval buffer parses before self-edit and truncated commands never execute" {
    // SAFETY: initialized before use.
    var model: Model = undefined;
    model.initInPlace();
    const source = "(buffer/insert! \"X\") (buffer/insert! \"Y\")";
    model.insert(source);
    enterCommand(&model, "eval-buffer");
    try std.testing.expectEqualStrings(source ++ "XY", model.doc.slice());
    model.handle(.undo);
    try std.testing.expectEqualStrings(source, model.doc.slice());
    enterCommand(&model, "(buffer/insert! \"bad\") (");
    try std.testing.expectEqual(Status.scheme_error, model.status);
    try std.testing.expectEqualStrings(source, model.doc.slice());
    model.handle(.escape);
    for ("(buffer/insert! \"bad\")") |byte| model.feedSerial(byte, 0);
    for (0..256) |_| model.feedSerial(' ', 0);
    model.handle(.enter);
    try std.testing.expectEqual(Status.command_full, model.status);
    try std.testing.expectEqualStrings(source, model.doc.slice());
    enterCommand(&model, "(+ 20 22)");
    try std.testing.expectEqualStrings("42", model.reply[0..model.reply_length]);
    model.handle(.escape);
    for ("葛\u{e0100}") |byte| model.feedSerial(byte, 0);
    model.handle(.backspace);
    try std.testing.expectEqual(@as(usize, 0), model.command_length);
}

//! RAM workspace over the shared xy Document and bounded Scheme runtime.
//! Normal boot uses render_session; render() retains a fixed-cell projection
//! for console fixtures. Storage uses copied provider requests; no shell access is exposed.
const std = @import("std");
pub const input = @import("../console/session_input.zig");
pub const scheme = @import("scheme_runtime.zig");
pub const document = @import("document.zig");
// Immutable presentation text follows the existing diagnostic font placement;
// host targets retain their ordinary read-only segment.
pub const help_text linksection(if (@import("builtin").os.tag == .freestanding) ".flash.rodata.display" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata") = "Type directly into *scratch*.\n\nArrows: move   Backspace: delete before\nCtrl-D: delete after   Ctrl-Z: undo\nEsc: minibuffer   Ctrl-C: cancel\n\nMinibuffer: Scheme expression or command\nCommands: log, mem, tasks, undo, forget-undo\nEval source: eval-buffer   Reset VM: reset-scheme\n\nSave: (buffer/save! \"name\")\nLoad: (buffer/load! \"name\")\nStorage must be available.\n\nEnter or Esc: return to *scratch*".*;
pub const Doc = document.Document(4096, 256, 2048, 1, 64);
pub const camera = @import("camera.zig");
pub const card = @import("card.zig");
pub const soft_keyboard = @import("soft_keyboard.zig");
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

pub const LearningSession = @import("learning_session.zig").Session;
pub const Model = struct {
    camera: camera.Client,
    card: card.Client,
    storage_client: scheme.storage.Client,
    doc: Doc,
    nav: navigation.State,
    learning: ?*@import("learning_session.zig").Session,
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
    deferred_serial: [512]u8,
    deferred_serial_delta: [512]u8,
    deferred_serial_first: u64,
    deferred_serial_last: u64,
    deferred_serial_count: u16,
    deferred: [64]input.Key,
    deferred_count: u8,
    deferred_overflow: bool,
    utf8: [4]u8,
    utf8_length: u3,
    utf8_needed: u3,
    /// Set by the session layer from the Tab5 keyboard probe (or a host
    /// that knows better). While true the soft keyboard stays hidden.
    physical_keyboard: bool,
    /// Dismissal is recorded against the input context that was active,
    /// so it expires by itself when the context changes.
    soft_keyboard_dismissed: bool,
    soft_keyboard_context: u8,
    soft_keyboard_state: soft_keyboard.State,
    portrait_touch: bool,
    /// Start point of the current touch, for edge-gesture recognition.
    touch_start_x: u32,
    touch_start_y: u32,
    touch_tracking: bool,

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
    pub fn replayInput(self: *Model) linksection(scheme.code_section) void {
        if (self.vm.running) return;
        if (self.deferred_overflow) {
            self.deferred_count = 0;
            self.deferred_serial_count = 0;
            self.deferred_overflow = false;
            self.serial = .{};
            self.utf8_length = 0;
            self.command_length = 0;
            self.mode = .edit;
            self.status = .invalid_input;
            self.changed();
            return;
        }
        var replay_now = self.deferred_serial_first;
        while (self.deferred_serial_count != 0) {
            const byte = self.deferred_serial[0];
            replay_now +|= @as(u64, self.deferred_serial_delta[0]) * 250;
            self.deferred_serial_count -= 1;
            std.mem.copyForwards(u8, self.deferred_serial[0..self.deferred_serial_count], self.deferred_serial[1..][0..self.deferred_serial_count]);
            std.mem.copyForwards(u8, self.deferred_serial_delta[0..self.deferred_serial_count], self.deferred_serial_delta[1..][0..self.deferred_serial_count]);
            self.expireSerial(replay_now);
            self.feedSerial(byte, replay_now);
        }
        while (self.deferred_count != 0) {
            const key = self.deferred[0];
            self.deferred_count -= 1;
            std.mem.copyForwards(input.Key, self.deferred[0..self.deferred_count], self.deferred[1..][0..self.deferred_count]);
            self.handle(key);
        }
    }
    pub fn insert(self: *Model, text: []const u8) linksection(scheme.code_section) void {
        if (self.nav.screen == .exercise) {
            if (self.learning) |l| l.insert(text) catch |err| l.notice(err);
            self.changed();
            return;
        }
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
        if (self.vm.running) {
            if (self.deferred_count == self.deferred.len) {
                self.deferred_overflow = true;
                return;
            }
            self.deferred[self.deferred_count] = key;
            self.deferred_count += 1;
            return;
        }
        self.status = .none;
        self.changed();
        if (self.nav.screen != .document) {
            if (self.nav.screen == .card_view and key == .enter) {
                var insert_buf: [256]u8 = undefined;
                const formatted = std.fmt.bufPrint(&insert_buf, "氏名: {s}\n住所: {s}\n生年月日: {s}\n", .{
                    self.nav.card.nameSlice(),
                    self.nav.card.addressSlice(),
                    self.nav.card.birthSlice(),
                }) catch "";
                self.nav.screen = .document;
                if (formatted.len > 0) self.insert(formatted);
                return;
            }
            const nav_key: navigation.Key = switch (key) {
                inline else => |value, tag| @unionInit(navigation.Key, @tagName(tag), value),
            };
            if (self.nav.screen == .examples or self.nav.screen == .exercise) {
                if (self.learning) |l| l.handle(&self.nav, nav_key) else self.nav.screen = .reading;
            } else self.nav.handle(nav_key, &self.vm.view);
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
    /// Input contexts that accept text: the document in edit or command
    /// mode, and the learning exercise screen. Zero is "no context".
    fn softKeyboardContext(self: *const Model) u8 {
        // The learning screens keep their own touch layout for now; the
        // keyboard serves the document screen first.
        if (self.nav.screen != .document) return 0;
        return switch (self.mode) {
            .edit => 1,
            .command => 2,
            else => 0,
        };
    }

    pub fn setPhysicalKeyboard(self: *Model, present: bool) linksection(scheme.code_section) void {
        if (self.physical_keyboard == present) return;
        self.physical_keyboard = present;
        if (!present) self.soft_keyboard_dismissed = false;
        self.changed();
    }

    pub fn softKeyboardVisible(self: *const Model) bool {
        const context = self.softKeyboardContext();
        const dismissed = self.soft_keyboard_dismissed and self.soft_keyboard_context == context;
        return soft_keyboard.visible(self.physical_keyboard, context != 0, dismissed);
    }

    pub fn touchOrientation(self: *const Model) soft_keyboard.Orientation {
        return if (self.portrait_touch) .portrait else .landscape;
    }

    pub fn touchDown(self: *Model, x: u32, y: u32) linksection(scheme.code_section) void {
        self.touch_start_x = x;
        self.touch_start_y = y;
        self.touch_tracking = true;
    }

    /// Applies a recognized edge gesture, returning true when it consumed
    /// the touch: flick up from the bottom edge summons the keyboard
    /// (clearing a dismissal), flick down across it dismisses it.
    fn touchGesture(self: *Model, x: u32, y: u32) bool {
        if (!self.touch_tracking) return false;
        self.touch_tracking = false;
        switch (soft_keyboard.edgeGestureIn(self.touch_start_x, self.touch_start_y, x, y, self.touchOrientation())) {
            .none => return false,
            .show => {
                if (self.physical_keyboard or self.softKeyboardContext() == 0) return false;
                self.soft_keyboard_dismissed = false;
                self.changed();
                return true;
            },
            .hide => {
                if (!self.softKeyboardVisible()) return false;
                self.soft_keyboard_dismissed = true;
                self.soft_keyboard_context = self.softKeyboardContext();
                self.changed();
                return true;
            },
        }
    }

    pub fn touch(self: *Model, x: u32, y: u32) linksection(scheme.code_section) void {
        const tracked = self.touch_tracking;
        const start_x = self.touch_start_x;
        const start_y = self.touch_start_y;
        if (self.touchGesture(x, y)) return;
        if (self.softKeyboardVisible()) {
            if (tracked) {
                const start = soft_keyboard.keyAtIn(start_x, start_y, self.soft_keyboard_state, self.touchOrientation());
                const end = soft_keyboard.keyAtIn(x, y, self.soft_keyboard_state, self.touchOrientation());
                if (start != null or end != null or soft_keyboard.containsIn(start_x, start_y, self.touchOrientation())) {
                    if (start == null or end == null or !std.meta.eql(start.?, end.?)) return;
                }
            }
            if (soft_keyboard.keyAtIn(x, y, self.soft_keyboard_state, self.touchOrientation())) |action| {
                switch (action) {
                    .char => |byte| {
                        self.handle(.{ .text = byte });
                        if (!self.soft_keyboard_state.symbols) self.soft_keyboard_state.shift = false;
                    },
                    .shift => {
                        self.soft_keyboard_state.shift = !self.soft_keyboard_state.shift;
                        self.changed();
                    },
                    .symbols => {
                        self.soft_keyboard_state.symbols = !self.soft_keyboard_state.symbols;
                        self.soft_keyboard_state.shift = false;
                        self.changed();
                    },
                    .left => self.handle(.left),
                    .right => self.handle(.right),
                    .enter => self.handle(.enter),
                    .backspace => self.handle(.backspace),
                    .escape => self.handle(.escape),
                    .dismiss => {
                        self.soft_keyboard_dismissed = true;
                        self.soft_keyboard_context = self.softKeyboardContext();
                        self.changed();
                    },
                }
                return;
            }
            if (soft_keyboard.containsIn(x, y, self.touchOrientation())) return; // Gaps between keys.
        }
        if (self.nav.screen == .examples or self.nav.screen == .exercise) {
            if (self.learning) |l| l.touch(&self.nav, x, y);
        } else self.nav.touch(x, y, &self.vm.view);
        self.changed();
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
        if (comptime @import("builtin").os.tag == .freestanding) return nih_xy_evaluate(self, source.ptr, source.len, named);
        self.evaluateOnStack(source, named);
    }
    extern fn nih_xy_evaluate(*Model, [*]const u8, usize, bool) void;
    pub fn evaluateOnStack(self: *Model, source: []const u8, named: bool) linksection(scheme.code_section) void {
        // A storage wait may present the initial revision before the reply arrives.
        defer self.changed();
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
    pub fn cameraCapture(self: *Model) linksection(scheme.code_section) scheme.Error!i32 {
        return self.camera.capture();
    }
    pub fn storageCall(self: *Model, request: scheme.storage.Request, output: []u8) linksection(scheme.code_section) scheme.Error![]const u8 {
        return self.storage_client.call(request, output);
    }
    pub fn saveDocument(self: *Model, name: []const u8) linksection(scheme.code_section) scheme.Error!void {
        if (self.mode == .system) return error.EditorFailure;
        try self.storage_client.save(name, self.doc.slice());
    }
    pub fn documentText(self: *Model) linksection(scheme.code_section) []const u8 {
        return self.doc.slice();
    }
    pub fn loadDocument(self: *Model, name: []const u8) linksection(scheme.code_section) scheme.Error!void {
        if (self.mode == .system) return error.EditorFailure;
        // This foreground-only buffer is already reserved for system snapshots.
        const text = try self.storage_client.load(name, &self.snapshot.bytes);
        self.doc.clear();
        self.doc.insertUtf8(text) catch return error.EditorFailure;
        self.top_row = 0;
    }
    pub fn cameraInfo(self: *Model, camera_handle: i32) linksection(scheme.code_section) scheme.Error!camera.Info {
        return self.camera.info(camera_handle);
    }
    pub fn cameraRead(self: *Model, camera_handle: i32, offset: u32, output: []u8) linksection(scheme.code_section) scheme.Error!void {
        return self.camera.read(camera_handle, offset, output);
    }
    pub fn cardRead(self: *Model) linksection(scheme.code_section) scheme.Error!i32 {
        return self.card.readInputSupport();
    }
    pub fn cardInfo(self: *Model, card_handle: i32) linksection(scheme.code_section) scheme.Error!card.Info {
        return self.card.info(card_handle);
    }
    pub fn cardDismiss(self: *Model, card_handle: i32) linksection(scheme.code_section) scheme.Error!void {
        try self.card.dismiss(card_handle);
        if (self.nav.screen == .card_view) {
            self.nav.card.clear();
            self.nav.screen = .document;
            self.changed();
        }
    }
    pub fn showCardView(self: *Model, card_handle: i32) linksection(scheme.code_section) scheme.Error!void {
        const info = try self.card.info(card_handle);
        self.nav.card.clear();
        self.nav.card.valid = true;
        const nlen = @min(info.name.len, self.nav.card.name.len);
        @memcpy(self.nav.card.name[0..nlen], info.name[0..nlen]);
        self.nav.card.name_len = @intCast(nlen);

        const alen = @min(info.address.len, self.nav.card.address.len);
        @memcpy(self.nav.card.address[0..alen], info.address[0..alen]);
        self.nav.card.address_len = @intCast(alen);

        const blen = @min(info.birth.len, self.nav.card.birth.len);
        @memcpy(self.nav.card.birth[0..blen], info.birth[0..blen]);
        self.nav.card.birth_len = @intCast(blen);

        const glen = @min(info.gender.len, self.nav.card.gender.len);
        @memcpy(self.nav.card.gender[0..glen], info.gender[0..glen]);
        self.nav.card.gender_len = @intCast(glen);

        self.nav.card.has_photo = info.photo_bytes > 0;
        self.nav.return_screen = if (self.nav.screen == .card_view) .document else self.nav.screen;
        self.nav.screen = .card_view;
        self.changed();
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
        if (self.vm.running) {
            if (self.deferred_serial_count == self.deferred_serial.len) {
                self.deferred_overflow = true;
                return;
            }
            if (self.deferred_serial_count == 0) {
                self.deferred_serial_first = now;
                self.deferred_serial_last = now;
            }
            self.deferred_serial_delta[self.deferred_serial_count] = @intCast(@min((now -| self.deferred_serial_last) / 250, 255));
            self.deferred_serial_last = now;
            self.deferred_serial[self.deferred_serial_count] = byte;
            self.deferred_serial_count += 1;
            return;
        }
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
        if (self.vm.running) return;
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

test "camera handle reads are bounded copies and do not edit the document" {
    const Fake = struct {
        var state: camera.State = .pending;
        var issued = false;
        const payload = [_]u8{ 0xff, 0xd8, 0, 0x80, 0xff, 0xd9 };
        fn capture() camera.Error!i32 {
            if (issued) return error.CameraBusy;
            issued = true;
            return 7;
        }
        fn info(camera_handle: i32) camera.Error!camera.Info {
            if (!issued or camera_handle != 7) return error.InvalidCameraHandle;
            return .{ .state = state, .bytes = if (state == .ready) payload.len else 0 };
        }
        fn read(_: i32, offset: u32, output: []u8) camera.Error!void {
            @memcpy(output, payload[offset..][0..output.len]);
        }
    };
    Fake.state = .pending;
    Fake.issued = false;
    const provider = camera.Provider{ .capture = Fake.capture, .info = Fake.info, .read = Fake.read };
    // SAFETY: initialization fills all metadata and VM cells before use.
    var model: Model = undefined;
    model.initInPlace();
    model.insert("notes");
    model.evaluate("(camera/capture!)", false);
    try std.testing.expectEqual(Status.scheme_error, model.status);
    try std.testing.expectEqualStrings("Camera unavailable", model.reply[0..model.reply_length]);
    model.camera.provider = &provider;
    var output: [128]u8 = @splat(0);
    try std.testing.expectEqualStrings("7", try model.vm.evaluate("(define image (camera/capture!)) image", &model, &output));
    try std.testing.expectEqualStrings("(pending 1280 720 0)", try model.vm.evaluate("(camera/info image)", &model, &output));
    try std.testing.expectError(error.CameraBusy, model.vm.evaluate("(camera/capture!)", &model, &output));
    try std.testing.expectError(error.CameraBusy, model.vm.evaluate("(camera/read image 0 1)", &model, &output));
    try std.testing.expectError(error.InvalidCameraHandle, model.vm.evaluate("(camera/info 8)", &model, &output));
    Fake.state = .ready;
    try std.testing.expectEqualStrings("(ready 1280 720 6)", try model.vm.evaluate("(camera/info image)", &model, &output));
    try std.testing.expectEqualStrings("\"ffd80080ffd9\"", try model.vm.evaluate("(camera/read image 0 6)", &model, &output));
    try std.testing.expectEqualStrings("\"\"", try model.vm.evaluate("(camera/read image 6 0)", &model, &output));
    for ([_][]const u8{ "(camera/read image -1 1)", "(camera/read image 0 -1)", "(camera/read image 0 33)", "(camera/read image 6 1)", "(camera/read image 2147483647 1)" }) |source| {
        try std.testing.expectError(error.InvalidCameraRange, model.vm.evaluate(source, &model, &output));
    }
    try std.testing.expectError(error.InvalidCameraHandle, model.vm.evaluate("(camera/read 0 0 1)", &model, &output));
    try std.testing.expectError(error.Arity, model.vm.evaluate("(camera/capture! 1)", &model, &output));
    try std.testing.expectError(error.Type, model.vm.evaluate("(camera/read image \"0\" 1)", &model, &output));
    // View configuration and camera access share the rebased builtin table.
    try std.testing.expectEqualStrings("2", try model.vm.evaluate("(view/set! #:size 36 #:foreground #x234567)", &model, &output));
    try std.testing.expectEqualStrings("\"ffd8\"", try model.vm.evaluate("(camera/read image 0 2)", &model, &output));
    try std.testing.expectEqualStrings("36", try model.vm.evaluate("(view/get #:size)", &model, &output));
    model.resetScheme();
    try std.testing.expectEqualStrings("\"ffd8\"", try model.vm.evaluate("(camera/read 7 0 2)", &model, &output));
    Fake.state = .failed;
    try std.testing.expectError(error.CameraFailed, model.vm.evaluate("(camera/read 7 0 1)", &model, &output));
    try std.testing.expectEqualStrings("notes", model.doc.slice());
}

test "learning input owns separate draft and notes without changing editor undo or settings" {
    const l = try std.testing.allocator.create(LearningSession);
    defer std.testing.allocator.destroy(l);
    l.initInPlace();
    l.active_slot = 0;
    l.slots[0].used = true;
    l.slots[0].code.revision = 1;
    l.slots[0].code.next_group_id = 1;
    l.slots[0].notes.revision = 1;
    l.slots[0].notes.next_group_id = 1;
    var model: Model = undefined;
    model.initInPlace();
    model.learning = l;
    model.insert("ordinary document");
    model.vm.view.style.axis = 1;
    model.nav.screen = .exercise;
    model.handle(.{ .text = 'A' });
    model.handle(.enter);
    for ("日本語") |b| model.feedSerial(b, 0);
    try std.testing.expectEqualStrings("A\n日本語", l.slots[0].code.slice());
    model.handle(.backspace);
    try std.testing.expectEqualStrings("A\n日本", l.slots[0].code.slice());
    model.handle(.undo);
    try std.testing.expectEqualStrings("A\n日本語", l.slots[0].code.slice());
    model.touch(1100, 680);
    for ("メモ") |b| model.feedSerial(b, 0);
    try std.testing.expectEqualStrings("メモ", l.slots[0].notes.slice());
    model.handle(.escape);
    try std.testing.expectEqual(navigation.Screen.reading, model.nav.screen);
    try std.testing.expectEqual(@as(u8, 1), model.vm.view.style.axis);
    try std.testing.expectEqualStrings("ordinary document", model.doc.slice());
    try std.testing.expect(try model.doc.undo());
    try std.testing.expectEqualStrings("", model.doc.slice());
}

// A provider may pump native UI while an evaluation awaits SD completion.
test "storage wait defers UTF8 and rejects an overflowing command as a whole" {
    var model: Model = undefined;
    model.initInPlace();
    model.insert("before");
    model.vm.running = true;
    for ("日本語") |byte| model.feedSerial(byte, 0);
    model.handle(.backspace);
    try std.testing.expectEqualStrings("before", model.doc.slice());
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqualStrings("before日本", model.doc.slice());
    model.vm.running = true;
    for (0..1100) |_| model.feedSerial('x', 0);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqualStrings("before日本", model.doc.slice());
    try std.testing.expectEqual(Status.invalid_input, model.status);
}

test "evaluation publishes a fresh revision after a provider pumps the pending UI" {
    const Provider = struct {
        model: *Model,
        observed: u32 = 0,
        fn call(context: ?*anyopaque, _: scheme.storage.Request, output: []u8) scheme.storage.Error![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.model.vm.running) return error.StorageFailed;
            self.observed = self.model.revision;
            @memcpy(output[0..2], "#t");
            return output[0..2];
        }
    };
    var model: Model = undefined;
    model.initInPlace();
    var provider = Provider{ .model = &model };
    model.storage_client.provider = .{ .context = &provider, .call = Provider.call };
    model.evaluate("(sql/check)", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expect(model.revision > provider.observed);
}

test "storage wait preserves the delayed ESC that opens a queued Scheme command" {
    var model: Model = undefined;
    model.initInPlace();
    model.vm.running = true;
    model.feedSerial(0x1b, 1_000_000);
    for ("(+ 1 2)\r") |byte| model.feedSerial(byte, 1_100_000);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expectEqualStrings("3", model.reply[0..model.reply_length]);
    try std.testing.expectEqualStrings("", model.doc.slice());
}

fn tapSoftKey(model: *Model, label: u8) void {
    var rects: [soft_keyboard.max_keys]soft_keyboard.KeyRect = undefined;
    for (soft_keyboard.layout(&rects)) |rect| {
        if (rect.label == label) {
            model.touch(rect.x + rect.w / 2, rect.y + rect.h / 2);
            return;
        }
    }
    unreachable;
}

test "soft keyboard types, edits and runs a minibuffer command without a physical keyboard" {
    var model: Model = undefined;
    model.initInPlace();
    try std.testing.expect(model.softKeyboardVisible());
    tapSoftKey(&model, 'h');
    tapSoftKey(&model, 'i');
    try std.testing.expectEqualStrings("hi", model.doc.slice());
    tapSoftKey(&model, soft_keyboard.label_backspace);
    try std.testing.expectEqualStrings("h", model.doc.slice());
    tapSoftKey(&model, soft_keyboard.label_enter);
    try std.testing.expectEqualStrings("h\n", model.doc.slice());
    // Escape from the keyboard opens the minibuffer; typing there is a
    // command context, so the keyboard stays available.
    tapSoftKey(&model, soft_keyboard.label_escape);
    try std.testing.expectEqual(Mode.command, model.mode);
    try std.testing.expect(model.softKeyboardVisible());
    tapSoftKey(&model, 'h');
    tapSoftKey(&model, 'e');
    tapSoftKey(&model, 'l');
    tapSoftKey(&model, 'p');
    tapSoftKey(&model, soft_keyboard.label_enter);
    try std.testing.expectEqual(Mode.help, model.mode);
}

test "a physical keyboard hides the soft keyboard and touches fall through" {
    var model: Model = undefined;
    model.initInPlace();
    model.setPhysicalKeyboard(true);
    try std.testing.expect(!model.softKeyboardVisible());
    // With no keyboard on screen, the same tap is workspace navigation
    // (a document-screen touch goes home) and types nothing.
    tapSoftKey(&model, 'x');
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expectEqual(navigation.Screen.home, model.nav.screen);

    var detached: Model = undefined;
    detached.initInPlace();
    detached.setPhysicalKeyboard(true);
    detached.setPhysicalKeyboard(false);
    try std.testing.expect(detached.softKeyboardVisible());
    tapSoftKey(&detached, 'x');
    try std.testing.expectEqualStrings("x", detached.doc.slice());
}

test "dismissing the soft keyboard lasts only for the current input context" {
    var model: Model = undefined;
    model.initInPlace();
    tapSoftKey(&model, soft_keyboard.label_dismiss);
    try std.testing.expect(!model.softKeyboardVisible());
    // Moving to the minibuffer is a new context: the keyboard returns.
    model.handle(.escape);
    try std.testing.expectEqual(Mode.command, model.mode);
    try std.testing.expect(model.softKeyboardVisible());
}

test "bottom-edge flicks summon and dismiss the soft keyboard" {
    var model: Model = undefined;
    model.initInPlace();
    // Dismiss, then flick up from the bottom edge: the keyboard returns
    // without waiting for a context change.
    tapSoftKey(&model, soft_keyboard.label_dismiss);
    try std.testing.expect(!model.softKeyboardVisible());
    model.touchDown(640, soft_keyboard.space_height - 4);
    model.touch(640, soft_keyboard.space_height - 160);
    try std.testing.expect(model.softKeyboardVisible());
    // A flick down across the keyboard dismisses it again.
    model.touchDown(640, soft_keyboard.top + 30);
    model.touch(640, soft_keyboard.top + 190);
    try std.testing.expect(!model.softKeyboardVisible());
    try std.testing.expectEqualStrings("", model.doc.slice());
    // A short drag is not a gesture: the tap underneath still applies.
    model.touchDown(640, soft_keyboard.space_height - 4);
    model.touch(640, soft_keyboard.space_height - 30);
    try std.testing.expect(!model.softKeyboardVisible());
}

var test_mock_card = card.MockStore{};
fn testCardReadInputSupport() card.Error!i32 {
    test_mock_card.set("日本 太郎", "東京都千代田区霞が関1-1", "19850101", "1");
    return 1;
}
fn testCardInfoLookup(card_handle: i32) card.Error!card.Info {
    if (card_handle != 1 or !test_mock_card.active) return error.InvalidCardHandle;
    return .{
        .state = .ready,
        .name = test_mock_card.name_buf[0..test_mock_card.name_len],
        .address = test_mock_card.addr_buf[0..test_mock_card.addr_len],
        .birth = test_mock_card.birth_buf[0..test_mock_card.birth_len],
        .gender = test_mock_card.gender_buf[0..test_mock_card.gender_len],
        .photo_width = test_mock_card.photo_width,
        .photo_height = test_mock_card.photo_height,
        .photo_bytes = test_mock_card.photo_bytes,
    };
}
fn testCardDismissSession(card_handle: i32) card.Error!void {
    if (card_handle != 1) return error.InvalidCardHandle;
    test_mock_card.dismiss();
}
fn testCardReadPhotoSession(card_handle: i32, offset: u32, output: []u8) card.Error!void {
    _ = card_handle;
    _ = offset;
    _ = output;
}

const test_card_provider = card.Provider{
    .read_input_support = testCardReadInputSupport,
    .info = testCardInfoLookup,
    .dismiss = testCardDismissSession,
    .read_photo = testCardReadPhotoSession,
};

test "scheme can read card, inspect info, show declarative card view, and insert into document" {
    var model: Model = undefined;
    model.initInPlace();
    model.card = .{ .provider = &test_card_provider };

    // 1. (card/read!) -> handle=1
    model.evaluate("(define h (card/read!))", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);

    // 2. (card/info h) -> association list
    model.evaluate("(card/info h)", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);

    // 3. (view/card! h) -> card_view screen
    model.evaluate("(view/card! h)", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expectEqual(navigation.Screen.card_view, model.nav.screen);
    try std.testing.expect(model.nav.card.valid);
    try std.testing.expectEqualStrings("日本 太郎", model.nav.card.nameSlice());
    try std.testing.expectEqualStrings("東京都千代田区霞が関1-1", model.nav.card.addressSlice());

    // 4. Press Enter in card_view -> formatted string inserted into document and return to document
    model.handle(.enter);
    try std.testing.expectEqual(navigation.Screen.document, model.nav.screen);
    try std.testing.expectEqualStrings("氏名: 日本 太郎\n住所: 東京都千代田区霞が関1-1\n生年月日: 19850101\n", model.doc.slice());

    // 5. (card/dismiss! h) -> clears mock store
    model.evaluate("(card/dismiss! h)", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expect(!test_mock_card.active);
}

test "soft keyboard enters shifted text, symbols and moves the caret" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.screen = .document;
    tapSoftKey(&model, soft_keyboard.label_shift);
    tapSoftKey(&model, 'q');
    try std.testing.expectEqualStrings("Q", model.doc.slice());
    tapSoftKey(&model, soft_keyboard.label_symbols);
    // Hit a symbol key using the same active layout used by the renderer.
    var keys: [soft_keyboard.max_keys]soft_keyboard.KeyRect = undefined;
    for (soft_keyboard.layoutState(&keys, model.soft_keyboard_state)) |key| {
        if (key.label == '(') {
            model.touch(key.x + key.w / 2, key.y + key.h / 2);
            break;
        }
    }
    try std.testing.expectEqualStrings("Q(", model.doc.slice());
    tapSoftKey(&model, soft_keyboard.label_left);
    tapSoftKey(&model, soft_keyboard.label_backspace);
    try std.testing.expectEqualStrings("(", model.doc.slice());
}

test "soft keyboard ignores a drag across different keys" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.screen = .document;
    model.touchDown(10, soft_keyboard.top + 10);
    model.touch(150, soft_keyboard.top + 10);
    try std.testing.expectEqualStrings("", model.doc.slice());
    model.touchDown(10, soft_keyboard.top + 10);
    model.touch(10, soft_keyboard.top + 10);
    try std.testing.expectEqualStrings("q", model.doc.slice());
}

test "portrait keyboard touches type and dismiss in document mode" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.screen = .document;
    model.portrait_touch = true;
    var keys: [soft_keyboard.max_keys]soft_keyboard.KeyRect = undefined;
    for (soft_keyboard.layoutIn(&keys, model.soft_keyboard_state, .portrait)) |key| {
        if (key.label == 'q') {
            model.touchDown(key.x + key.w / 2, key.y + key.h / 2);
            model.touch(key.x + key.w / 2, key.y + key.h / 2);
            break;
        }
    }
    try std.testing.expectEqualStrings("q", model.doc.slice());
    const g = soft_keyboard.geometry(.portrait);
    model.touchDown(g.width / 2, g.top() + 10);
    model.touch(g.width / 2, g.top() + 110);
    try std.testing.expect(!model.softKeyboardVisible());
    model.touchDown(g.width / 2, g.height - 4);
    model.touch(g.width / 2, g.height - 110);
    try std.testing.expect(model.softKeyboardVisible());
}

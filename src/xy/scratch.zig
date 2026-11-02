//! RAM workspace over the shared xy Document and bounded Scheme runtime.
//! Normal boot uses render_session; render() retains a fixed-cell projection
//! for console fixtures. Storage uses copied provider requests; no shell access is exposed.
const std = @import("std");
pub const input = @import("../console/session_input.zig");
pub const scheme = @import("scheme_runtime.zig");
pub const document = @import("document.zig");
// Immutable presentation text follows the existing diagnostic font placement;
// host targets retain their ordinary read-only segment.
pub const help_text linksection(if (@import("builtin").os.tag == .freestanding) ".flash.rodata.display" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata") = "Type directly into *scratch*.\n\nArrows: move   Backspace: delete before\nCtrl-D: delete after   Ctrl-Z: undo\nEsc: minibuffer   Ctrl-C: cancel\n\nMinibuffer: Scheme expression or command\nCommands: log, mem, tasks, undo, forget-undo\nJapanese input: ime toggles SKK (in SKK: l=ASCII, q=katakana)\nEval source: eval-buffer   Reset VM: reset-scheme\n\nSave: (buffer/save! \"name\")\nLoad: (buffer/load! \"name\")\nStorage must be available.\n\nEnter or Esc: return to *scratch*".*;
pub const Doc = document.Document(4096, 256, 2048, 1, 64);
pub const camera = @import("camera.zig");
pub const card = @import("card.zig");
pub const soft_keyboard = @import("soft_keyboard.zig");
pub const ime_omni = @import("ime_omni.zig");
pub const system = @import("system_buffer.zig");
pub const navigation = @import("navigation.zig");
pub const Mode = enum { edit, command, help, system };
pub const Status = enum { none, buffer_full, undo_full, invalid_input, unknown_command, scheme_result, scheme_error, command_full, read_only, scheme_running, scheme_cancelling };

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
const status_6 linksection(scheme.data_section) = "Running Scheme (Ctrl-C to cancel)".*;
const status_7 linksection(scheme.data_section) = "Cancelling Scheme...".*;

pub const LearningSession = @import("learning_session.zig").Session;
/// CPU0-only terminal attachment. The producer keeps the cells and context
/// alive until detach; each snapshot is borrowed only for the current draw.
pub const TerminalPort = struct {
    pub const View = @import("render_protocol.zig").TerminalView;
    context: *anyopaque,
    snapshot: *const fn (*anyopaque, *View) bool,
    write: *const fn (*anyopaque, []const u8) bool,
    close: *const fn (*anyopaque) void,
};
/// Foreground-only private input sink. The owner must wipe its own state in
/// close and keep it alive until detach; input never enters document history.
pub const PrivateInputPort = struct {
    pub const View = @import("render_protocol.zig").PrivateInputView;
    context: *anyopaque,
    key: *const fn (*anyopaque, input.Key) bool,
    close: *const fn (*anyopaque) void,
    snapshot: *const fn (*anyopaque, *View) bool,
};
const DeferredTouchKind = enum { down, move, up, cancel };
pub const Model = struct {
    pub const TerminalPortType = TerminalPort;
    pub const PrivateInputPortType = PrivateInputPort;
    pub const PrivateInputKey = input.Key;
    camera: camera.Client,
    card: card.Client,
    storage_client: scheme.storage.Client,
    doc: Doc,
    nav: navigation.State,
    learning: ?*@import("learning_session.zig").Session,
    terminal: ?TerminalPort,
    private_input: ?PrivateInputPort,
    vm: scheme.Runtime,
    continuation: ScratchDispatch,
    continuation_authority: ScratchDispatchAuthority,
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
    deferred_touch: [8]struct { x: u32, y: u32, kind: DeferredTouchKind },
    deferred_touch_count: u8,
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
    touch_moved: bool,
    /// SKK composition state for the document screen. Starts in direct
    /// (ASCII) mode so existing editing is unchanged; the minibuffer
    /// command `ime` toggles Japanese input.
    ime: ime_omni.OmniIme,
    /// Candidate backend for the IME. Hosts may replace it (the sqld
    /// dictionary provider is a follow-up); null means no candidates.
    ime_provider: ?ime_omni.OmniProvider,

    pub fn initInPlace(self: *Model) linksection(scheme.code_section) void {
        @memset(std.mem.asBytes(self), 0);
        self.ime = .{ .mode = .direct };
        self.nav.chapter_count = .{ 3, 13, 3, 32 };
        self.doc.revision = 1;
        self.doc.next_group_id = 1;
        self.revision = 1;
        self.resetScheme();
    }
    /// Caller retains the context and cell storage until detach; no screen is
    /// made available without an attached, explicitly started backend.
    pub fn attachTerminal(self: *Model, port: TerminalPort) linksection(scheme.code_section) bool {
        if (self.terminal != null or self.private_input != null or self.vm.running) return false;
        self.terminal = port;
        self.mode = .edit;
        self.status = .none;
        self.changed();
        return true;
    }
    pub fn detachTerminal(self: *Model) linksection(scheme.code_section) void {
        const port = self.terminal orelse return;
        self.terminal = null;
        port.close(port.context);
        self.changed();
    }
    pub fn terminalSnapshot(self: *const Model, out: *TerminalPort.View) linksection(scheme.code_section) bool {
        const port = self.terminal orelse return false;
        return port.snapshot(port.context, out);
    }
    /// The CPU0 session owner calls this after output or a visible state change.
    pub fn terminalChanged(self: *Model) linksection(scheme.code_section) void {
        if (self.terminal != null) self.changed();
    }
    /// Do not consume or replay input collected before entering private mode.
    pub fn attachPrivateInput(self: *Model, port: PrivateInputPort) linksection(scheme.code_section) bool {
        if (self.nav.screen != .ssh or self.private_input != null or self.terminal != null or self.vm.running or self.deferred_count != 0 or self.deferred_serial_count != 0 or self.deferred_touch_count != 0 or self.deferred_overflow or self.utf8_length != 0 or self.serial.state != .idle) return false;
        std.crypto.secureZero(u8, std.mem.asBytes(&self.deferred));
        std.crypto.secureZero(u8, &self.deferred_serial);
        std.crypto.secureZero(u8, &self.deferred_serial_delta);
        std.crypto.secureZero(u8, &self.utf8);
        self.serial = .{};
        self.private_input = port;
        self.status = .none;
        self.changed();
        return true;
    }
    pub fn detachPrivateInput(self: *Model) linksection(scheme.code_section) void {
        const port = self.private_input orelse return;
        self.private_input = null;
        self.serial = .{};
        std.crypto.secureZero(u8, &self.utf8);
        self.utf8_length = 0;
        self.utf8_needed = 0;
        port.close(port.context);
        self.changed();
    }
    pub fn privateInputSnapshot(self: *const Model, out: *PrivateInputPort.View) linksection(scheme.code_section) bool {
        const port = self.private_input orelse return false;
        return port.snapshot(port.context, out);
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
            std.crypto.secureZero(u8, std.mem.asBytes(&self.deferred));
            std.crypto.secureZero(u8, &self.deferred_serial);
            std.crypto.secureZero(u8, &self.deferred_serial_delta);
            self.deferred_count = 0;
            self.deferred_serial_count = 0;
            self.deferred_touch_count = 0;
            self.deferred_overflow = false;
            self.serial = .{};
            self.utf8_length = 0;
            self.command_length = 0;
            self.touch_tracking = false;
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
        std.crypto.secureZero(u8, std.mem.asBytes(&self.deferred));
        std.crypto.secureZero(u8, &self.deferred_serial);
        std.crypto.secureZero(u8, &self.deferred_serial_delta);
        while (self.deferred_touch_count != 0) {
            const event = self.deferred_touch[0];
            self.deferred_touch_count -= 1;
            std.mem.copyForwards(@TypeOf(event), self.deferred_touch[0..self.deferred_touch_count], self.deferred_touch[1..][0..self.deferred_touch_count]);
            switch (event.kind) {
                .down => self.touchDownNow(event.x, event.y),
                .move => self.touchMoveNow(event.x, event.y),
                .up => self.touchNow(event.x, event.y),
                .cancel => self.touch_tracking = false,
            }
        }
    }
    pub fn insert(self: *Model, text: []const u8) linksection(scheme.code_section) void {
        if (self.private_input != null) {
            self.status = .invalid_input;
            self.changed();
            return;
        }
        if (self.terminal) |port| {
            self.status = if (port.write(port.context, text)) .none else .buffer_full;
            self.changed();
            return;
        }
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
    fn emptyImeQuery(_: *anyopaque, _: ime_omni.PrefixKind, _: u8, _: []const u8, _: *ime_omni.CandidateList) linksection(scheme.code_section) void {}

    fn imeProvider(self: *Model) linksection(scheme.code_section) ime_omni.OmniProvider {
        if (self.ime_provider) |provider| return provider;
        return .{ .ctx = self, .queryFn = emptyImeQuery };
    }

    fn imeKey(self: *Model, byte: u8) linksection(scheme.code_section) void {
        self.ime.handleKey(&self.doc, self.imeProvider(), byte) catch |err| {
            self.status = if (err == error.BufferFull) .buffer_full else .invalid_input;
        };
    }

    /// Routes one key through the IME while the document is being edited.
    /// Text and Backspace always go through it (direct mode is a plain
    /// passthrough, kana modes convert); Enter, Escape and Cancel only
    /// while a composition is active, so they keep their workspace
    /// meaning otherwise. Cursor and editing keys first cancel any
    /// composition, then fall through to their normal handling.
    fn imeRoute(self: *Model, key: input.Key) linksection(scheme.code_section) bool {
        if (self.mode != .edit) return false;
        const composing = self.ime.phase != .idle;
        switch (key) {
            .text => |byte| self.imeKey(byte),
            .backspace => self.imeKey(0x7f),
            .enter => {
                if (!composing) return false;
                self.imeKey('\n');
            },
            .escape, .cancel => {
                if (!composing) return false;
                self.imeKey(0x07);
            },
            else => {
                if (composing) self.imeKey(0x07);
                return false;
            },
        }
        return true;
    }

    pub fn handle(self: *Model, key: input.Key) linksection(scheme.code_section) void {
        if (self.private_input) |port| {
            if (self.vm.running or self.nav.screen != .ssh) {
                self.detachPrivateInput();
                self.status = .invalid_input;
                return;
            }
            self.status = if (port.key(port.context, key)) .none else .invalid_input;
            self.changed();
            return;
        }
        if (self.continuation.current != 0 and key == .cancel) {
            self.continuation.cancel(.{ .authority = self.continuation.authority.?, .serial = self.continuation.current }) catch |err| {
                self.schemeError(if (err == error.StaleContinuation) error.Busy else @errorCast(err));
                self.changed();
            };
            return;
        }
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
        if (self.terminal) |port| {
            var one: [1]u8 = undefined;
            const bytes: []const u8 = switch (key) {
                .text => |byte| blk: {
                    one[0] = byte;
                    break :blk &one;
                },
                .enter => "\r",
                .backspace => "\x7f",
                .left => "\x1b[D",
                .right => "\x1b[C",
                .up => "\x1b[A",
                .down => "\x1b[B",
                .escape => "\x1b",
                .cancel => "\x03",
                .eof => "\x04",
                .clear => "\x0c",
                .undo => "\x1a",
            };
            if (!port.write(port.context, bytes)) self.status = .buffer_full;
            return;
        }
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
        if (self.imeRoute(key)) return;
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
                    if (std.mem.eql(u8, text, "home")) self.nav.home() else if (std.mem.eql(u8, text, "ime")) {
                        self.ime.mode = if (self.ime.mode == .direct) .hiragana else .direct;
                    } else if (std.mem.eql(u8, text, "help")) self.mode = .help else if (std.mem.eql(u8, text, "reset-scheme")) self.resetScheme() else if (std.mem.eql(u8, text, "eval-buffer")) self.evaluate(self.doc.slice(), false) else if (text.len != 0) self.evaluate(text, text[0] != '(' and text[0] != '\'');
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
    /// The document and portrait learning exercise accept soft-key input.
    /// Zero indicates a screen with no soft-keyboard input context.
    fn softKeyboardContext(self: *const Model) u8 {
        if (self.private_input != null) return 6;
        if (self.terminal != null) return 5;
        if (self.nav.screen == .exercise and self.portrait_touch and self.learning != null) {
            return if (self.learning.?.editing_notes) 4 else 3;
        }
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

    /// Defer an orientation switch until the active contact and VM work end.
    /// A reflow preserves the current reading offset but discards old page
    /// boundaries, which were fitted to the previous viewport.
    pub fn applyKeyboardPresence(self: *Model, present: bool) linksection(scheme.code_section) bool {
        const portrait = !present;
        if (self.physical_keyboard == present and self.portrait_touch == portrait) return true;
        if (self.touch_tracking or self.vm.running) return false;
        self.setPhysicalKeyboard(present);
        if (self.portrait_touch != portrait) {
            self.portrait_touch = portrait;
            self.nav.end = 0;
            self.nav.previous_count = 0;
            self.changed();
        }
        return true;
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
        if (self.vm.running) return self.deferTouch(x, y, .down);
        if (self.deferred_touch_count != 0 or self.deferred_overflow) self.replayInput();
        self.touchDownNow(x, y);
    }
    fn touchDownNow(self: *Model, x: u32, y: u32) linksection(scheme.code_section) void {
        self.touch_start_x = x;
        self.touch_start_y = y;
        self.touch_tracking = true;
        self.touch_moved = false;
    }

    /// A drag may be a show/hide gesture, but must not become a key or card tap
    /// if it leaves the contact tolerance and returns before release.
    pub fn touchMove(self: *Model, x: u32, y: u32) linksection(scheme.code_section) void {
        if (self.vm.running) return self.deferTouch(x, y, .move);
        if (self.deferred_touch_count != 0 or self.deferred_overflow) self.replayInput();
        self.touchMoveNow(x, y);
    }
    fn touchMoveNow(self: *Model, x: u32, y: u32) linksection(scheme.code_section) void {
        if (!self.touch_tracking) return;
        const dx = @max(x, self.touch_start_x) - @min(x, self.touch_start_x);
        const dy = @max(y, self.touch_start_y) - @min(y, self.touch_start_y);
        if (dx > 24 or dy > 24) self.touch_moved = true;
    }

    pub fn touchCancel(self: *Model) linksection(scheme.code_section) void {
        if (self.vm.running) return self.deferTouch(0, 0, .cancel);
        if (self.deferred_touch_count != 0 or self.deferred_overflow) self.replayInput();
        self.touch_tracking = false;
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
        if (self.vm.running) return self.deferTouch(x, y, .up);
        if (self.deferred_touch_count != 0 or self.deferred_overflow) self.replayInput();
        self.touchNow(x, y);
    }
    fn touchNow(self: *Model, x: u32, y: u32) linksection(scheme.code_section) void {
        const tracked = self.touch_tracking;
        const start_x = self.touch_start_x;
        const start_y = self.touch_start_y;
        if (self.touchGesture(x, y)) return;
        if (tracked and self.touch_moved) return;
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
        if (self.terminal != null) return;
        if (self.nav.screen == .examples or self.nav.screen == .exercise) {
            if (self.learning) |l| {
                if (self.portrait_touch) l.touchPortrait(&self.nav, x, y, self.softKeyboardVisible()) else l.touch(&self.nav, x, y);
            }
        } else if (self.portrait_touch) {
            self.nav.touchPortrait(x, y, &self.vm.view);
        } else self.nav.touch(x, y, &self.vm.view);
        if (self.private_input != null and self.nav.screen != .ssh) self.detachPrivateInput();
        self.changed();
    }
    fn deferTouch(self: *Model, x: u32, y: u32, kind: DeferredTouchKind) linksection(scheme.code_section) void {
        if (self.deferred_touch_count == self.deferred_touch.len) {
            self.deferred_overflow = true;
            return;
        }
        self.deferred_touch[self.deferred_touch_count] = .{ .x = x, .y = y, .kind = kind };
        self.deferred_touch_count += 1;
    }
    pub fn hasContinuation(self: *const Model) bool {
        return self.continuation.current != 0;
    }
    pub fn continuationTick(self: *Model) linksection(scheme.code_section) void {
        if (!self.hasContinuation()) return;
        _ = self.continuation.poll(.{ .authority = self.continuation.authority.?, .serial = self.continuation.current }, 16) catch |err| {
            if (err == error.StaleContinuation) {
                self.schemeError(error.Busy);
                self.changed();
            }
        };
    }
    pub fn resetScheme(self: *Model) linksection(scheme.code_section) void {
        // A suspended evaluator owns the heap, including any partially
        // completed collection. Do not discard it through an external reset.
        if (self.vm.running) {
            self.schemeError(error.Busy);
            self.changed();
            return;
        }
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
    pub fn evaluationStackUnavailable(self: *Model) linksection(scheme.code_section) void {
        const text = "Evaluation stack unavailable";
        @memcpy(self.reply[0..text.len], text);
        self.reply_length = text.len;
        self.status = .scheme_error;
        self.changed();
    }
    pub fn evaluate(self: *Model, source: []const u8, named: bool) linksection(scheme.code_section) void {
        if (comptime @import("builtin").os.tag == .freestanding) return nih_xy_evaluate(self, source.ptr, source.len, named);
        self.evaluateOnStack(source, named);
    }
    extern fn nih_xy_evaluate(*Model, [*]const u8, usize, bool) void;
    pub fn evaluateOnStack(self: *Model, source: []const u8, named: bool) linksection(scheme.code_section) void {
        if (comptime @import("builtin").os.tag == .freestanding) {
            if (!named) {
                const selected = self.continuation.start(&self.continuation_authority, self, source) catch |err| {
                    self.schemeError(if (err == error.StaleContinuation) error.Busy else @errorCast(err));
                    self.changed();
                    return;
                };
                switch (selected) {
                    .pending => return,
                    .fallback => {},
                }
            }
        }
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
        if (self.private_input != null) {
            if (self.vm.running or self.nav.screen != .ssh) {
                self.detachPrivateInput();
                self.status = .invalid_input;
            } else if (byte >= 128) {
                self.status = .invalid_input;
                self.changed();
            } else if (self.serial.feed(byte, now)) |key| self.handle(key);
            return;
        }
        if (self.continuation.current != 0 and byte == 3) {
            self.continuation.cancel(.{ .authority = self.continuation.authority.?, .serial = self.continuation.current }) catch |err| {
                self.schemeError(if (err == error.StaleContinuation) error.Busy else @errorCast(err));
                self.changed();
            };
            return;
        }
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
            .scheme_running => &status_6,
            .scheme_cancelling => &status_7,
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

test "private input bypasses editor and deferred queues and clears on detach" {
    const Sink = struct {
        bytes: [16]u8 = @splat(0),
        length: usize = 0,
        closed: bool = false,
        fn key(ctx: *anyopaque, value: input.Key) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (value != .text or self.length == self.bytes.len) return false;
            self.bytes[self.length] = value.text;
            self.length += 1;
            return true;
        }
        fn close(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.crypto.secureZero(u8, &self.bytes);
            self.length = 0;
            self.closed = true;
        }
        fn snapshot(_: *anyopaque, _: *PrivateInputPort.View) bool {
            return false;
        }
    };
    // SAFETY: initInPlace initializes all model state.
    var model: Model = undefined;
    model.initInPlace();
    var sink: Sink = .{};
    const port = PrivateInputPort{ .context = &sink, .key = Sink.key, .close = Sink.close, .snapshot = Sink.snapshot };
    try std.testing.expect(!model.attachPrivateInput(port));
    model.nav.screen = .ssh;
    model.vm.running = true;
    try std.testing.expect(!model.attachPrivateInput(port));
    model.vm.running = false;
    model.deferred_touch_count = 1;
    try std.testing.expect(!model.attachPrivateInput(port));
    model.deferred_touch_count = 0;
    try std.testing.expect(model.attachPrivateInput(port));
    model.feedSerial('a', 0);
    model.feedHid(0, 5); // b
    model.handle(.{ .text = 'c' });
    try std.testing.expectEqualStrings("abc", sink.bytes[0..sink.length]);
    model.insert("not-private");
    model.feedSerial(0xc3, 0);
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expectEqual(@as(u16, 0), model.deferred_serial_count);
    try std.testing.expectEqual(@as(u8, 0), model.deferred_count);
    model.vm.running = true;
    model.feedSerial('x', 1);
    try std.testing.expect(sink.closed and model.private_input == null);
    try std.testing.expectEqual(@as(u16, 0), model.deferred_serial_count);
    for (sink.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    model.vm.running = false;
    sink.closed = false;
    model.setPhysicalKeyboard(true);
    try std.testing.expect(model.attachPrivateInput(port));
    model.feedSerial('s', 2);
    model.touch(10, 670);
    try std.testing.expectEqual(navigation.Screen.home, model.nav.screen);
    try std.testing.expect(sink.closed and model.private_input == null);
    for (sink.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "replayed and overflowed deferred input is erased" {
    // SAFETY: initInPlace initializes all model state.
    var model: Model = undefined;
    model.initInPlace();
    model.vm.running = true;
    model.feedSerial('a', 1);
    model.handle(.{ .text = 'b' });
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqualStrings("ab", model.doc.slice());
    for (model.deferred_serial) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (std.mem.asBytes(&model.deferred)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    model.vm.running = true;
    for (0..model.deferred_serial.len + 1) |_| model.feedSerial('x', 2);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqual(Status.invalid_input, model.status);
    for (model.deferred_serial) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (model.deferred_serial_delta) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

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

test "unavailable evaluation stack preserves the document and permits recovery" {
    var model: Model = undefined;
    model.initInPlace();
    model.insert("notes");
    model.evaluationStackUnavailable();
    try std.testing.expectEqual(Status.scheme_error, model.status);
    try std.testing.expectEqualStrings("Evaluation stack unavailable", model.reply[0..model.reply_length]);
    try std.testing.expectEqualStrings("notes", model.doc.slice());
    model.evaluateOnStack("(+ 20 22)", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expectEqualStrings("42", model.reply[0..model.reply_length]);
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

test "evaluation defers touch gestures and taps until the VM is idle" {
    var model: Model = undefined;
    model.initInPlace();
    model.vm.running = true;
    tapSoftKey(&model, 'x');
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expectEqual(@as(u8, 1), model.deferred_touch_count);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqualStrings("x", model.doc.slice());
    // A gesture may start before the VM becomes idle and end afterwards.
    tapSoftKey(&model, soft_keyboard.label_dismiss);
    model.vm.running = true;
    model.touchDown(640, soft_keyboard.space_height - 4);
    model.vm.running = false;
    model.touch(640, soft_keyboard.space_height - 160);
    try std.testing.expect(model.softKeyboardVisible());
    try std.testing.expectEqual(@as(u8, 0), model.deferred_touch_count);
    try std.testing.expect(!model.touch_tracking);
    // The reverse boundary keeps the pre-existing touch start until replay.
    tapSoftKey(&model, soft_keyboard.label_dismiss);
    model.touchDown(640, soft_keyboard.space_height - 4);
    model.vm.running = true;
    model.touch(640, soft_keyboard.space_height - 160);
    try std.testing.expect(!model.softKeyboardVisible());
    model.vm.running = false;
    model.replayInput();
    try std.testing.expect(model.softKeyboardVisible());
    try std.testing.expect(!model.touch_tracking);
}

test "deferred touch overflow drops the whole pending input batch" {
    var model: Model = undefined;
    model.initInPlace();
    model.vm.running = true;
    for (0..9) |_| tapSoftKey(&model, 'x');
    model.feedSerial('y', 0);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expectEqual(Status.invalid_input, model.status);
    try std.testing.expectEqual(@as(u8, 0), model.deferred_touch_count);
    try std.testing.expect(!model.touch_tracking);
}

test "deferred touch preserves drag and cancel across evaluation" {
    var model: Model = undefined;
    model.initInPlace();
    var rects: [soft_keyboard.max_keys]soft_keyboard.KeyRect = undefined;
    var x: u32 = 0;
    var y: u32 = 0;
    for (soft_keyboard.layout(&rects)) |rect| {
        if (rect.label == 'x') {
            x = rect.x + rect.w / 2;
            y = rect.y + rect.h / 2;
            break;
        }
    }
    try std.testing.expect(x != 0 and y != 0);
    model.vm.running = true;
    model.touchDown(x, y);
    model.touchMove(x + 50, y);
    model.touchMove(x, y);
    model.touch(x, y);
    try std.testing.expectEqualStrings("", model.doc.slice());
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expect(!model.touch_tracking);
    model.vm.running = true;
    model.touchDown(x, y);
    model.touchCancel();
    model.vm.running = false;
    model.replayInput();
    try std.testing.expect(!model.touch_tracking);
    try std.testing.expectEqualStrings("", model.doc.slice());
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

test "portrait home touch opens document and preserves portrait key input" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.home();
    model.portrait_touch = true;
    model.touchDown(navigation.State.portrait_home_x + 10, navigation.State.portrait_home_top + 10);
    model.touch(navigation.State.portrait_home_x + 10, navigation.State.portrait_home_top + 10);
    try std.testing.expectEqual(navigation.Screen.document, model.nav.screen);
    const g = soft_keyboard.geometry(.portrait);
    model.touchDown(10, g.top() + 10);
    model.touch(10, g.top() + 10);
    try std.testing.expectEqualStrings("q", model.doc.slice());
}

test "portrait exercise routes soft keys to lesson code and keeps toolbar reachable" {
    var model: Model = undefined;
    model.initInPlace();
    const lesson = try std.testing.allocator.create(LearningSession);
    defer std.testing.allocator.destroy(lesson);
    lesson.initInPlace();
    lesson.active_slot = 0;
    lesson.slots[0].used = true;
    lesson.slots[0].code.revision = 1;
    lesson.slots[0].code.next_group_id = 1;
    lesson.slots[0].notes.revision = 1;
    lesson.slots[0].notes.next_group_id = 1;
    model.learning = lesson;
    model.nav.screen = .exercise;
    model.portrait_touch = true;
    try std.testing.expect(model.softKeyboardVisible());
    const g = soft_keyboard.geometry(.portrait);
    model.touchDown(10, g.top() + 10);
    model.touch(10, g.top() + 10);
    try std.testing.expectEqualStrings("q", lesson.slots[0].code.slice());
    // The portrait toolbar sits immediately above the keyboard; Notes switches
    // the active input context without touching or running code.
    model.touchDown(650, 910);
    model.touch(650, 910);
    try std.testing.expect(lesson.editing_notes);
    model.touchDown(10, g.top() + 10);
    model.touch(10, g.top() + 10);
    try std.testing.expectEqualStrings("q", lesson.slots[0].notes.slice());
    try std.testing.expectEqualStrings("q", lesson.slots[0].code.slice());
}

test "a drag out and back cannot type but a bottom-edge flick still works" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.screen = .document;
    model.portrait_touch = true;
    const g = soft_keyboard.geometry(.portrait);
    model.touchDown(10, g.top() + 10);
    model.touchMove(200, g.top() + 10);
    model.touchMove(10, g.top() + 10);
    model.touch(10, g.top() + 10);
    try std.testing.expectEqualStrings("", model.doc.slice());
    model.touchDown(360, g.top() + 10);
    model.touchMove(360, g.top() + 110);
    model.touch(360, g.top() + 110);
    try std.testing.expect(!model.softKeyboardVisible());
}

const ImeMock = struct {
    learned: bool = false,
    fn query(_: *anyopaque, kind: ime_omni.PrefixKind, _: u8, key: []const u8, out: *ime_omni.CandidateList) void {
        if (kind == .kanji and std.mem.eql(u8, key, "かんじ")) _ = out.append("漢字", "");
    }
    fn learn(ctx: *anyopaque, _: []const u8, _: []const u8) void {
        const self: *ImeMock = @ptrCast(@alignCast(ctx));
        self.learned = true;
    }
};

fn typeKeys(model: *Model, keys: []const u8) void {
    for (keys) |byte| model.handle(.{ .text = byte });
}

fn runMinibuffer(model: *Model, command_text: []const u8) void {
    model.handle(.escape);
    typeKeys(model, command_text);
    model.handle(.enter);
}

test "IME defaults to direct ASCII and the ime command toggles SKK kana input" {
    var model: Model = undefined;
    model.initInPlace();
    try std.testing.expectEqual(ime_omni.InputMode.direct, model.ime.mode);
    typeKeys(&model, "abc");
    try std.testing.expectEqualStrings("abc", model.doc.slice());
    runMinibuffer(&model, "ime");
    try std.testing.expectEqual(ime_omni.InputMode.hiragana, model.ime.mode);
    try std.testing.expectEqual(Mode.edit, model.mode);
    typeKeys(&model, "kanji");
    try std.testing.expectEqualStrings("abcかんじ", model.doc.slice());
    // SKK's own `l` returns to direct input without the minibuffer.
    typeKeys(&model, "l");
    try std.testing.expectEqual(ime_omni.InputMode.direct, model.ime.mode);
    typeKeys(&model, "z");
    try std.testing.expectEqualStrings("abcかんじz", model.doc.slice());
}

test "SKK conversion runs through the workspace provider and learns the commit" {
    var model: Model = undefined;
    model.initInPlace();
    var mock = ImeMock{};
    model.ime_provider = .{ .ctx = &mock, .queryFn = ImeMock.query, .learnFn = ImeMock.learn };
    runMinibuffer(&model, "ime");
    typeKeys(&model, "Kanji"); // Uppercase starts the ▽ reading.
    try std.testing.expectEqual(ime_omni.OmniPhase.reading, model.ime.phase);
    try std.testing.expectEqualStrings("", model.doc.slice());
    typeKeys(&model, " ");
    try std.testing.expectEqual(ime_omni.OmniPhase.selecting, model.ime.phase);
    model.handle(.enter); // Commits the selected candidate, not a newline.
    try std.testing.expectEqualStrings("漢字", model.doc.slice());
    try std.testing.expectEqual(ime_omni.OmniPhase.idle, model.ime.phase);
    try std.testing.expect(mock.learned);
}

test "Escape cancels a composition instead of opening the minibuffer" {
    var model: Model = undefined;
    model.initInPlace();
    runMinibuffer(&model, "ime");
    typeKeys(&model, "Ka");
    try std.testing.expectEqual(ime_omni.OmniPhase.reading, model.ime.phase);
    model.handle(.escape);
    try std.testing.expectEqual(Mode.edit, model.mode);
    try std.testing.expectEqual(ime_omni.OmniPhase.idle, model.ime.phase);
    try std.testing.expectEqualStrings("", model.doc.slice());
    // With nothing composing, Escape opens the minibuffer as before.
    model.handle(.escape);
    try std.testing.expectEqual(Mode.command, model.mode);
}

test "SKK conversion powered by NfstDict seamlessly converts and commits" {
    const dict = @import("dict.zig");
    const nfst_bytes = @embedFile("fixtures/mini_nfst.bin");
    const nfst = try dict.NfstDict.init(nfst_bytes);

    var model: Model = undefined;
    model.initInPlace();
    model.ime_provider = nfst.omniProvider();

    runMinibuffer(&model, "ime");
    typeKeys(&model, "IKu"); // SKK okuri-ari: reading "い", okuri "く" (key "いk") -> auto-triggers conversion to "▼行く"
    try std.testing.expectEqual(ime_omni.OmniPhase.selecting, model.ime.phase);
    try std.testing.expectEqualStrings("▼行く", model.doc.preedit.slice());

    model.handle(.enter); // Commits "行く"
    try std.testing.expectEqual(ime_omni.OmniPhase.idle, model.ime.phase);
    try std.testing.expectEqualStrings("行く", model.doc.slice());
}

test "soft keyboard drives SKK composition and commits a candidate" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.screen = .document;
    var mock = ImeMock{};
    model.ime_provider = .{ .ctx = &mock, .queryFn = ImeMock.query, .learnFn = ImeMock.learn };
    runMinibuffer(&model, "ime");
    tapSoftKey(&model, soft_keyboard.label_shift);
    for ("kanji") |key| tapSoftKey(&model, key);
    try std.testing.expectEqual(ime_omni.OmniPhase.reading, model.ime.phase);
    tapSoftKey(&model, soft_keyboard.label_space);
    try std.testing.expectEqual(ime_omni.OmniPhase.selecting, model.ime.phase);
    tapSoftKey(&model, soft_keyboard.label_enter);
    try std.testing.expectEqualStrings("漢字", model.doc.slice());
    try std.testing.expect(mock.learned);
}

test "keyboard orientation switch waits for release and preserves the reading location" {
    var model: Model = undefined;
    model.initInPlace();
    model.nav.screen = .reading;
    model.nav.offset = 123;
    model.nav.end = 456;
    model.nav.previous_count = 1;
    model.portrait_touch = true;
    model.touchDown(100, 100);
    try std.testing.expect(!model.applyKeyboardPresence(true));
    try std.testing.expect(model.portrait_touch);
    model.touchCancel();
    const rev = model.revision;
    try std.testing.expect(model.applyKeyboardPresence(true));
    try std.testing.expect(!model.portrait_touch and model.physical_keyboard);
    try std.testing.expectEqual(@as(u32, 123), model.nav.offset);
    try std.testing.expectEqual(@as(u32, 0), model.nav.end);
    try std.testing.expectEqual(@as(u16, 0), model.nav.previous_count);
    try std.testing.expect(model.revision != rev);
    try std.testing.expect(model.applyKeyboardPresence(false));
    try std.testing.expect(model.portrait_touch and !model.physical_keyboard);
}

test "running evaluator defers editing and cancel until replay" {
    var model: Model = undefined;
    model.initInPlace();
    model.vm.running = true;
    model.handle(.{ .text = 'x' });
    model.handle(.cancel);
    try std.testing.expect(model.vm.running);
    try std.testing.expectEqualStrings("", model.doc.slice());
    try std.testing.expectEqual(@as(u8, 2), model.deferred_count);
    model.replayInput();
    try std.testing.expectEqual(@as(u8, 2), model.deferred_count);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqual(@as(u8, 0), model.deferred_count);
    try std.testing.expectEqualStrings("x", model.doc.slice());
}

// Ticketed dispatcher for a scratch evaluation. The authority must outlive
// all queued tickets issued from it.
const ScratchDispatchAuthority = struct {
    serial: u64 = 0,
    fn issue(self: *@This()) linksection(scheme.code_section) scheme.Error!u64 {
        if (self.serial == std.math.maxInt(u64)) return error.Overflow;
        self.serial += 1;
        return self.serial;
    }
};
const ScratchDispatch = struct {
    const Error = scheme.Error || error{StaleContinuation};
    const Ticket = struct { authority: *const ScratchDispatchAuthority, serial: u64 };
    const Begin = union(enum) { pending: Ticket, fallback };
    lease: scheme.SlicedContinuation = .{},
    authority: ?*const ScratchDispatchAuthority = null,
    model: ?*Model = null,
    current: u64 = 0,
    output: [128]u8 = @splat(0),

    fn start(self: *@This(), authority: *ScratchDispatchAuthority, model: *Model, source: []const u8) linksection(scheme.code_section) Error!Begin {
        if (self.current != 0 or model.vm.running) return error.Busy;
        const issued = try authority.issue();
        if (!try self.lease.begin(&model.vm, source)) {
            if (comptime @import("builtin").os.tag != .freestanding) model.evaluateOnStack(source, false);
            return .fallback;
        }
        self.current = issued;
        self.authority = authority;
        self.model = model;
        model.reply_length = 0;
        model.status = .scheme_running;
        model.changed();
        return .{ .pending = .{ .authority = authority, .serial = issued } };
    }
    fn authorized(self: *const @This(), ticket: Ticket) linksection(scheme.code_section) bool {
        return self.current != 0 and self.authority == ticket.authority and self.current == ticket.serial;
    }
    fn cancel(self: *@This(), ticket: Ticket) linksection(scheme.code_section) Error!void {
        if (!self.authorized(ticket)) return error.StaleContinuation;
        const model = self.model.?;
        self.lease.cancel();
        if (self.lease.cancel_pending) {
            model.status = .scheme_cancelling;
            model.changed();
            return;
        }
        self.current = 0;
        self.authority = null;
        self.model = null;
        model.reply_length = 0;
        model.status = .none;
        model.changed();
    }
    fn poll(self: *@This(), ticket: Ticket, quantum: usize) linksection(scheme.code_section) Error!bool {
        if (!self.authorized(ticket)) return error.StaleContinuation;
        const model = self.model.?;
        const result = self.lease.poll(model, quantum, 64, &self.output) catch |err| {
            self.current = 0;
            self.authority = null;
            self.model = null;
            model.schemeError(err);
            model.changed();
            return err;
        };
        if (result == null and self.lease.lease.owner == null) {
            self.current = 0;
            self.authority = null;
            self.model = null;
            model.reply_length = 0;
            model.status = .none;
            model.changed();
            return true;
        }
        if (result) |value| {
            @memcpy(model.reply[0..value.len], value);
            model.reply_length = value.len;
            model.status = .scheme_result;
            model.changed();
            self.current = 0;
            self.authority = null;
            self.model = null;
            return true;
        }
        return false;
    }
    fn key(self: *@This(), model: *Model, value: input.Key) linksection(scheme.code_section) Error!void {
        if (self.current != 0 and self.model == model and value == .cancel) {
            return self.cancel(.{ .authority = self.authority.?, .serial = self.current });
        }
        model.handle(value);
    }
    fn serial(self: *@This(), model: *Model, byte: u8, now: u64) linksection(scheme.code_section) Error!void {
        if (self.current != 0 and self.model == model and byte == 3) {
            return self.cancel(.{ .authority = self.authority.?, .serial = self.current });
        }
        model.feedSerial(byte, now);
    }
    fn hid(self: *@This(), model: *Model, modifiers: u8, usage: u8) linksection(scheme.code_section) Error!void {
        if (model.hid.feed(modifiers, usage)) |value| try self.key(model, value);
    }
};

test "scratch continuation dispatcher prioritizes cancel without weakening synchronous deferral" {
    var model: Model = undefined;
    model.initInPlace();
    var authority = ScratchDispatchAuthority{};
    var dispatch = ScratchDispatch{};
    model.evaluateOnStack("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1)))))", false);
    try std.testing.expectEqual(Status.scheme_result, model.status);
    const first = (try dispatch.start(&authority, &model, "(count 60)")).pending;
    try std.testing.expect(!try dispatch.poll(first, 7));
    try dispatch.key(&model, .{ .text = 'x' });
    try std.testing.expectEqual(@as(u8, 1), model.deferred_count);
    try std.testing.expectEqualStrings("", model.doc.slice());
    try dispatch.serial(&model, 3, 1000);
    try std.testing.expect(!model.vm.running and dispatch.current == 0);
    try std.testing.expectError(error.StaleContinuation, dispatch.poll(first, 7));
    model.replayInput();
    try std.testing.expectEqualStrings("x", model.doc.slice());
    const second = (try dispatch.start(&authority, &model, "(count 60)")).pending;
    try std.testing.expectError(error.StaleContinuation, dispatch.cancel(first));
    try std.testing.expect(!try dispatch.poll(second, 7));
    try dispatch.hid(&model, 1, 6); // Ctrl-C
    try std.testing.expect(!model.vm.running and dispatch.current == 0);
    const third = (try dispatch.start(&authority, &model, "(count 5)")).pending;
    while (!try dispatch.poll(third, 7)) {}
    try std.testing.expectEqual(Status.scheme_result, model.status);
    try std.testing.expectEqualStrings("5", model.reply[0..model.reply_length]);
    try std.testing.expectError(error.StaleContinuation, dispatch.poll(second, 7));
    try std.testing.expectEqualStrings("5", model.reply[0..model.reply_length]);
    const failing = (try dispatch.start(&authority, &model, "(car 5)")).pending;
    try std.testing.expectError(error.Type, dispatch.poll(failing, 100));
    try std.testing.expectEqual(Status.scheme_error, model.status);
    try std.testing.expectEqualStrings(scheme.message(error.Type), model.reply[0..model.reply_length]);
    try std.testing.expectError(error.StaleContinuation, dispatch.poll(failing, 7));
    try std.testing.expectEqualStrings(scheme.message(error.Type), model.reply[0..model.reply_length]);
    model.evaluateOnStack("(define marker 0)", false);
    try std.testing.expect((try dispatch.start(&authority, &model, "(begin (set! marker (+ marker 1)) marker)")) == .fallback);
    try std.testing.expectEqualStrings("1", model.reply[0..model.reply_length]);
    model.evaluateOnStack("marker", false);
    try std.testing.expectEqualStrings("1", model.reply[0..model.reply_length]);
    // Existing synchronous waits keep their deferral policy, including Ctrl-C.
    model.vm.running = true;
    try dispatch.serial(&model, 3, 2000);
    try dispatch.hid(&model, 1, 6);
    try std.testing.expect(model.vm.running);
    try std.testing.expectEqual(@as(u16, 1), model.deferred_serial_count);
    try std.testing.expectEqual(@as(u8, 1), model.deferred_count);
    model.vm.running = false;
    model.replayInput();
    try std.testing.expectEqual(@as(u16, 0), model.deferred_serial_count);
    try std.testing.expectEqual(@as(u8, 0), model.deferred_count);
    std.debug.print("SCRATCH_DISPATCH serial=cancel hid=cancel synchronous=deferred stale=reject\n", .{});
}

test "sliced scratch cancellation drains before releasing ticket" {
    var model: Model = undefined;
    model.initInPlace();
    var authority = ScratchDispatchAuthority{};
    var dispatch = ScratchDispatch{};
    var input_buf: [256]u8 = undefined;
    var f = std.Io.Writer.fixed(&input_buf);
    try f.writeAll("(define retained '( ");
    for (0..50) |_| try f.writeAll("0 ");
    try f.writeAll("))");
    model.evaluateOnStack(f.buffered(), false);
    for (0..6) |_| model.evaluateOnStack("(set! retained (append retained retained))", false);
    model.evaluateOnStack("(define (churn n acc) (if (= n 0) acc (churn (- n 1) (cons n acc)))) (define (nth xs n) (if (= n 0) (car xs) (nth (cdr xs) (- n 1))))", false);
    const ticket = (try dispatch.start(&authority, &model, "(nth (churn 180 '()) 20)")).pending;
    var polls: usize = 0;
    while (dispatch.lease.cursor == null and polls < 10000) : (polls += 1) _ = try dispatch.poll(ticket, 16);
    try std.testing.expect(dispatch.lease.cursor != null);
    try std.testing.expectEqualStrings("Running Scheme (Ctrl-C to cancel)", model.statusText());
    _ = try dispatch.poll(ticket, 16); // Collector is now partially progressed.
    model.resetScheme();
    try std.testing.expect(model.vm.running and dispatch.lease.cursor != null);
    try std.testing.expectEqualStrings(scheme.message(error.Busy), model.reply[0..model.reply_length]);
    try dispatch.key(&model, .{ .text = 'x' });
    try dispatch.serial(&model, 3, 1000);
    try std.testing.expect(dispatch.current != 0 and model.vm.running and dispatch.lease.cancel_pending);
    try std.testing.expectEqualStrings("Cancelling Scheme...", model.statusText());
    try std.testing.expectError(error.Busy, dispatch.start(&authority, &model, "42"));
    while (dispatch.current != 0 and polls < 20000) : (polls += 1) _ = try dispatch.poll(ticket, 16);
    try std.testing.expect(dispatch.current == 0 and !model.vm.running);
    try std.testing.expectError(error.StaleContinuation, dispatch.poll(ticket, 16));
    model.replayInput();
    try std.testing.expectEqualStrings("x", model.doc.slice());
    model.evaluateOnStack("(length retained)", false);
    try std.testing.expectEqualStrings("3200", model.reply[0..model.reply_length]);
    model.evaluateOnStack("(+ 20 22)", false);
    try std.testing.expectEqualStrings("42", model.reply[0..model.reply_length]);
    const normal = (try dispatch.start(&authority, &model, "(nth (churn 180 '()) 20)")).pending;
    polls = 0;
    while (dispatch.current != 0 and polls < 20000) : (polls += 1) _ = try dispatch.poll(normal, 16);
    try std.testing.expect(dispatch.current == 0);
    try std.testing.expectEqualStrings("21", model.reply[0..model.reply_length]);
    std.debug.print("SLICED_SCRATCH polls={d} replay=x retained=3200 recovery=42\n", .{polls});
}

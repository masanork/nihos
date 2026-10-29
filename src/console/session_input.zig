//! ASCII shell/menu input. Boot diagnostic keys keep their separate decoder.
const std = @import("std");
pub const Key = union(enum) { text: u8, enter, backspace, left, right, up, down, escape, cancel, eof, clear };

/// Preserve legacy colon-prefixed serial diagnostics only at an empty shell
/// prompt (or while an already-started diagnostic is being collected).
pub fn allowDiagnostic(session_active: bool, shell: bool, line_length: usize, collecting: bool) bool {
    return collecting or !session_active or (shell and line_length == 0);
}

pub const Hid = struct {
    caps: bool = false,
    pub fn feed(self: *Hid, modifiers: u8, usage: u8) ?Key {
        if (modifiers & 0xcc != 0) return null; // Alt/GUI are not text.
        if (usage == 0x39) {
            self.caps = !self.caps;
            return null;
        }
        if (modifiers & 0x11 != 0) return switch (usage) {
            0x06 => .cancel,
            0x07 => .eof,
            0x0f => .clear,
            else => null,
        };
        const shift = modifiers & 0x22 != 0;
        if (usage >= 4 and usage <= 29) return .{ .text = (if (shift != self.caps) @as(u8, 'A') else @as(u8, 'a')) + usage - 4 };
        if (usage >= 30 and usage <= 39) return .{ .text = (if (shift) "!@#$%^&*()" else "1234567890")[usage - 30] };
        return switch (usage) {
            0x28, 0x58 => .enter,
            0x29 => .escape,
            0x2a => .backspace,
            0x2c => .{ .text = ' ' },
            0x2d => .{ .text = if (shift) '_' else '-' },
            0x2e => .{ .text = if (shift) '+' else '=' },
            0x2f => .{ .text = if (shift) '{' else '[' },
            0x30 => .{ .text = if (shift) '}' else ']' },
            0x31 => .{ .text = if (shift) '|' else '\\' },
            0x33 => .{ .text = if (shift) ':' else ';' },
            0x34 => .{ .text = if (shift) '"' else '\'' },
            0x35 => .{ .text = if (shift) '~' else '`' },
            0x36 => .{ .text = if (shift) '<' else ',' },
            0x37 => .{ .text = if (shift) '>' else '.' },
            0x38 => .{ .text = if (shift) '?' else '/' },
            0x4f => if (modifiers == 0) .right else null,
            0x50 => if (modifiers == 0) .left else null,
            0x51 => .down,
            0x52 => .up,
            else => null,
        };
    }
};

pub const Serial = struct {
    state: enum { idle, escape, sequence } = .idle,
    started: u64 = 0,
    count: u8 = 0,
    cr: bool = false,
    pub fn expire(self: *Serial, now: u64) ?Key {
        if (self.state == .escape and now - self.started >= 30_000) {
            self.state = .idle;
            return .escape;
        }
        if (self.state == .sequence and now - self.started >= 100_000) self.state = .idle;
        return null;
    }
    pub fn feed(self: *Serial, byte: u8, now: u64) ?Key {
        switch (self.state) {
            .idle => {},
            .escape => {
                if (byte == '[' or byte == 'O') {
                    self.state = .sequence;
                    self.count = 0;
                    return null;
                }
                // A malformed escape is discarded, never replayed as a command.
                self.state = .idle;
                return .escape;
            },
            .sequence => {
                self.count +|= 1;
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = .idle;
                    if (self.count != 1) return null;
                    return switch (byte) {
                        'A' => .up,
                        'B' => .down,
                        'C' => .right,
                        'D' => .left,
                        else => null,
                    };
                }
                if (self.count >= 32) self.state = .idle;
                return null;
            },
        }
        const after_cr = self.cr;
        self.cr = byte == '\r';
        return switch (byte) {
            0x1b => blk: {
                self.state = .escape;
                self.started = now;
                break :blk null;
            },
            '\r' => .enter,
            '\n' => if (after_cr) null else .enter,
            8, 127 => .backspace,
            3 => .cancel,
            4 => .eof,
            12 => .clear,
            32...126 => .{ .text = byte },
            else => null,
        };
    }
};

test "serial CRLF executes once and arrows are not Escape" {
    var serial = Serial{};
    try std.testing.expectEqual(Key.enter, serial.feed('\r', 0).?);
    try std.testing.expect(serial.feed('\n', 1) == null);
    for ("\x1b[") |byte| try std.testing.expect(serial.feed(byte, 2) == null);
    try std.testing.expectEqual(Key.down, serial.feed('B', 3).?);
    try std.testing.expect(serial.expire(100_000) == null);
    try std.testing.expect(serial.feed(27, 100_000) == null);
    try std.testing.expect(serial.expire(129_999) == null);
    try std.testing.expectEqual(Key.escape, serial.expire(130_000).?);
    for ("\x1b[200~") |byte| try std.testing.expect(serial.feed(byte, 140_000) == null);
}

test "HID supports ASCII, Shift, Caps Lock and editing controls" {
    var hid = Hid{};
    try std.testing.expectEqual(@as(u8, 'a'), hid.feed(0, 4).?.text);
    try std.testing.expectEqual(@as(u8, 'A'), hid.feed(2, 4).?.text);
    try std.testing.expect(hid.feed(0, 0x39) == null);
    try std.testing.expectEqual(@as(u8, 'A'), hid.feed(0, 4).?.text);
    try std.testing.expectEqual(@as(u8, 'a'), hid.feed(0x20, 4).?.text);
    try std.testing.expectEqual(@as(u8, '!'), hid.feed(2, 30).?.text);
    try std.testing.expectEqual(Key.cancel, hid.feed(1, 6).?);
    try std.testing.expectEqual(Key.backspace, hid.feed(0, 0x2a).?);
    try std.testing.expect(hid.feed(4, 4) == null);
}

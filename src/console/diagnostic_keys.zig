//! Bounded diagnostic controls; never interprets text as shell commands.
const std = @import("std");
pub const Source = enum(u8) { serial = 1, tab5_keyboard, usb_keyboard, bluetooth_keyboard, touch };
pub fn capability(source: Source) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@backingInt(source) - 1));
}
pub const Action = enum(u8) { logs = 1, splash, pause, resume_boot };
pub fn hid(modifiers: u8, usage: u8) ?Action {
    if (usage == 0x29) return .logs;
    if (modifiers & 0x11 == 0 or modifiers & 0xcc != 0) return null;
    return switch (usage) {
        0x05 => .pause,
        0x0f => .splash,
        0x15 => .resume_boot,
        else => null,
    };
}
pub const Serial = struct {
    state: enum { idle, escape, sequence } = .idle,
    started: u64 = 0,
    count: u8 = 0,
    pub fn expire(self: *Serial, now: u64) ?Action {
        if (self.state == .escape and now - self.started >= 30_000) {
            self.state = .idle;
            return .logs;
        }
        if (self.state == .sequence and now - self.started >= 100_000) self.state = .idle;
        return null;
    }
    pub fn feed(self: *Serial, byte: u8, now: u64) ?Action {
        switch (self.state) {
            .idle => {},
            .escape => {
                if (byte == '[' or byte == 'O') {
                    self.state = .sequence;
                    self.count = 0;
                    return null;
                }
                self.state = if (byte == 0x1b) .escape else .idle;
                self.started = now;
                return .logs;
            },
            .sequence => {
                self.count +|= 1;
                if ((byte >= 0x40 and byte <= 0x7e) or self.count >= 32) self.state = .idle;
                return null;
            },
        }
        return switch (byte) {
            0x1b => blk: {
                self.state = .escape;
                self.started = now;
                break :blk null;
            },
            0x02 => .pause,
            0x0c => .splash,
            0x12 => .resume_boot,
            else => null,
        };
    }
};
test "HID controls are physical usages, not layout-dependent text" {
    try std.testing.expectEqual(Action.logs, hid(0, 0x29).?);
    try std.testing.expectEqual(Action.pause, hid(0x10, 0x05).?);
    try std.testing.expectEqual(Action.splash, hid(1, 0x0f).?);
    try std.testing.expectEqual(Action.resume_boot, hid(1, 0x15).?);
    try std.testing.expect(hid(0, 0x05) == null and hid(5, 0x05) == null);
}
test "serial arrows do not masquerade as standalone Escape" {
    var serial = Serial{};
    for ("\x1b[A") |byte| try std.testing.expect(serial.feed(byte, 0) == null);
    try std.testing.expect(serial.expire(100_000) == null);
    try std.testing.expect(serial.feed(0x1b, 100_000) == null);
    try std.testing.expect(serial.expire(129_999) == null);
    try std.testing.expectEqual(Action.logs, serial.expire(130_000).?);
    try std.testing.expect(serial.feed('r', 140_000) == null);
}

test "future transports share controls without consuming each other's capability bit" {
    try std.testing.expectEqual(@as(u8, 1), capability(.serial));
    try std.testing.expectEqual(@as(u8, 2), capability(.tab5_keyboard));
    try std.testing.expectEqual(@as(u8, 4), capability(.usb_keyboard));
    try std.testing.expectEqual(@as(u8, 8), capability(.bluetooth_keyboard));
}

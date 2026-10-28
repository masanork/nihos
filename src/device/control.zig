//! CPU0 foreground device requests. No hardware activity follows from parsing
//! ordinary UI keys, incomplete lines, or an overlong command.
const std = @import("std");
pub const Command = enum(u32) { audio = 1, microphone, rs485_loopback, rs485_peer, status };
pub const Parser = struct {
    buffer: [24]u8 = @splat(0),
    length: usize = 0,
    collecting: bool = false,
    overflow: bool = false,
    /// Returns true for bytes belonging to a colon-prefixed command line.
    pub fn feed(self: *Parser, byte: u8, result: *?Command) bool {
        result.* = null;
        if (!self.collecting) {
            if (byte != ':') return false;
            self.collecting = true;
            self.length = 0;
            self.overflow = false;
            return true;
        }
        if (byte == 0x1b) {
            self.collecting = false;
            return false; // Preserve the normal UI Escape action.
        }
        if (byte == '\r' or byte == '\n') {
            if (!self.overflow) {
                const line = self.buffer[0..self.length];
                inline for (.{ .{ "audio", Command.audio }, .{ "mic", Command.microphone }, .{ "rs485-loopback", Command.rs485_loopback }, .{ "rs485-peer", Command.rs485_peer }, .{ "devices", Command.status } }) |entry| {
                    if (std.mem.eql(u8, line, entry[0])) result.* = entry[1];
                }
            }
            self.collecting = false;
        } else if (self.length < self.buffer.len and !self.overflow) {
            self.buffer[self.length] = byte;
            self.length += 1;
        } else self.overflow = true;
        return true;
    }
};
pub const Owner = enum(u32) { none, audio, microphone };
/// A failed cleanup pins the controller and its storage until reboot. A quiet
/// terminal report is required before changing the shared I2S0/pin owner.
pub const Gate = struct {
    owner: Owner = .none,
    pinned: bool = false,
    pub fn acquire(self: *Gate, owner: Owner) bool {
        if (owner == .none or self.owner != .none or self.pinned) return false;
        self.owner = owner;
        return true;
    }
    pub fn release(self: *Gate, owner: Owner, clean: bool) bool {
        if (owner == .none or self.owner != owner or self.pinned) return false;
        if (!clean) {
            self.pinned = true;
            return false;
        }
        self.owner = .none;
        return true;
    }
};
test "only complete exact commands dispatch and overflow cannot become a command" {
    var parser: Parser = .{};
    var result: ?Command = null;
    try std.testing.expect(!parser.feed('a', &result));
    for (":audio") |c| {
        try std.testing.expect(parser.feed(c, &result));
        try std.testing.expect(result == null);
    }
    try std.testing.expect(parser.feed('\n', &result));
    try std.testing.expectEqual(Command.audio, result.?);
    for (":rs485-peer\r") |c| _ = parser.feed(c, &result);
    try std.testing.expectEqual(Command.rs485_peer, result.?);
    for (":audiooooooooooooooooooooooooooooo\n") |c| _ = parser.feed(c, &result);
    try std.testing.expect(result == null);
    for (":mic\n") |c| _ = parser.feed(c, &result);
    try std.testing.expectEqual(Command.microphone, result.?);
    for (":audio") |c| _ = parser.feed(c, &result);
    try std.testing.expect(!parser.feed(0x1b, &result));
    try std.testing.expect(!parser.feed('a', &result));
    for (":unknown\n") |c| _ = parser.feed(c, &result);
    try std.testing.expect(result == null);
}
test "shared I2S lease rejects overlap, wrong-owner cleanup and failed stop reuse" {
    var gate: Gate = .{};
    try std.testing.expect(!gate.acquire(.none));
    try std.testing.expect(gate.acquire(.audio));
    try std.testing.expect(!gate.acquire(.audio));
    try std.testing.expect(!gate.acquire(.microphone));
    try std.testing.expect(!gate.release(.microphone, true));
    try std.testing.expect(gate.release(.audio, true));
    try std.testing.expect(gate.acquire(.microphone));
    try std.testing.expect(!gate.release(.microphone, false));
    try std.testing.expect(!gate.release(.microphone, true));
    try std.testing.expect(!gate.acquire(.audio));
}

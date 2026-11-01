//! One-shot console start token for an explicit OTA fixture. The fixed token
//! identifies the candidate; it is not an authentication mechanism. The
//! caller must have verified image identity and own the serial/SDIO devices.
const std = @import("std");
pub const Error = error{ InvalidToken, Timeout, AlreadyFinished };
pub const Arm = struct {
    expected: [32]u8,
    deadline: u64,
    last_now: u64,
    length: usize = 0,
    bytes: [70]u8 = undefined,
    state: enum { waiting, armed, failed } = .waiting,

    pub fn init(digest: [32]u8, now: u64, deadline: u64) Error!Arm {
        if (deadline <= now) return error.Timeout;
        return .{ .expected = digest, .last_now = now, .deadline = deadline };
    }
    /// Feed exactly one complete command, with no replay after an outcome.
    pub fn feed(self: *Arm, byte: u8, now: u64) Error!bool {
        if (self.state != .waiting) return error.AlreadyFinished;
        errdefer self.state = .failed;
        if (now < self.last_now or now >= self.deadline) return error.Timeout;
        self.last_now = now;
        if (self.length >= self.bytes.len) return error.InvalidToken;
        self.bytes[self.length] = byte;
        self.length += 1;
        if (byte != '\n') {
            if (self.length == self.bytes.len) return error.InvalidToken;
            return false;
        }
        if (self.length != self.bytes.len or !std.mem.eql(u8, self.bytes[0..5], "OTA1 ")) return error.InvalidToken;
        const alphabet = "0123456789abcdef";
        for (self.expected, 0..) |value, i| {
            if (self.bytes[5 + i * 2] != alphabet[value >> 4] or self.bytes[6 + i * 2] != alphabet[value & 15]) return error.InvalidToken;
        }
        self.state = .armed;
        return true;
    }
};

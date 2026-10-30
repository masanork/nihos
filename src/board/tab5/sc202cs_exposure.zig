//! Bounded manual SC202CS exposure setup before stream-on.
//! Encoding and limits cross-checked against the existing MeOS Tab5 camera
//! driver (register facts only). Caller owns the powered, configured sensor.
const std = @import("std");
const address: u8 = 0x36;
const registers = [_]u16{ 0x3e00, 0x3e01, 0x3e02 };
pub const State = enum { idle, writing, reading, done, failed };
pub const Fault = enum { none, transport, readback };
pub const Driver = struct {
    state: State = .idle,
    fault: Fault = .none,
    lines: u16 = 0,
    index: usize = 0,
    pub fn start(self: *Driver, lines: u16) bool {
        if (self.state != .idle or lines < 8 or lines > 0x4dc) return false;
        self.lines = lines;
        self.state = .writing;
        return true;
    }
    fn value(self: *const Driver, index: usize) u8 {
        return switch (index) {
            0 => @intCast((self.lines >> 12) & 0xf),
            1 => @truncate(self.lines >> 4),
            2 => @truncate(self.lines << 4),
            else => unreachable,
        };
    }
    /// At most one I2C transaction per call; any unconfirmed write/read fails.
    pub fn poll(self: *Driver, bus: anytype) void {
        if (self.state != .writing and self.state != .reading) return;
        const reg = registers[self.index];
        const prefix = [_]u8{ @truncate(reg >> 8), @truncate(reg) };
        if (self.state == .writing) {
            bus.transfer(address, &.{ prefix[0], prefix[1], self.value(self.index) }, &.{}) catch {
                self.fault = .transport;
                self.state = .failed;
                return;
            };
        } else {
            var read: [1]u8 = undefined;
            bus.transfer(address, &prefix, &read) catch {
                self.fault = .transport;
                self.state = .failed;
                return;
            };
            if (read[0] != self.value(self.index)) {
                self.fault = .readback;
                self.state = .failed;
                return;
            }
        }
        self.index += 1;
        if (self.index == registers.len) {
            self.index = 0;
            self.state = if (self.state == .writing) .reading else .done;
        }
    }
};
const Fake = struct {
    regs: [3]u8 = @splat(0),
    calls: u8 = 0,
    fail_at: u8 = 0,
    corrupt: bool = false,
    pub fn transfer(self: *Fake, dev: u8, w: []const u8, out: []u8) error{Nack}!void {
        self.calls += 1;
        if (self.calls == self.fail_at or dev != address or w.len < 2 or w[0] != 0x3e or w[1] > 2) return error.Nack;
        if (w.len == 3 and out.len == 0) self.regs[w[1]] = w[2] else if (w.len == 2 and out.len == 1) out[0] = self.regs[w[1]] ^ @as(u8, @intFromBool(self.corrupt)) else return error.Nack;
    }
};
test "encode and verify bounded exposure, one transaction per poll" {
    var d: Driver = .{};
    var b: Fake = .{};
    try std.testing.expect(!d.start(7));
    try std.testing.expect(!d.start(0x4dd));
    try std.testing.expect(d.start(0x100));
    for (0..6) |_| {
        const old = b.calls;
        d.poll(&b);
        try std.testing.expectEqual(old + 1, b.calls);
    }
    try std.testing.expectEqual(State.done, d.state);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x10, 0 }, &b.regs);
}
test "transport and incorrect readback never report success" {
    for (1..7) |n| {
        var d: Driver = .{};
        var b: Fake = .{ .fail_at = @intCast(n) };
        _ = d.start(0x100);
        for (0..6) |_| d.poll(&b);
        try std.testing.expectEqual(State.failed, d.state);
        try std.testing.expectEqual(Fault.transport, d.fault);
    }
    var d: Driver = .{};
    var b: Fake = .{ .corrupt = true };
    _ = d.start(0x100);
    for (0..6) |_| d.poll(&b);
    try std.testing.expectEqual(Fault.readback, d.fault);
}

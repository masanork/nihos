//! Single-owner, one-I2C-transaction-per-poll SC202CS mode preparation.
//! Power, stable clock, ID verification and later CSI ownership are caller duties.
//! Never enables streaming. Failure must be followed by board power cleanup.
const std = @import("std");
const table = @import("sc202cs_720p_table.zig");
comptime {
    if (table.entries[0].address != 0x0103 or table.entries[0].value != 0x01)
        @compileError("sensor reset delay assumes reset is the first write");
}
pub const address: u8 = 0x36;
pub const State = enum { idle, writing, verifying, ready, failed };
pub const Fault = enum { none, transport, readback };
pub const Driver = struct {
    state: State = .idle,
    fault: Fault = .none,
    index: usize = 0,
    verified: usize = 0,
    pub fn start(self: *Driver) bool {
        if (self.state != .idle) return false;
        self.state = .writing;
        return true;
    }
    pub fn poll(self: *Driver, bus: anytype) void {
        switch (self.state) {
            .writing => {
                const entry = table.entries[self.index];
                bus.transfer(address, &.{ @truncate(entry.address >> 8), @truncate(entry.address), entry.value }, &.{}) catch {
                    self.state = .failed;
                    self.fault = .transport;
                    return;
                };
                self.index += 1;
                if (self.index == table.entries.len) self.state = .verifying;
            },
            .verifying => {
                const regs = [_]u16{ 0x0100, 0x3208, 0x3209, 0x320a, 0x320b };
                const expected = [_]u8{ 0, 0x05, 0, 0x02, 0xd0 };
                const reg = regs[self.verified];
                var bytes: [1]u8 = undefined;
                bus.transfer(address, &.{ @truncate(reg >> 8), @truncate(reg) }, &bytes) catch {
                    self.state = .failed;
                    self.fault = .transport;
                    return;
                };
                if (bytes[0] != expected[self.verified]) {
                    self.state = .failed;
                    self.fault = .readback;
                    return;
                }
                self.verified += 1;
                if (self.verified == regs.len) self.state = .ready;
            },
            else => {},
        }
    }
};
const Fake = struct {
    regs: [65536]u8 = @splat(0),
    count: usize = 0,
    fail_at: ?usize = null,
    wrong_read: bool = false,
    pub fn transfer(self: *Fake, dev: u8, write: []const u8, read: []u8) error{Nack}!void {
        if (dev != address or write.len < 2) return error.Nack;
        self.count += 1;
        if (self.fail_at == self.count) return error.Nack;
        const reg = (@as(u16, write[0]) << 8) | write[1];
        if (write.len == 3 and read.len == 0) self.regs[reg] = write[2] else if (write.len == 2 and read.len == 1) read[0] = if (self.wrong_read) 0xff else self.regs[reg] else return error.Nack;
    }
};
test "complete table then verify dimensions and stream-off in bounded steps" {
    var bus: Fake = .{};
    var driver: Driver = .{};
    try std.testing.expect(driver.start());
    try std.testing.expect(!driver.start());
    while (driver.state != .ready) {
        const count = bus.count;
        driver.poll(&bus);
        try std.testing.expectEqual(count + 1, bus.count);
        try std.testing.expect(driver.state != .failed);
    }
    try std.testing.expectEqual(table.entries.len + 5, bus.count);
    try std.testing.expectEqual(@as(u8, 0), bus.regs[0x0100]);
}
test "failure stops further traffic and never reports ready" {
    var bus: Fake = .{ .fail_at = 8 };
    var driver: Driver = .{};
    _ = driver.start();
    while (driver.state == .writing) driver.poll(&bus);
    try std.testing.expectEqual(Fault.transport, driver.fault);
    const count = bus.count;
    driver.poll(&bus);
    try std.testing.expectEqual(count, bus.count);
    bus = .{ .wrong_read = true };
    driver = .{};
    _ = driver.start();
    while (driver.state == .writing or driver.state == .verifying) driver.poll(&bus);
    try std.testing.expectEqual(Fault.readback, driver.fault);
}

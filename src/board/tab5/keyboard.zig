//! Standard Tab5 Keyboard, Ext.Port1 I2C 0x6d. No USB, SD or global bus owner.
//! Register definitions: M5Unit-KEYBOARD unit_Tab5Keyboard.hpp (MIT).
const std = @import("std");
pub const Event = struct { modifiers: u8, usage: u8 };
pub const Report = struct { status: u32 = 0, firmware: u32 = 0, mode: u32 = 0, presses: u32 = 0, releases: u32 = 0, malformed: u32 = 0 };
pub fn Keyboard(comptime Bus: type) type {
    return struct {
        bus: *Bus,
        report: Report = .{},
        const Self = @This();
        fn read(self: *Self, register: u8, bytes: []u8) !void {
            try self.bus.transfer(0x6d, &.{register}, bytes);
        }
        pub fn begin(self: *Self) !bool {
            var value: [1]u8 = .{0};
            self.read(0xfe, &value) catch |err| {
                if (err == error.AddressNack) {
                    self.report.status = 2;
                    return false;
                }
                return err;
            };
            self.report.firmware = value[0];
            try self.read(0xff, &value); // Read the address; NEVER write persistent address settings.
            if (value[0] != 0x6d) return error.UnsupportedKeyboard;
            try self.read(0x10, &value);
            if (value[0] > 2) return error.UnsupportedKeyboard;
            if (value[0] != 1) try self.bus.transfer(0x6d, &.{ 0x10, 1 }, &.{});
            try self.read(0x10, &value);
            if (value[0] != 1) return error.KeyboardMode;
            // Do not clear events queued while the CPU was booting.
            self.report.mode = 1;
            self.report.status = 1;
            return true;
        }
        /// Caller polls outside interrupts; never drain more than four events.
        pub fn poll(self: *Self, output: *[4]Event) !usize {
            if (self.report.status != 1) return 0;
            var count: [1]u8 = .{0};
            try self.read(0x02, &count);
            if (count[0] > 32) return error.KeyboardQueue;
            var found: usize = 0;
            for (0..@min(count[0], 4)) |_| {
                var event: [2]u8 = undefined;
                try self.read(0x30, &event);
                if (event[0] == 0xff and event[1] == 0xff) break;
                if (event[1] == 0) {
                    self.report.releases +|= 1;
                    continue;
                }
                if (event[1] <= 3 or event[1] >= 0xe0) {
                    self.report.malformed +|= 1;
                    continue;
                }
                output[found] = .{ .modifiers = event[0], .usage = event[1] };
                found += 1;
                self.report.presses +|= 1;
            }
            return found;
        }
    };
}
const Model = struct {
    mode: u8 = 0,
    absent: bool = false,
    writes: u32 = 0,
    next: usize = 0,
    events: [6]Event = .{ .{ .modifiers = 0, .usage = 0x29 }, .{ .modifiers = 1, .usage = 5 }, .{ .modifiers = 0, .usage = 0 }, .{ .modifiers = 0, .usage = 1 }, .{ .modifiers = 0, .usage = 0x0f }, .{ .modifiers = 0, .usage = 0x15 } },
    pub fn transfer(self: *Model, address: u8, write: []const u8, read: []u8) !void {
        try std.testing.expectEqual(@as(u8, 0x6d), address);
        if (self.absent) return error.AddressNack;
        if (write.len == 2) {
            try std.testing.expectEqualSlices(u8, &.{ 0x10, 1 }, write);
            self.mode = write[1];
            self.writes += 1;
            return;
        }
        switch (write[0]) {
            0xfe => read[0] = 1,
            0xff => read[0] = 0x6d,
            0x10 => read[0] = self.mode,
            0x02 => read[0] = @intCast(self.events.len - self.next),
            0x30 => {
                read[0] = self.events[self.next].modifiers;
                read[1] = self.events[self.next].usage;
                self.next += 1;
            },
            else => return error.UnexpectedRegister,
        }
    }
};
test "keyboard retains queued Escape and bounds each drain without persistent writes" {
    var bus = Model{};
    var keyboard = Keyboard(Model){ .bus = &bus };
    try std.testing.expect(try keyboard.begin());
    try std.testing.expectEqual(@as(u32, 1), bus.writes);
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), try keyboard.poll(&events));
    try std.testing.expectEqual(@as(u8, 0x29), events[0].usage);
    try std.testing.expectEqual(@as(usize, 4), bus.next);
    try std.testing.expectEqual(@as(u32, 1), keyboard.report.releases);
    try std.testing.expectEqual(@as(usize, 2), try keyboard.poll(&events));
    var missing = Model{ .absent = true };
    var absent = Keyboard(Model){ .bus = &missing };
    try std.testing.expect(!try absent.begin());
    try std.testing.expectEqual(@as(u32, 0), missing.writes);
}

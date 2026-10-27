//! RX8130CE calendar, independently implemented from Epson ETM50E-10.
//! All APIs require exclusive ownership of the shared board I2C bus.
const std = @import("std");
pub const address = 0x32;
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    weekday: u3, // Sunday=0. RTC stores a one-hot week counter.
    hour: u8,
    minute: u8,
    second: u8,
    pub fn validate(self: DateTime) error{InvalidCalendar}!void {
        if (self.year < 2000 or self.year > 2099 or self.month == 0 or self.month > 12 or self.weekday > 6 or self.hour > 23 or self.minute > 59 or self.second > 59) return error.InvalidCalendar;
        const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const max = days[self.month - 1] + @as(u8, @intFromBool(self.month == 2 and self.year % 4 == 0));
        if (self.day == 0 or self.day > max) return error.InvalidCalendar;
    }
};
fn bcd(value: u8) error{InvalidCalendar}!u8 {
    if (value & 15 > 9 or value >> 4 > 9) return error.InvalidCalendar;
    return (value >> 4) * 10 + (value & 15);
}
fn encode(value: u8) u8 {
    return ((value / 10) << 4) | (value % 10);
}
pub const Sample = struct {
    registers: [16]u8,
    pub fn calendar(self: Sample) !DateTime {
        if (self.registers[13] & 2 != 0) return error.VoltageLow;
        if (self.registers[14] & 0xc0 != 0) return error.Stopped;
        const r = self.registers;
        if (r[3] == 0 or r[3] & 0x80 != 0 or @popCount(r[3]) != 1) return error.InvalidCalendar;
        const result = DateTime{ .year = 2000 + @as(u16, try bcd(r[6])), .month = try bcd(r[5]), .day = try bcd(r[4]), .weekday = @intCast(@ctz(r[3])), .hour = try bcd(r[2]), .minute = try bcd(r[1]), .second = try bcd(r[0]) };
        try result.validate();
        return result;
    }
};
/// Continuous auto-increment read latches calendar carry until STOP on I2C.
/// No RTC STOP-bit writes, flag clears, or implicit host/build-time setting.
pub fn read(bus: anytype) !Sample {
    // SAFETY: successful transfer fills all registers; errors propagate first.
    var result: Sample = undefined;
    try bus.transfer(address, &.{0x10}, &result.registers);
    return result;
}
/// Explicit calendar operation only. Preserves alarm, timer and battery setup.
/// Failed writes attempt to leave STOP asserted, so partial calendars cannot
/// qualify as a running clock. Power/backup initialization is a
/// separate board policy and is deliberately not inferred by this driver.
pub fn set(bus: anytype, value: DateTime) !void {
    try value.validate();
    const before = try read(bus);
    // VLF requires full board-selected register/battery initialization per
    // Epson. A calendar-only write must not clear it and claim recovery.
    if (before.registers[13] & 2 != 0) return error.NeedsInitialization;
    const control = before.registers[14];
    if (control & 0x80 != 0) return error.TestMode;
    try bus.transfer(address, &.{ 0x1e, control | 0x40 }, &.{});
    writeStopped(bus, value, control) catch |err| {
        bus.transfer(address, &.{ 0x1e, control | 0x40 }, &.{}) catch return error.StopFailed;
        return err;
    };
}
fn writeStopped(bus: anytype, value: DateTime, control: u8) !void {
    const bytes = [_]u8{ 0x10, encode(value.second), encode(value.minute), encode(value.hour), @as(u8, 1) << value.weekday, encode(value.day), encode(value.month), encode(@intCast(value.year - 2000)) };
    try bus.transfer(address, &bytes, &.{});
    try bus.transfer(address, &.{ 0x1e, control & ~@as(u8, 0x40) }, &.{});
    _ = try (try read(bus)).calendar();
}

test "RTC rejects low voltage, stopped clocks, corrupt BCD and impossible dates" {
    var sample = Sample{ .registers = @splat(0) };
    sample.registers[0..7].* = .{ 0x59, 0x58, 0x23, 4, 0x29, 2, 0x24 };
    try std.testing.expectEqual(@as(u16, 2024), (try sample.calendar()).year);
    sample.registers[6] = 0x25;
    try std.testing.expectError(error.InvalidCalendar, sample.calendar());
    sample.registers[4] = 0x28;
    sample.registers[0] = 0x5a;
    try std.testing.expectError(error.InvalidCalendar, sample.calendar());
    sample.registers[0] = 0;
    sample.registers[3] = 3;
    try std.testing.expectError(error.InvalidCalendar, sample.calendar());
    sample.registers[3] = 1;
    sample.registers[13] = 2;
    try std.testing.expectError(error.VoltageLow, sample.calendar());
    sample.registers[13] = 0;
    sample.registers[14] = 0x40;
    try std.testing.expectError(error.Stopped, sample.calendar());
}

test "RTC burst read is coherent and never writes calendar or flags" {
    const Bus = struct {
        calls: u32 = 0,
        fn transfer(self: *@This(), addr: u7, write: []const u8, out: []u8) !void {
            try std.testing.expectEqual(@as(u7, address), addr);
            try std.testing.expectEqualSlices(u8, &.{0x10}, write);
            try std.testing.expectEqual(@as(usize, 16), out.len);
            @memset(out, 0);
            self.calls += 1;
        }
    };
    var bus: Bus = .{};
    _ = try read(&bus);
    try std.testing.expectEqual(@as(u32, 1), bus.calls);
}

test "RTC explicit setting preserves control and flags; partial writes leave STOP asserted" {
    const Bus = struct {
        control: u8 = 0x28,
        regs: [16]u8 = @splat(0),
        writes: u32 = 0,
        fail_calendar: bool = false,
        fn transfer(self: *@This(), _: u7, write: []const u8, out: []u8) !void {
            if (out.len != 0) {
                if (write[0] == 0x1e) out[0] = self.control else {
                    @memcpy(out, &self.regs);
                    out[14] = self.control;
                }
            } else {
                self.writes += 1;
                switch (write[0]) {
                    0x1e => self.control = write[1],
                    0x1d => self.regs[13] &= write[1],
                    0x10 => {
                        if (self.fail_calendar) return error.Nack;
                        @memcpy(self.regs[0..7], write[1..]);
                    },
                    else => return error.UnexpectedWrite,
                }
            }
        }
    };
    const date = DateTime{ .year = 2026, .month = 10, .day = 27, .weekday = 2, .hour = 12, .minute = 34, .second = 56 };
    var bus = Bus{};
    bus.regs[13] = 0x38;
    try set(&bus, date);
    try std.testing.expectEqual(@as(u8, 0x28), bus.control);
    try std.testing.expectEqual(@as(u8, 0x38), bus.regs[13]);
    try std.testing.expectEqual(@as(u8, 0x26), bus.regs[6]);
    bus.fail_calendar = true;
    try std.testing.expectError(error.Nack, set(&bus, date));
    try std.testing.expect(bus.control & 0x40 != 0);
    try std.testing.expectError(error.Stopped, (try read(&bus)).calendar());
    const before = bus.writes;
    var invalid = date;
    invalid.month = 13;
    try std.testing.expectError(error.InvalidCalendar, set(&bus, invalid));
    try std.testing.expectEqual(before, bus.writes);
    bus.regs[13] |= 2;
    try std.testing.expectError(error.NeedsInitialization, set(&bus, date));
    try std.testing.expectEqual(before, bus.writes);
}

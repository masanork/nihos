//! Boot-only I2C on GPIO31/32. Exclusive CPU0 ownership before CPU1 release.
//! Open drain is implemented by driving low or releasing the output driver.
//! Ordinary transfers never recover a busy bus. The sole boot owner can
//! explicitly clear retained SDA-low with at most nine clocks (UM10204 3.1.16).
const std = @import("std");
pub const Error = error{ InvalidTransfer, ClockTimeout, BusBusy, AddressNack, ReadAddressNack, Nack, ArbitrationLost, Timer };
pub const sda = 31;
pub const scl = 32;

/// Remove USB-A power without resetting the shared expander or other pins.
/// Verify the enable latch, output direction and high-impedance control.
pub fn usbPowerOff(bus: anytype) !void {
    for ([_]u8{ 0x05, 0x07, 0x03 }) |register| {
        var previous: [1]u8 = .{0};
        try bus.transfer(0x44, &.{register}, &previous);
        const value = if (register == 3) previous[0] | 8 else previous[0] & ~@as(u8, 8);
        try bus.transfer(0x44, &.{ register, value }, &.{});
        var readback: [1]u8 = .{0};
        try bus.transfer(0x44, &.{register}, &readback);
        if (readback[0] != value) return error.Readback;
    }
    if (!bus.pins.delay(250_000)) return error.Timer;
}

/// Exclusive boot diagnostic only: reset the USB-A reader's retained state.
pub fn usbPowerCycle(bus: anytype) !void {
    var saved: [3]u8 = @splat(0);
    const registers = [_]u8{ 0x05, 0x03, 0x07 };
    for (registers, 0..) |register, index| try bus.transfer(0x44, &.{register}, saved[index..][0..1]);
    try bus.transfer(0x44, &.{ 0x05, saved[0] & 0xf7 }, &.{});
    try bus.transfer(0x44, &.{ 0x03, saved[1] | 8 }, &.{});
    try bus.transfer(0x44, &.{ 0x07, saved[2] & 0xf7 }, &.{});
    if (!bus.pins.delay(250_000)) return error.Timer;
    try bus.transfer(0x44, &.{ 0x05, saved[0] | 8 }, &.{});
    if (!bus.pins.delay(100_000)) return error.Timer;
}

const PowerModel = struct {
    values: [3]u8 = .{ 0xa5, 0x55, 0xaa },
    waits: [2]u32 = @splat(0),
    next: usize = 0,
    pins: *PowerModel,
    drop: bool = false,
    pub fn transfer(self: *@This(), address: u8, write: []const u8, read: []u8) !void {
        try std.testing.expectEqual(@as(u8, 0x44), address);
        const index: usize = switch (write[0]) {
            5 => 0,
            3 => 1,
            7 => 2,
            else => return error.InvalidTransfer,
        };
        if (read.len == 1) read[0] = self.values[index] else if (!self.drop) self.values[index] = write[1];
    }
    pub fn delay(self: *@This(), microseconds: u32) bool {
        self.waits[self.next] = microseconds;
        if (self.next == 0 and self.values[0] & 8 != 0) return false;
        if (self.next == 1 and self.values[0] & 8 == 0) return false;
        self.next += 1;
        return true;
    }
};

test "USB reader power cycle changes only expander bit 3 and observes off/on waits" {
    var model: PowerModel = undefined;
    model = .{ .pins = &model };
    try usbPowerCycle(&model);
    try std.testing.expectEqualDeep([3]u8{ 0xad, 0x5d, 0xa2 }, model.values);
    try std.testing.expectEqualDeep([2]u32{ 250_000, 100_000 }, model.waits);
}
test "USB power-off verifies readback, preserves other pins and detects dropped writes" {
    var model: PowerModel = undefined;
    model = .{ .pins = &model, .values = .{ 0xad, 0x55, 0xaa } };
    try usbPowerOff(&model);
    try std.testing.expectEqualDeep([3]u8{ 0xa5, 0x5d, 0xa2 }, model.values);
    try std.testing.expectEqual(@as(u32, 250_000), model.waits[0]);
    model = .{ .pins = &model, .values = .{ 0xad, 0x55, 0xaa }, .drop = true };
    try std.testing.expectError(error.Readback, usbPowerOff(&model));
}

pub fn Master(comptime Pins: type) type {
    return struct {
        pins: Pins,
        transactions: u32 = 0,
        data_pin: u32 = sda,
        clock_pin: u32 = scl,
        const Self = @This();

        /// Only before the first transaction, with exclusive boot ownership.
        /// No peripheral reset and no driven-high pin; SCL-low is rejected.
        pub fn clearBootBus(self: *Self) Error!u32 {
            if (self.transactions != 0) return error.InvalidTransfer;
            defer {
                self.pins.release(self.data_pin, true);
                self.pins.release(self.clock_pin, true);
            }
            self.pins.release(self.data_pin, true);
            try self.highClock();
            if (self.pins.level(self.data_pin)) return 0;
            for (1..10) |pulse| {
                try self.lowClock();
                try self.highClock();
                if (self.pins.level(self.data_pin)) {
                    try self.lowClock();
                    try self.stop();
                    if (!self.pins.level(self.data_pin)) return error.BusBusy;
                    return @intCast(pulse);
                }
            }
            return error.BusBusy;
        }

        fn pause(self: *Self) Error!void {
            if (!self.pins.delay(5)) return error.Timer;
        }
        fn highClock(self: *Self) Error!void {
            self.pins.release(self.clock_pin, true);
            for (0..200) |_| {
                if (self.pins.level(self.clock_pin)) return self.pause();
                try self.pause();
            }
            return error.ClockTimeout;
        }
        fn lowClock(self: *Self) Error!void {
            self.pins.release(self.clock_pin, false);
            try self.pause();
        }
        fn start(self: *Self) Error!void {
            self.pins.release(self.data_pin, true);
            try self.highClock();
            if (!self.pins.level(self.data_pin)) return error.BusBusy;
            self.pins.release(self.data_pin, false);
            try self.pause();
            try self.lowClock();
        }
        fn stop(self: *Self) Error!void {
            self.pins.release(self.data_pin, false);
            try self.pause();
            try self.highClock();
            self.pins.release(self.data_pin, true);
            try self.pause();
        }
        fn writeBit(self: *Self, bit: bool) Error!void {
            self.pins.release(self.data_pin, bit);
            try self.pause();
            try self.highClock();
            if (bit and !self.pins.level(self.data_pin)) return error.ArbitrationLost;
            try self.lowClock();
        }
        fn readBit(self: *Self) Error!bool {
            self.pins.release(self.data_pin, true);
            try self.pause();
            try self.highClock();
            const bit = self.pins.level(self.data_pin);
            try self.lowClock();
            return bit;
        }
        fn writeByte(self: *Self, byte: u8) Error!void {
            for (0..8) |bit| try self.writeBit(byte & (@as(u8, 0x80) >> @intCast(bit)) != 0);
            if (try self.readBit()) {
                try self.stop();
                return error.Nack;
            }
        }
        fn readByte(self: *Self, last: bool) Error!u8 {
            var byte: u8 = 0;
            for (0..8) |_| byte = (byte << 1) | @intFromBool(try self.readBit());
            try self.writeBit(last); // NACK the last byte, ACK intermediate bytes.
            return byte;
        }

        /// At most 64 bytes each way. Reads use a repeated START, no STOP gap.
        pub fn transfer(self: *Self, address: u8, write: []const u8, read: []u8) Error!void {
            if (address >= 128 or write.len > 64 or read.len > 64 or (write.len == 0 and read.len == 0)) return error.InvalidTransfer;
            errdefer {
                // Do not issue STOP after arbitration loss: just release both.
                self.pins.release(self.clock_pin, true);
                self.pins.release(self.data_pin, true);
            }
            try self.start();
            if (write.len != 0) {
                self.writeByte(address << 1) catch |err| return if (err == error.Nack) error.AddressNack else err;
                for (write) |byte| try self.writeByte(byte);
                if (read.len != 0) try self.start();
            }
            if (read.len != 0) {
                self.writeByte((address << 1) | 1) catch |err| return if (err == error.Nack)
                    (if (write.len == 0) error.AddressNack else error.ReadAddressNack)
                else
                    err;
                for (read, 0..) |*byte, index| byte.* = try self.readByte(index + 1 == read.len);
            }
            try self.stop();
            self.transactions += 1;
        }
    };
}

const Model = struct {
    samples: [128]bool = @splat(true),
    count: usize = 0,
    next: usize = 0,
    released: [2]bool = .{ true, true },
    clock_stuck: bool = false,
    timer_ok: bool = true,
    transitions: u32 = 0,
    delays: u32 = 0,
    pub fn release(self: *@This(), pin: u32, high: bool) void {
        self.released[pin - sda] = high;
        self.transitions += 1;
    }
    pub fn level(self: *@This(), pin: u32) bool {
        if (pin == scl) return !self.clock_stuck;
        const bit = self.samples[self.next];
        self.next += 1;
        return bit;
    }
    pub fn delay(self: *@This(), _: u32) bool {
        self.delays += 1;
        return self.timer_ok;
    }
    fn sample(self: *@This(), bit: bool) void {
        self.samples[self.count] = bit;
        self.count += 1;
    }
    fn write(self: *@This(), byte: u8, ack: bool) void {
        for (0..8) |bit| if (byte & (@as(u8, 0x80) >> @intCast(bit)) != 0) self.sample(true);
        self.sample(!ack);
    }
};

test "explicit boot clear releases retained SDA with bounded clocks" {
    var model = Model{};
    for (0..3) |_| model.sample(false);
    model.sample(true);
    model.sample(true);
    var master = Master(*Model){ .pins = &model };
    try std.testing.expectEqual(@as(u32, 3), try master.clearBootBus());
    try std.testing.expectEqual(@as(u32, 0), master.transactions);
    try std.testing.expectEqualDeep([2]bool{ true, true }, model.released);
    var stuck = Model{};
    for (0..10) |_| stuck.sample(false);
    var blocked = Master(*Model){ .pins = &stuck };
    try std.testing.expectError(error.BusBusy, blocked.clearBootBus());
    try std.testing.expectEqual(@as(usize, 10), stuck.next);
    try std.testing.expectEqualDeep([2]bool{ true, true }, stuck.released);
    var held_clock = Model{ .clock_stuck = true };
    var clock = Master(*Model){ .pins = &held_clock };
    try std.testing.expectError(error.ClockTimeout, clock.clearBootBus());
    try std.testing.expectEqual(@as(usize, 0), held_clock.next);
    var owned = Master(*Model){ .pins = &model, .transactions = 1 };
    try std.testing.expectError(error.InvalidTransfer, owned.clearBootBus());
}

test "register read preserves repeated START, MSB order, final NACK" {
    var model = Model{};
    model.sample(true);
    model.write(0x86, true);
    model.write(0x03, true);
    model.sample(true);
    model.write(0x87, true);
    for (0..8) |bit| model.sample(@as(u8, 0xa5) & (@as(u8, 0x80) >> @intCast(bit)) != 0);
    model.sample(true); // master final NACK arbitration check
    var master = Master(*Model){ .pins = &model };
    var result: [1]u8 = .{0};
    try master.transfer(0x43, &.{0x03}, &result);
    try std.testing.expectEqual(@as(u8, 0xa5), result[0]);
    try std.testing.expectEqual(model.count, model.next);
    try std.testing.expectEqual(@as(u32, 1), master.transactions);
    try std.testing.expectEqualDeep([2]bool{ true, true }, model.released);
}

test "stuck clock, busy bus, NACK and arbitration loss release both lines" {
    var stuck = Model{ .clock_stuck = true };
    var a = Master(*Model){ .pins = &stuck };
    try std.testing.expectError(error.ClockTimeout, a.transfer(0x43, &.{3}, &.{}));
    try std.testing.expectEqual(@as(u32, 200), stuck.delays);
    var busy = Model{};
    busy.sample(false);
    var b = Master(*Model){ .pins = &busy };
    try std.testing.expectError(error.BusBusy, b.transfer(0x43, &.{3}, &.{}));
    var nack = Model{};
    nack.sample(true);
    nack.write(0x86, false);
    var c = Master(*Model){ .pins = &nack };
    try std.testing.expectError(error.AddressNack, c.transfer(0x43, &.{3}, &.{}));
    var lost = Model{};
    lost.sample(true);
    lost.sample(false);
    var d = Master(*Model){ .pins = &lost };
    try std.testing.expectError(error.ArbitrationLost, d.transfer(0x43, &.{3}, &.{}));
    for ([_]*Model{ &stuck, &busy, &nack, &lost }) |model| {
        try std.testing.expectEqualDeep([2]bool{ true, true }, model.released);
    }
    var invalid = Model{};
    var e = Master(*Model){ .pins = &invalid };
    try std.testing.expectError(error.InvalidTransfer, e.transfer(128, &.{3}, &.{}));
    try std.testing.expectEqual(@as(u32, 0), invalid.transitions);
}

test "data NACK differs from absent address and timer failure aborts" {
    var model = Model{};
    model.sample(true);
    model.write(0x86, true);
    model.write(0x03, false);
    var master = Master(*Model){ .pins = &model };
    try std.testing.expectError(error.Nack, master.transfer(0x43, &.{3}, &.{}));
    try std.testing.expectEqual(@as(u32, 0), master.transactions);
    try std.testing.expectEqualDeep([2]bool{ true, true }, model.released);
    var stopped = Model{ .timer_ok = false };
    var broken = Master(*Model){ .pins = &stopped };
    try std.testing.expectError(error.Timer, broken.transfer(0x43, &.{3}, &.{}));
    try std.testing.expectEqualDeep([2]bool{ true, true }, stopped.released);
    var read_nack = Model{};
    read_nack.sample(true);
    read_nack.write(0x86, true);
    read_nack.write(0x03, true);
    read_nack.sample(true);
    read_nack.write(0x87, false);
    var reader = Master(*Model){ .pins = &read_nack };
    var output: [1]u8 = .{0};
    try std.testing.expectError(error.ReadAddressNack, reader.transfer(0x43, &.{3}, &output));
}

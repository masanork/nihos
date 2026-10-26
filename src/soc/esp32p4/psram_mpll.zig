//! Exclusive pre-mapping MPLL400 setup, following pinned ESP-IDF v5.4.4.
//! No ROM-patch calls, SDK runtime, PLL changes for CPU/Flash, or unbounded waits.
const std = @import("std");
pub const power = 0x5011515c;
pub const lp_clock = 0x50111040;
pub const analog_clock = 0x50120000;
pub const analog = 0x50124000;
pub const calibration = 0x500e60bc;
pub const power_mask: u32 = 1 << 24;
pub const stop_mask: u32 = 1 << 9;
pub const done_mask: u32 = 1 << 8;
const busy: u32 = 1 << 25;
const divider400: u8 = (19 << 3) | 1; // XTAL40 *20 /2 =400 MHz.
pub const Error = error{ Busy, Timeout, Readback, AlreadyOwned, InvalidBudget };
pub const Result = struct { mhz: u32 = 400, reused: u32 = 0, divider: u32 = divider400 };

fn wait(io: anytype, address: usize, mask: u32, expected: u32, limit: u32) Error!void {
    for (0..limit) |_| if (io.read(address) & mask == expected) return;
    return error.Timeout;
}

fn transaction(io: anytype, register: u8, value: ?u8, limit: u32) Error!u8 {
    if (io.read(analog) & busy != 0) return error.Busy;
    const previous1 = io.read(analog + 0x1c);
    const previous2 = io.read(analog + 0x20);
    io.write(analog + 0x1c, 0);
    io.write(analog + 0x20, 1 << 9); // only MPLL block0x63, master0.
    defer {
        io.write(analog + 0x1c, previous1);
        io.write(analog + 0x20, previous2);
    }
    const command: u32 = 0x63 | (@as(u32, register) << 8) |
        (if (value) |byte| (1 << 24) | (@as(u32, byte) << 16) else @as(u32, 0));
    io.write(analog, command);
    try wait(io, analog, busy, 0, limit);
    return @truncate(io.read(analog) >> 16);
}

pub fn initialize(io: anytype, limit: u32) Error!Result {
    if (limit == 0 or limit > 1_000_000) return error.InvalidBudget;
    if (io.read(analog) & busy != 0) return error.Busy;
    // Preserve other low-power clocks and all CPU/SPLL settings.
    io.write(analog_clock, io.read(analog_clock) | (1 << 27));
    io.write(analog + 0x34, io.read(analog + 0x34) | 1);
    if (io.read(power) & power_mask != 0) {
        if (try transaction(io, 2, null, limit) != divider400 or io.read(calibration) & done_mask == 0)
            return error.AlreadyOwned;
        return .{ .reused = 1 };
    }
    io.write(power, io.read(power) | power_mask);
    io.write(lp_clock, io.read(lp_clock) | (1 << 28));
    io.write(calibration, io.read(calibration) & ~stop_mask);
    defer io.write(calibration, io.read(calibration) | stop_mask);
    const reference = try transaction(io, 3, null, limit);
    _ = try transaction(io, 3, reference | 0x30, limit);
    const reset = try transaction(io, 1, null, limit);
    _ = try transaction(io, 1, reset & ~@as(u8, 0x20), limit);
    _ = try transaction(io, 1, reset | 0x20, limit);
    _ = try transaction(io, 2, divider400, limit);
    try wait(io, calibration, done_mask, done_mask, limit);
    if (try transaction(io, 2, null, limit) != divider400) return error.Readback;
    return .{};
}

const Model = struct {
    pwr: u32 = 0x80,
    lp: u32 = 0x12,
    ac: u32 = 0x34,
    conf1: u32 = 0xa123,
    conf2: u32 = 0xb456,
    clock160: u32 = 0x10,
    ctrl: u32 = 0,
    cal: u32 = stop_mask,
    registers: [4]u8 = .{ 0, 0x83, 0, 0x05 },
    ready: bool = true,
    stuck: bool = false,
    pub fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            power => self.pwr,
            lp_clock => self.lp,
            analog_clock => self.ac,
            analog => self.ctrl | (if (self.stuck) busy else @as(u32, 0)),
            analog + 0x1c => self.conf1,
            analog + 0x20 => self.conf2,
            analog + 0x34 => self.clock160,
            calibration => self.cal,
            else => unreachable,
        };
    }
    pub fn write(self: *@This(), address: usize, value: u32) void {
        switch (address) {
            power => self.pwr = value,
            lp_clock => self.lp = value,
            analog_clock => self.ac = value,
            analog + 0x1c => self.conf1 = value,
            analog + 0x20 => self.conf2 = value,
            analog + 0x34 => self.clock160 = value,
            calibration => self.cal = value,
            analog => {
                std.debug.assert(value & 255 == 0x63);
                const index: usize = @as(u8, @truncate(value >> 8));
                if (value & (1 << 24) != 0) {
                    self.registers[index] = @truncate(value >> 16);
                    if (index == 2 and self.ready) self.cal |= done_mask;
                }
                self.ctrl = @as(u32, self.registers[index]) << 16;
            },
            else => unreachable,
        }
    }
};

test "MPLL400 preserves unrelated power clocks and restores analog selectors" {
    var model = Model{};
    const result = try initialize(&model, 100);
    try std.testing.expectEqual(@as(u32, 400), result.mhz);
    try std.testing.expectEqual(@as(u32, 0), result.reused);
    try std.testing.expectEqual(@as(u32, 0x80), model.pwr & ~power_mask);
    try std.testing.expectEqual(@as(u32, 0x12), model.lp & ~@as(u32, 1 << 28));
    try std.testing.expectEqual(@as(u32, 0xa123), model.conf1);
    try std.testing.expectEqual(@as(u32, 0xb456), model.conf2);
    try std.testing.expectEqual(@as(u8, 0x35), model.registers[3]);
    try std.testing.expect(model.cal & stop_mask != 0);
    try std.testing.expectEqual(@as(u32, 1), (try initialize(&model, 100)).reused);
}

test "unknown retained MPLL and busy analog transactions are never retuned" {
    var retained = Model{ .pwr = power_mask, .registers = .{ 0, 0x83, 0xc1, 0x05 } };
    try std.testing.expectError(error.AlreadyOwned, initialize(&retained, 100));
    try std.testing.expectEqual(@as(u8, 0xc1), retained.registers[2]);
    var busy_model = Model{ .stuck = true };
    try std.testing.expectError(error.Busy, initialize(&busy_model, 10));
    try std.testing.expectEqual(@as(u32, 0x80), busy_model.pwr);
}

test "calibration timeout is bounded and stops calibration without fabricating success" {
    var model = Model{ .ready = false };
    try std.testing.expectError(error.Timeout, initialize(&model, 5));
    try std.testing.expect(model.cal & stop_mask != 0);
    try std.testing.expectEqual(@as(u32, 0xa123), model.conf1);
    try std.testing.expectEqual(@as(u32, 0xb456), model.conf2);
    try std.testing.expectError(error.InvalidBudget, initialize(&model, 0));
}

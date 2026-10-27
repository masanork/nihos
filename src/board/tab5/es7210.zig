//! ES7210 register control from Everest rev2.0 datasheet, section 7.
//! CPU0 supplies the shared I2C owner; no bus reset or expander writes.
const std = @import("std");
pub const address = 0x40;
pub const Failure = extern struct { register: u32 = 0, expected: u32 = 0, actual: u32 = 0, stage: u32 = 0 };
pub var failure: Failure = .{};
var identified = false;
fn failed(register: u8, expected: u8, actual: u8, stage: u32) void {
    if (failure.stage == 0) failure = .{ .register = register, .expected = expected, .actual = actual, .stage = stage };
}
fn read(bus: anytype, register: u8) !u8 {
    var byte: [1]u8 = undefined;
    bus.transfer(address, &.{register}, &byte) catch |err| {
        failed(register, 0, 0, 1);
        return err;
    };
    return byte[0];
}
fn write(bus: anytype, register: u8, requested: u8, mask: u8) !void {
    const before = try read(bus, register);
    const value = (before & ~mask) | (requested & mask);
    bus.transfer(address, &.{ register, value }, &.{}) catch |err| {
        failed(register, value, 0, 2);
        return err;
    };
    const actual = try read(bus, register);
    if (actual & mask != value & mask) {
        failed(register, value, actual, 3);
        return error.Readback;
    }
}
pub fn prepare(bus: anytype) !void {
    failure = .{};
    identified = false;
    if (try read(bus, 0x3d) != 0x72 or try read(bus, 0x3e) != 0x10) return error.WrongDevice;
    identified = true;
    // Do not issue a global reset. Hold digital pairs in reset while changing
    // clocks, mute, interface and analog state. Reserved fields are preserved.
    try write(bus, 0x00, 0x71, 0x7f);
    try write(bus, 0x01, 0x7f, 0x7f);
    try write(bus, 0x14, 3, 3);
    try write(bus, 0x15, 3, 3);
    try write(bus, 0x08, 0x14, 0xff); // Slave, single speed, EQ off, 2-channel LRCK groups.
    try write(bus, 0x09, 0x30, 0xff);
    try write(bus, 0x0a, 0x30, 0xff);
    try write(bus, 0x02, 0xc1, 0xdf); // MCLK doubler, DLL bypass, divider 1.
    try write(bus, 0x06, 0, 7);
    try write(bus, 0x07, 0x20, 0x3f);
    try write(bus, 0x10, 0, 0xff); // Analog inputs; no DMIC source.
    try write(bus, 0x11, 0x60, 0xf3); // 16-bit Philips I2S.
    try write(bus, 0x12, 2, 0x7f); // Four-channel TDM I2S on SDOUT1.
    try write(bus, 0x13, 0, 0x0f); // No automatic muting.
    try write(bus, 0x16, 0, 0xff); // ALC disabled.
    for ([_]u8{ 0x1b, 0x1c, 0x1d, 0x1e }) |reg| try write(bus, reg, 0xbf, 0xff); // 0 dB digital gain.
    for ([_]u8{ 0x20, 0x22 }) |reg| try write(bus, reg, 0x0a, 0xff);
    for ([_]u8{ 0x21, 0x23 }) |reg| try write(bus, reg, 0x2a, 0xff);
    try write(bus, 0x40, 0x43, 0xef); // VDDA 3.3V, VMID 5k divider.
    for ([_]u8{ 0x41, 0x42 }) |reg| try write(bus, reg, 0x70, 0x77);
    for ([_]u8{ 0x43, 0x44, 0x45, 0x46 }) |reg| try write(bus, reg, 0x18, 0x1f); // Select analog input, 24 dB.
    for ([_]u8{ 0x47, 0x48, 0x49, 0x4a }) |reg| try write(bus, reg, 0x08, 0x1f);
    for ([_]u8{ 0x4b, 0x4c }) |reg| try write(bus, reg, 0, 0xff);
    try write(bus, 0x01, 0x20, 0x7f); // Slave clocks and ADCs on; master generator off.
    try write(bus, 0x00, 0x41, 0x7f); // Release both ADC digital pairs.
}
pub fn unmute(bus: anytype) !void {
    try write(bus, 0x14, 0, 3);
    try write(bus, 0x15, 0, 3);
}
pub fn shutdown(bus: anytype) !void {
    if (!identified) return error.WrongDevice;
    var bad = false;
    for ([_]u8{ 0x14, 0x15 }) |reg| write(bus, reg, 3, 3) catch {
        bad = true;
    };
    for ([_]u8{ 0x4b, 0x4c }) |reg| write(bus, reg, 0xff, 0xff) catch {
        bad = true;
    };
    write(bus, 0x40, 0xc0, 0xef) catch {
        bad = true;
    };
    // Stop internal MCLK before powering its DLL down (datasheet register 6).
    var clock_off = true;
    write(bus, 1, 0x7f, 0x7f) catch {
        clock_off = false;
        bad = true;
    };
    if (clock_off) write(bus, 6, 7, 7) catch {
        bad = true;
    };
    if (bad) return error.Shutdown;
}
const Model = struct {
    regs: [128]u8 = @splat(0),
    fail_register: ?u8 = null,
    pub fn transfer(self: *@This(), dev: u8, request: []const u8, result: []u8) !void {
        try std.testing.expectEqual(@as(u8, address), dev);
        if (result.len == 1) {
            result[0] = self.regs[request[0]];
            return;
        }
        if (self.fail_register == request[0]) return error.Nack;
        self.regs[request[0]] = request[1];
    }
};
fn model() Model {
    var m: Model = .{};
    m.regs[0x3d] = 0x72;
    m.regs[0x3e] = 0x10;
    return m;
}
test "ES7210 validates identity, preserves reserved bits and stays muted until requested" {
    var m = model();
    m.regs[0x43] = 0xe0;
    try prepare(&m);
    try std.testing.expectEqual(@as(u8, 0xf8), m.regs[0x43]);
    try std.testing.expect(m.regs[0x14] & 3 == 3 and m.regs[0x15] & 3 == 3);
    try unmute(&m);
    try std.testing.expect(m.regs[0x14] & 3 == 0 and m.regs[0x15] & 3 == 0);
    try shutdown(&m);
    try std.testing.expectEqual(@as(u8, 0xff), m.regs[0x4b]);
    try std.testing.expectEqual(@as(u8, 0xff), m.regs[0x4c]);
    m = model();
    m.regs[0x3d] = 0;
    try std.testing.expectError(error.WrongDevice, prepare(&m));
}
test "ES7210 shutdown tries independent power controls and avoids DLL powerdown without clock-off" {
    var m = model();
    try prepare(&m);
    m.fail_register = 0x14;
    try std.testing.expectError(error.Shutdown, shutdown(&m));
    try std.testing.expectEqual(@as(u8, 0xff), m.regs[0x4c]);
    m = model();
    try prepare(&m);
    m.fail_register = 1;
    try std.testing.expectError(error.Shutdown, shutdown(&m));
    try std.testing.expectEqual(@as(u8, 0), m.regs[6]);
}

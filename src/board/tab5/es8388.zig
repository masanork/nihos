//! Playback-only ES8388 control from Everest datasheet rev5 and Tab5 wiring.
//! The caller owns board I2C. No mic setup, global expander reset or bus clear.
const std = @import("std");
pub const address = 0x10;
pub const attenuation = 24; // 0.5 dB steps: -12 dB, in addition to PCM scaling.
pub const Failure = extern struct { device: u32 = 0, register: u32 = 0, expected: u32 = 0, actual: u32 = 0, stage: u32 = 0 };
pub var failure: Failure = .{};
fn recordFailure(device: u8, register: u8, expected: u32, actual: u32, stage: u32) void {
    if (failure.stage == 0) failure = .{ .device = device, .register = register, .expected = expected, .actual = actual, .stage = stage };
}

fn read(bus: anytype, device: u8, register: u8) !u8 {
    var value: [1]u8 = undefined;
    bus.transfer(device, &.{register}, &value) catch |err| {
        recordFailure(device, register, 0, 0, 1);
        return err;
    };
    return value[0];
}
fn write(bus: anytype, register: u8, requested: u8) !void {
    // Read-only/reserved bits need not echo the written byte (physical
    // CONTROL2 bit6 reads high). Preserve them and verify documented fields.
    const mask: u8 = switch (register) {
        1, 0x18, 0x26, 0x2e, 0x2f, 0x30, 0x31 => 0x3f,
        4, 0x2b => 0xfc,
        0x17 => 0xfe,
        0x19 => 0xec,
        0x27, 0x2a => 0xf8,
        else => 0xff,
    };
    const before = try read(bus, address, register);
    const value = (before & ~mask) | (requested & mask);
    bus.transfer(address, &.{ register, value }, &.{}) catch |err| {
        recordFailure(address, register, value, 0, 2);
        return err;
    };
    const actual = try read(bus, address, register);
    if (actual & mask != value & mask) {
        recordFailure(address, register, value, actual, 3);
        return error.Readback;
    }
}
fn ampBit(bus: anytype, register: u8, enabled: bool) !void {
    const before = try read(bus, 0x43, register);
    const value = (before & ~@as(u8, 2)) | (if (enabled) @as(u8, 2) else 0);
    bus.transfer(0x43, &.{ register, value }, &.{}) catch |err| {
        recordFailure(0x43, register, value, 0, 2);
        return err;
    };
    const actual = try read(bus, 0x43, register);
    if (actual != value) {
        recordFailure(0x43, register, value, actual, 3);
        return error.Readback;
    }
}
/// P1 on the first expander drives the NS4150 amplifier enable. Latch first.
pub fn amplifier(bus: anytype, enabled: bool) !void {
    try ampBit(bus, 5, enabled);
    try ampBit(bus, 7, false); // No high-impedance override on this output.
    try ampBit(bus, 3, true); // Direction: 1=output; preserve LCD/touch pins.
}
/// Leave DAC muted and amplifier off. Caller supplies MCLK and waits at least
/// 150 ms for analog settling before starting PCM and explicitly unmuting.
pub fn prepare(bus: anytype) !void {
    failure = .{};
    try amplifier(bus, false);
    // Do not reset the shared codec/control port: explicitly configure the
    // DAC path while powering down ADC inputs, and leave microphone ADC alone.
    try write(bus, 0x19, 0x26); // Soft ramp, muted.
    try write(bus, 4, 0xc0); // Both DACs down, outputs disabled.
    try write(bus, 0, 0x36); // Common Fs, DAC MCLK, reference + 500k VMID.
    try write(bus, 1, 0x00); // Analog bias/reference on, normal power.
    try write(bus, 2, 0x88); // ADC digital/DLL down; DAC reference/DLL on.
    try write(bus, 3, 0xff); // ES8388 ADC/input/mic bias down.
    try write(bus, 8, 0x00); // Slave, normal MCLK and BCLK polarity.
    try write(bus, 0x17, 0x18); // 16-bit Philips I2S.
    try write(bus, 0x18, 2); // 256 Fs, single-speed.
    try write(bus, 0x1a, attenuation);
    try write(bus, 0x1b, attenuation);
    try write(bus, 0x26, 0x00); // No analog bypass.
    try write(bus, 0x27, 0xb8); // Left DAC -> left mixer only.
    try write(bus, 0x2a, 0xb8); // Right DAC -> right mixer only.
    try write(bus, 0x2b, 0x80); // Shared LRCK, DAC/ADC DLL controls normal.
    for ([_]u8{ 0x2e, 0x2f, 0x30, 0x31 }) |register| try write(bus, register, 0x1e); // 0 dB analog outputs.
    try write(bus, 4, 0x3c); // DACs and output pairs up, still muted.
}
/// Must only follow a successfully started DMA/I2S stream.
pub fn unmute(bus: anytype) !void {
    for ([_]u8{ 0x1a, 0x1b }) |register| {
        const value = try read(bus, address, register);
        if (value != attenuation) {
            recordFailure(address, register, attenuation, value, 3);
            return error.Readback;
        }
    }
    try write(bus, 0x19, 0x22);
    try amplifier(bus, true);
}
/// Attempt all independent shutdown operations, even if one I2C write fails.
/// A failure is reported; amp-off must never be inferred from a request alone.
pub fn shutdown(bus: anytype) !void {
    var failed = false;
    amplifier(bus, false) catch {
        failed = true;
    };
    write(bus, 0x19, 0x26) catch {
        failed = true;
    };
    write(bus, 4, 0xc0) catch {
        failed = true;
    };
    if (failed) return error.Shutdown;
}

const Model = struct {
    codec: [64]u8 = @splat(0),
    expander: [16]u8 = @splat(0xa5),
    writes: u32 = 0,
    fail_register: ?u8 = null,
    dropped: bool = false,
    pub fn transfer(self: *@This(), device: u8, request: []const u8, output: []u8) !void {
        if (device != address and device != 0x43) return error.WrongDevice;
        const registers: []u8 = if (device == address) &self.codec else &self.expander;
        if (output.len == 1) {
            output[0] = registers[request[0]];
            return;
        }
        if (device == address and self.fail_register == request[0]) return error.Nack;
        self.writes += 1;
        if (!self.dropped) registers[request[0]] = request[1];
    }
};
test "ES8388 starts muted, checks both gains and preserves unrelated expander bits" {
    var model: Model = .{};
    try prepare(&model);
    try std.testing.expect(model.expander[5] & 2 == 0 and model.codec[0x19] & 4 != 0);
    const original = model.expander;
    model.codec[0x1b] = 0;
    try std.testing.expectError(error.Readback, unmute(&model));
    try std.testing.expectEqual(@as(u8, 0), model.expander[5] & 2);
    model.codec[0x1b] = attenuation;
    try unmute(&model);
    try std.testing.expect(model.expander[5] & 2 != 0);
    for (model.expander, original, 0..) |after, before, index| {
        if (index == 5) try std.testing.expectEqual(before | 2, after) else try std.testing.expectEqual(before, after);
    }
    try shutdown(&model);
    try std.testing.expectEqual(@as(u8, 0xc0), model.codec[4]);
    try std.testing.expect(model.expander[5] & 2 == 0 and model.codec[0x19] & 4 != 0);
}
test "ES8388 detects dropped writes and still powers DAC down when muting fails" {
    var model = Model{ .dropped = true };
    try std.testing.expectError(error.Readback, prepare(&model));
    model = .{};
    try prepare(&model);
    try unmute(&model);
    model.fail_register = 0x19;
    try std.testing.expectError(error.Shutdown, shutdown(&model));
    try std.testing.expectEqual(@as(u8, 0), model.expander[5] & 2);
    try std.testing.expectEqual(@as(u8, 0xc0), model.codec[4]);
}
test "ES8388 preserves CONTROL2 reserved bit6 while configuring writable analog fields" {
    var model: Model = .{};
    model.codec[1] = 0x5c;
    try prepare(&model);
    try std.testing.expectEqual(@as(u8, 0x40), model.codec[1]);
}

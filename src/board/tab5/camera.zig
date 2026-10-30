//! Tab5 camera power and SC202CS-compatible identity probe, not capture.
//! Caller exclusively owns shared board I2C and provides the 100 ms power delay.
//! Register facts: Espressif Tab5 NoGLIB BSP 1.3.2 and esp_cam_sensor SC202CS.
const std = @import("std");
const mode = @import("sc202cs_mode.zig");
pub const expander: u8 = 0x43;
pub const sensor: u8 = 0x36;
pub const expected_id: u16 = 0xeb52;
pub const Error = error{ ExpanderIdentity, Readback, SensorIdentity };
const camera_mask: u8 = 0x40;

fn readExpander(bus: anytype, reg: u8) !u8 {
    var value: [1]u8 = undefined;
    try bus.transfer(expander, &.{reg}, &value);
    return value[0];
}
fn update(bus: anytype, reg: u8, bits: u8) !void {
    const old = try readExpander(bus, reg);
    const next = (old & ~camera_mask) | bits;
    try bus.transfer(expander, &.{ reg, next }, &.{});
    if (try readExpander(bus, reg) != next) return error.Readback;
}
/// On any error, camera power state is unknown; caller must not assume cleanup.
/// Latch before enabling output to avoid a transient high when disabling.
pub fn setPower(bus: anytype, enabled: bool) !void {
    if (try readExpander(bus, 0x01) & 0xfc != 0xa0) return error.ExpanderIdentity;
    try update(bus, 0x05, if (enabled) camera_mask else 0);
    try update(bus, 0x07, 0); // push-pull
    try update(bus, 0x03, camera_mask); // output
}
/// Call only after power has been stable for at least 100 ms. Identity is not
/// evidence that the sensor mode, CSI, ISP, DMA or capture works.
pub fn identify(bus: anytype) !u16 {
    var hi: [1]u8 = undefined;
    var lo: [1]u8 = undefined;
    try bus.transfer(sensor, &.{ 0x31, 0x07 }, &hi);
    try bus.transfer(sensor, &.{ 0x31, 0x08 }, &lo);
    const id = (@as(u16, hi[0]) << 8) | lo[0];
    if (id != expected_id) return error.SensorIdentity;
    return id;
}

/// Control the sensor's stream bit, then read it back. An I2C error after the
/// write leaves the stream state unknown even if the write may have landed.
/// The caller must hold powered, identified and configured sensor ownership.
pub fn setStream(bus: anytype, enabled: bool) !void {
    const value: u8 = if (enabled) 1 else 0;
    try bus.transfer(sensor, &.{ 0x01, 0x00, value }, &.{});
    var actual: [1]u8 = undefined;
    try bus.transfer(sensor, &.{ 0x01, 0x00 }, &actual);
    if (actual[0] != value) return error.Readback;
}

/// Finite identity-only probe, serialized by the shared I2C owner. The caller
/// must have established that the camera is not in use before start. No frame
/// is started and no other peripheral's power is intentionally changed.
pub const Probe = struct {
    pub const State = enum { idle, power_on, settling, identify, power_off, done, pinned, configure, held, stream_on, stream_off, reset_wait };
    pub const Result = enum { none, identified, transport, identity, clock, cancelled, configured, mode_readback, stream_tested };
    state: State = .idle,
    result: Result = .none,
    ready_at: u64 = 0,
    configure_mode: bool = false,
    hold_mode: bool = false,
    stream_probe: bool = false,
    mode_driver: mode.Driver = .{},

    pub fn start(self: *Probe) bool {
        if (self.state != .idle) return false;
        self.state = .power_on;
        return true;
    }
    pub fn startMode(self: *Probe) bool {
        if (!self.start()) return false;
        self.configure_mode = true;
        return true;
    }
    /// A future capture owner must retire the sensor and receiver before
    /// releasing this held configuration; ordinary diagnostics still power off.
    pub fn startHeldMode(self: *Probe) bool {
        if (!self.startMode()) return false;
        self.hold_mode = true;
        return true;
    }
    /// Diagnostic only: start then stop the sensor without CSI or DMA.
    pub fn startStreamProbe(self: *Probe) bool {
        if (!self.startMode()) return false;
        self.stream_probe = true;
        return true;
    }
    pub fn releaseHeld(self: *Probe) bool {
        if (self.state != .held) return false;
        self.state = .power_off;
        return true;
    }
    pub fn cancel(self: *Probe) void {
        switch (self.state) {
            .power_on, .settling, .identify, .configure, .reset_wait => {
                self.result = .cancelled;
                self.state = .power_off;
            },
            .stream_on => {
                self.result = .cancelled;
                self.state = .stream_off;
            },
            else => {},
        }
    }
    /// Clock is monotonic microseconds; no busy wait. A failed clock or power
    /// operation still attempts cleanup on the next call. Failed cleanup pins.
    pub fn poll(self: *Probe, bus: anytype, clock: anytype) void {
        switch (self.state) {
            .power_on => {
                setPower(bus, true) catch {
                    self.result = .transport;
                    self.state = .power_off;
                    return;
                };
                const now = clock.counter() orelse {
                    self.result = .clock;
                    self.state = .power_off;
                    return;
                };
                self.ready_at = std.math.add(u64, now, 100_000) catch {
                    self.result = .clock;
                    self.state = .power_off;
                    return;
                };
                self.state = .settling;
            },
            .settling => {
                const now = clock.counter() orelse {
                    self.result = .clock;
                    self.state = .power_off;
                    return;
                };
                if (now >= self.ready_at) self.state = .identify;
            },
            .identify => {
                _ = identify(bus) catch |err| {
                    self.result = if (err == error.SensorIdentity) .identity else .transport;
                    self.state = .power_off;
                    return;
                };
                if (self.configure_mode) {
                    if (!self.mode_driver.start()) {
                        self.result = .transport;
                        self.state = .power_off;
                        return;
                    }
                    self.state = .configure;
                } else {
                    self.result = .identified;
                    self.state = .power_off;
                }
            },
            .stream_on => {
                setStream(bus, true) catch {
                    self.result = .transport;
                    self.state = .stream_off;
                    return;
                };
                self.result = .stream_tested;
                self.state = .stream_off;
            },
            .stream_off => {
                setStream(bus, false) catch {
                    self.result = .transport;
                };
                // Power-off is still attempted even when I2C stream-off failed.
                self.state = .power_off;
            },
            .configure => {
                self.mode_driver.poll(bus);
                if (self.mode_driver.state == .writing and self.mode_driver.index == 1) {
                    // The Tab5 SC202CS reset requires a 10 ms settling period.
                    const now = clock.counter() orelse {
                        self.result = .clock;
                        self.state = .power_off;
                        return;
                    };
                    self.ready_at = std.math.add(u64, now, 10_000) catch {
                        self.result = .clock;
                        self.state = .power_off;
                        return;
                    };
                    self.state = .reset_wait;
                    return;
                }
                switch (self.mode_driver.state) {
                    .ready => {
                        self.result = .configured;
                        self.state = if (self.stream_probe) .stream_on else if (self.hold_mode) .held else .power_off;
                    },
                    .failed => {
                        self.result = if (self.mode_driver.fault == .readback) .mode_readback else .transport;
                        self.state = .power_off;
                    },
                    else => {},
                }
            },
            .reset_wait => {
                const now = clock.counter() orelse {
                    self.result = .clock;
                    self.state = .power_off;
                    return;
                };
                if (now >= self.ready_at) self.state = .configure;
            },
            .power_off => {
                setPower(bus, false) catch {
                    self.state = .pinned;
                    return;
                };
                self.state = .done;
            },
            else => {},
        }
    }
};
const Fake = struct {
    regs: [16]u8 = @splat(0x95),
    sensor_id: u16 = expected_id,
    sensor_regs: [65536]u8 = @splat(0),
    drop: bool = false,
    writes: u32 = 0,
    sensor_writes: u32 = 0,
    fail_stream_on: bool = false,
    fail_stream_off: bool = false,
    pub fn transfer(self: *Fake, address: u8, w: []const u8, out: []u8) error{Nack}!void {
        if (address == expander) {
            if (w.len == 2) {
                self.writes += 1;
                if (!self.drop) self.regs[w[0]] = w[1];
            }
            if (out.len == 1) out[0] = self.regs[w[0]];
        } else if (address == sensor and w.len >= 2) {
            const reg = (@as(u16, w[0]) << 8) | w[1];
            if (w.len == 3 and out.len == 0) {
                if (reg == 0x0100 and ((w[2] == 1 and self.fail_stream_on) or (w[2] == 0 and self.fail_stream_off))) return error.Nack;
                self.sensor_writes += 1;
                self.sensor_regs[reg] = w[2];
            } else if (w.len == 2 and out.len == 1) {
                out[0] = switch (reg) {
                    0x3107 => @intCast(self.sensor_id >> 8),
                    0x3108 => @truncate(self.sensor_id),
                    else => self.sensor_regs[reg],
                };
            } else return error.Nack;
        } else return error.Nack;
    }
};
test "power controls only camera bit and confirms both transitions" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    const before = f.regs;
    try setPower(&f, true);
    for (f.regs, before, 0..) |actual, prior, i| {
        const mask: u8 = if (i == 3 or i == 5 or i == 7) camera_mask else 0;
        try std.testing.expectEqual(prior & ~mask, actual & ~mask);
    }
    try std.testing.expectEqual(@as(u8, camera_mask), f.regs[5] & camera_mask);
    try std.testing.expectEqual(@as(u8, 0), f.regs[7] & camera_mask);
    try std.testing.expectEqual(@as(u8, camera_mask), f.regs[3] & camera_mask);
    try setPower(&f, false);
    try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);
}
test "bad expander or unconfirmed write fail closed; identify checks both bytes" {
    var f: Fake = .{};
    try std.testing.expectError(error.ExpanderIdentity, setPower(&f, true));
    try std.testing.expectEqual(@as(u32, 0), f.writes);
    f.regs[1] = 0xa1;
    f.drop = true;
    try std.testing.expectError(error.Readback, setPower(&f, true));
    try std.testing.expectEqual(expected_id, try identify(&f));
    f.sensor_id ^= 1;
    try std.testing.expectError(error.SensorIdentity, identify(&f));
}

const TestClock = struct {
    now: ?u64 = 0,
    pub fn counter(self: *TestClock) ?u64 {
        return self.now;
    }
};
test "probe waits from completed power-on and confirms off before success" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    var clock: TestClock = .{ .now = 10 };
    var p: Probe = .{};
    try std.testing.expect(p.start());
    try std.testing.expect(!p.start());
    p.poll(&f, &clock);
    clock.now = 100_009;
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.settling, p.state);
    clock.now = 100_010;
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.Result.identified, p.result);
    try std.testing.expectEqual(Probe.State.power_off, p.state);
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.done, p.state);
    try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);
}
test "cancel and failed power-off never claim successful cleanup" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    var clock: TestClock = .{};
    var p: Probe = .{};
    _ = p.start();
    p.poll(&f, &clock);
    p.cancel();
    f.drop = true;
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.Result.cancelled, p.result);
    try std.testing.expectEqual(Probe.State.pinned, p.state);
    try std.testing.expect(!p.start());
}

test "bad sensor ID and failed clock both run cleanup" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    f.sensor_id = 0;
    var clock: TestClock = .{};
    var p: Probe = .{};
    _ = p.start();
    p.poll(&f, &clock);
    clock.now = 100_000;
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.Result.identity, p.result);
    try std.testing.expectEqual(Probe.State.done, p.state);
    try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);

    p = .{};
    clock.now = null;
    _ = p.start();
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.Result.clock, p.result);
    try std.testing.expectEqual(Probe.State.power_off, p.state);
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.done, p.state);
}

test "mode request identifies, configures without streaming and powers off" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    var clock: TestClock = .{};
    var p: Probe = .{};
    try std.testing.expect(p.startMode());
    p.poll(&f, &clock);
    clock.now = 100_000;
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    for (0..200) |_| {
        if (p.state == .done or p.state == .pinned) break;
        clock.now = clock.now.? + 1_000;
        p.poll(&f, &clock);
    }
    try std.testing.expectEqual(Probe.State.done, p.state);
    try std.testing.expectEqual(Probe.Result.configured, p.result);
    try std.testing.expectEqual(@as(u8, 0), f.sensor_regs[0x0100]);
    try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);
}

test "held mode remains powered until capture owner explicitly releases it" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    var clock: TestClock = .{};
    var p: Probe = .{};
    try std.testing.expect(p.startHeldMode());
    p.poll(&f, &clock);
    clock.now = 100_000;
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    for (0..200) |_| {
        if (p.state == .held or p.state == .pinned) break;
        clock.now = clock.now.? + 1_000;
        p.poll(&f, &clock);
    }
    try std.testing.expectEqual(Probe.State.held, p.state);
    try std.testing.expectEqual(@as(u8, camera_mask), f.regs[5] & camera_mask);
    try setStream(&f, true);
    try std.testing.expectEqual(@as(u8, 1), f.sensor_regs[0x0100]);
    try setStream(&f, false);
    try std.testing.expect(p.releaseHeld());
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.done, p.state);
    try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);
}

test "sensor reset waits ten milliseconds before the next I2C write" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    var clock: TestClock = .{};
    var p: Probe = .{};
    try std.testing.expect(p.startMode());
    p.poll(&f, &clock);
    clock.now = 100_000;
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.reset_wait, p.state);
    try std.testing.expectEqual(@as(u32, 1), f.sensor_writes);
    clock.now = 109_999;
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.reset_wait, p.state);
    try std.testing.expectEqual(@as(u32, 1), f.sensor_writes);
    clock.now = 110_000;
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.configure, p.state);
    p.poll(&f, &clock);
    try std.testing.expectEqual(@as(u32, 2), f.sensor_writes);
}

test "stream diagnostic confirms on then off before removing power" {
    var f: Fake = .{};
    f.regs[1] = 0xa1;
    var clock: TestClock = .{};
    var p: Probe = .{};
    try std.testing.expect(p.startStreamProbe());
    p.poll(&f, &clock);
    clock.now = 100_000;
    p.poll(&f, &clock);
    p.poll(&f, &clock);
    for (0..200) |_| {
        if (p.state == .stream_on) break;
        clock.now = clock.now.? + 1_000;
        p.poll(&f, &clock);
    }
    try std.testing.expectEqual(Probe.State.stream_on, p.state);
    p.poll(&f, &clock);
    try std.testing.expectEqual(@as(u8, 1), f.sensor_regs[0x0100]);
    p.poll(&f, &clock);
    try std.testing.expectEqual(@as(u8, 0), f.sensor_regs[0x0100]);
    try std.testing.expectEqual(@as(u8, camera_mask), f.regs[5] & camera_mask);
    p.poll(&f, &clock);
    try std.testing.expectEqual(Probe.State.done, p.state);
    try std.testing.expectEqual(Probe.Result.stream_tested, p.result);
    try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);
}

test "stream write failure attempts stop and powers off without reporting success" {
    var clock: TestClock = .{};
    for ([_]bool{ false, true }) |fail_on| {
        var f: Fake = .{};
        f.regs[1] = 0xa1;
        f.regs[5] |= camera_mask;
        var p: Probe = .{ .state = .stream_on };
        f.fail_stream_on = fail_on;
        p.poll(&f, &clock);
        try std.testing.expectEqual(Probe.State.stream_off, p.state);
        if (!fail_on) f.fail_stream_off = true;
        p.poll(&f, &clock);
        try std.testing.expectEqual(Probe.State.power_off, p.state);
        try std.testing.expectEqual(Probe.Result.transport, p.result);
        p.poll(&f, &clock);
        try std.testing.expectEqual(Probe.State.done, p.state);
        try std.testing.expectEqual(Probe.Result.transport, p.result);
        try std.testing.expectEqual(@as(u8, 0), f.regs[5] & camera_mask);
    }
}

const std = @import("std");
const imu = @import("bmi270.zig");
const Clock = struct {
    now: u64,
    pub fn counter(self: @This()) ?u64 {
        return self.now;
    }
};
const Model = struct {
    calls: usize = 0,
    uploaded: usize = 0,
    pointer: usize = 0,
    commits: u32 = 0,
    resets: u32 = 0,
    init: u8 = 1,
    chip: u8 = 0x24,
    status: u8 = 0xc0,
    sensor_error: u8 = 0,
    mismatch: bool = false,
    nack: bool = false,
    configuration: [8192]u8 = @splat(0),
    pub fn transfer(self: *@This(), address: u8, write: []const u8, read: []u8) !void {
        self.calls += 1;
        if (self.nack) return error.Nack;
        try std.testing.expectEqual(@as(u8, imu.address), address);
        try std.testing.expect(write.len <= 33 and read.len <= 12);
        if (read.len != 0) {
            switch (write[0]) {
                0 => read[0] = self.chip,
                0x21 => read[0] = self.init,
                0x40 => @memcpy(read, &[_]u8{ 0xa8, 1, 0xa8, if (self.mismatch) 3 else 2 }),
                0x7c => @memcpy(read, &[_]u8{ 2, 0x0e }),
                2 => @memcpy(read, &[_]u8{ self.sensor_error, self.status }),
                0x0c => @memcpy(read, &[_]u8{ 0, 0xe0, 0, 0, 0, 0x20, 0xff, 0xff, 0, 0x80, 0xff, 0x7f }),
                else => return error.UnexpectedRead,
            }
        } else switch (write[0]) {
            0x7e => {
                try std.testing.expectEqual(@as(u8, 0xb6), write[1]);
                self.resets += 1;
            },
            0x5b => {
                self.pointer = ((@as(usize, write[2]) << 4) | write[1]) * 2;
                try std.testing.expectEqual(self.uploaded, self.pointer);
            },
            0x5e => {
                try std.testing.expectEqual(@as(usize, 33), write.len);
                @memcpy(self.configuration[self.pointer..][0..32], write[1..]);
                self.uploaded += 32;
            },
            0x59 => if (write[1] == 1) {
                try std.testing.expectEqual(@as(usize, 8192), self.uploaded);
                self.commits += 1;
            },
            0x7c, 0x40, 0x7d => {},
            else => return error.UnexpectedWrite,
        }
    }
};
fn advance(driver: *imu.Driver, bus: *Model, until: imu.State) !u64 {
    for (0..1000) |index| {
        const now: u64 = index * 1000;
        const before = bus.calls;
        driver.poll(bus, Clock{ .now = now });
        try std.testing.expect(bus.calls - before <= 1);
        if (driver.state == until or driver.state == .failed) return now;
    }
    return error.DidNotProgress;
}
test "BMI270 uploads the exact licensed blob using word addresses and one transfer per poll" {
    var driver: imu.Driver = .{};
    var bus: Model = .{};
    const now = try advance(&driver, &bus, .status);
    try std.testing.expect(driver.initialized and !driver.valid);
    try std.testing.expectEqual(@as(u32, 1), bus.resets);
    try std.testing.expectEqual(@as(u32, 1), bus.commits);
    try std.testing.expectEqualSlices(u8, @embedFile("bmi270/config.bin"), &bus.configuration);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bus.configuration, &digest, .{});
    try std.testing.expectEqualStrings(imu.config_sha256, &std.fmt.bytesToHex(digest, .lower));
    driver.poll(&bus, Clock{ .now = now + 1000 });
    driver.poll(&bus, Clock{ .now = now + 2000 });
    try std.testing.expect(driver.valid);
    try std.testing.expectEqual(@as(u32, 1), driver.samples);
    try std.testing.expectEqualDeep([3]i16{ -8192, 0, 8192 }, driver.sample.acceleration);
    try std.testing.expectEqualDeep([3]i16{ -1, -32768, 32767 }, driver.sample.gyroscope);
}
test "BMI270 deadlines prevent early transfers and incomplete init never enables sensors" {
    var driver = imu.Driver{ .state = .reset };
    var bus: Model = .{};
    driver.poll(&bus, Clock{ .now = 0 });
    driver.poll(&bus, Clock{ .now = 1999 });
    try std.testing.expectEqual(@as(usize, 1), bus.calls);
    driver.poll(&bus, Clock{ .now = 2000 });
    driver.poll(&bus, Clock{ .now = 2449 });
    try std.testing.expectEqual(@as(usize, 2), bus.calls);
    driver = .{ .state = .initialization, .deadline = 150_000 };
    bus.init = 0;
    driver.poll(&bus, Clock{ .now = 149_000 });
    try std.testing.expectEqual(imu.State.initialization, driver.state);
    driver.poll(&bus, Clock{ .now = 150_000 });
    try std.testing.expectEqual(imu.Fault.initialization, driver.fault);
    try std.testing.expect(!driver.initialized and !driver.valid);
}
test "BMI270 rejects identity, init errors and dropped config writes" {
    var driver: imu.Driver = .{};
    var bus = Model{ .chip = 0 };
    driver.poll(&bus, Clock{ .now = 0 });
    try std.testing.expectEqual(imu.Fault.identity, driver.fault);
    try std.testing.expectEqual(@as(u32, 0), bus.resets);
    driver = .{ .state = .initialization };
    bus.init = 2;
    driver.poll(&bus, Clock{ .now = 0 });
    try std.testing.expectEqual(imu.Fault.initialization, driver.fault);
    driver = .{ .state = .check_config };
    bus.mismatch = true;
    driver.poll(&bus, Clock{ .now = 0 });
    try std.testing.expectEqual(imu.Fault.configuration, driver.fault);
}
test "BMI270 requires both fresh data flags and retires readings on timeout or I2C failure" {
    var driver = imu.Driver{ .state = .status, .initialized = true, .deadline = 100_000 };
    var bus = Model{ .status = 0x80 };
    driver.poll(&bus, Clock{ .now = 0 });
    try std.testing.expectEqual(imu.State.status, driver.state);
    try std.testing.expect(!driver.valid);
    driver.poll(&bus, Clock{ .now = 100_000 });
    try std.testing.expectEqual(imu.Fault.timeout, driver.fault);
    driver = .{ .state = .data, .initialized = true, .valid = true, .sample = .{ .acceleration = @splat(1) } };
    bus.nack = true;
    driver.poll(&bus, Clock{ .now = 0 });
    try std.testing.expectEqual(imu.Fault.transport, driver.fault);
    try std.testing.expect(!driver.initialized and !driver.valid);
    try std.testing.expectEqualDeep([3]i16{ 0, 0, 0 }, driver.sample.acceleration);
    const before = bus.calls;
    driver.poll(&bus, Clock{ .now = 1_000_000 });
    try std.testing.expectEqual(before, bus.calls);
    driver = .{ .state = .status, .initialized = true };
    bus.nack = false;
    bus.sensor_error = 1;
    driver.poll(&bus, Clock{ .now = 0 });
    try std.testing.expectEqual(imu.Fault.sensor, driver.fault);
}

test "BMI270 measures mandatory waits after a slow transfer completes" {
    const CompletingClock = struct {
        bus: *Model,
        pub fn counter(self: @This()) ?u64 {
            return if (self.bus.calls == 0) 0 else 5000;
        }
    };
    var driver = imu.Driver{ .state = .reset };
    var bus: Model = .{};
    const clock = CompletingClock{ .bus = &bus };
    driver.poll(&bus, clock);
    try std.testing.expectEqual(@as(u64, 7000), driver.next);
    driver.poll(&bus, clock);
    try std.testing.expectEqual(@as(usize, 1), bus.calls);
}

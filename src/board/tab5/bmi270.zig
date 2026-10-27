//! BMI270 base-profile acquisition from Bosch BST-BMI270-DS000-08.
//! Exclusive bus owner calls poll with monotonic microseconds. Each poll does
//! at most one I2C transfer; waits never spin. Axes are sensor-frame raw counts.
const std = @import("std");
pub const address = 0x68;
pub const chunk_bytes = 32;
pub const config_sha256 = "2d75e68e343a13ff99be98261dfbd99d9e8c6f267da9e3c5aeb883276ad178db";
const configuration linksection(if (@import("builtin").os.tag == .freestanding) ".flash.rodata.bmi270" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata") = @embedFile("bmi270/config.bin").*;
pub const config_bytes = configuration.len;
pub const State = enum(u8) {
    identify,
    reset,
    disable_power_save,
    prepare,
    upload_address,
    upload_data,
    commit,
    initialization,
    configure,
    check_config,
    power,
    check_power,
    status,
    data,
    failed,
};
pub const Fault = enum(u8) { none, transport, identity, initialization, configuration, sensor, timeout, clock };
pub const Sample = struct {
    acceleration: [3]i16 = @splat(0), // +/-4 g: 8192 counts/g.
    gyroscope: [3]i16 = @splat(0), // +/-500 dps: 65.536 counts/(degree/s).
};
pub const Driver = struct {
    state: State = .identify,
    fault: Fault = .none,
    chip: u8 = 0,
    internal_status: u8 = 0,
    error_register: u8 = 0,
    ready_status: u8 = 0,
    uploaded: u16 = 0,
    initialized: bool = false,
    valid: bool = false,
    samples: u32 = 0,
    sample: Sample = .{},
    next: u64 = 0,
    deadline: u64 = 0,
    wait_us: u32 = 1000,
    timeout_us: u32 = 0,

    pub fn poll(self: *Driver, bus: anytype, clock: anytype) void {
        const now = clock.counter() orelse {
            self.fail(.clock);
            return;
        };
        if (self.state == .failed or now < self.next) return;
        self.wait_us = 1000;
        self.timeout_us = 0;
        self.step(bus, now) catch {
            self.fail(if (self.fault == .none) .transport else self.fault);
            return;
        };
        // The I2C transfer can take longer than the interval. Start waits at
        // completion, never at the earlier poll entry timestamp.
        const completed = clock.counter() orelse {
            self.fail(.clock);
            return;
        };
        self.next = completed +| self.wait_us;
        if (self.timeout_us != 0) self.deadline = completed +| self.timeout_us;
    }

    fn fail(self: *Driver, fault: Fault) void {
        self.fault = fault;
        self.initialized = false;
        self.valid = false;
        self.sample = .{};
        self.state = .failed;
    }

    fn reject(self: *Driver, fault: Fault) error{Rejected} {
        self.fault = fault;
        return error.Rejected;
    }

    fn step(self: *Driver, bus: anytype, now: u64) !void {
        switch (self.state) {
            .identify => {
                var value: [1]u8 = undefined;
                try bus.transfer(address, &.{0}, &value);
                self.chip = value[0];
                if (self.chip != 0x24) return self.reject(.identity);
                self.state = .reset;
            },
            .reset => {
                // INIT_CTRL=1 is allowed only once per sensor reset. Reset also
                // removes any configuration retained across a warm P4 reset.
                try bus.transfer(address, &.{ 0x7e, 0xb6 }, &.{});
                self.wait_us = 2000;
                self.state = .disable_power_save;
            },
            .disable_power_save => {
                try bus.transfer(address, &.{ 0x7c, 0x02 }, &.{});
                self.state = .prepare; // >=450 us before INIT_CTRL.
            },
            .prepare => {
                try bus.transfer(address, &.{ 0x59, 0 }, &.{});
                self.state = .upload_address;
            },
            .upload_address => {
                const word = self.uploaded / 2;
                try bus.transfer(address, &.{ 0x5b, @intCast(word & 15), @intCast(word >> 4) }, &.{});
                self.state = .upload_data;
            },
            .upload_data => {
                var bytes: [chunk_bytes + 1]u8 = undefined;
                bytes[0] = 0x5e;
                @memcpy(bytes[1..], configuration[self.uploaded..][0..chunk_bytes]);
                try bus.transfer(address, &bytes, &.{});
                self.uploaded += chunk_bytes;
                self.state = if (self.uploaded == config_bytes) .commit else .upload_address;
            },
            .commit => {
                try bus.transfer(address, &.{ 0x59, 1 }, &.{});
                self.wait_us = 20_000;
                self.timeout_us = 150_000;
                self.state = .initialization;
            },
            .initialization => {
                var value: [1]u8 = undefined;
                try bus.transfer(address, &.{0x21}, &value);
                self.internal_status = value[0];
                if (value[0] == 1) self.state = .configure else if (value[0] != 0 or now >= self.deadline) return self.reject(.initialization);
            },
            .configure => {
                // Normal filters, both at 100 Hz, +/-4 g and +/-500 degrees/s.
                // Keep sensors disabled until configuration has been checked.
                try bus.transfer(address, &.{ 0x40, 0xa8, 1, 0xa8, 2 }, &.{});
                self.state = .check_config;
            },
            .check_config => {
                var value: [4]u8 = undefined;
                try bus.transfer(address, &.{0x40}, &value);
                if (!std.mem.eql(u8, &value, &.{ 0xa8, 1, 0xa8, 2 })) return self.reject(.configuration);
                self.state = .power;
            },
            .power => {
                try bus.transfer(address, &.{ 0x7d, 0x0e }, &.{});
                self.wait_us = 100_000; // Includes gyro startup.
                self.state = .check_power;
            },
            .check_power => {
                var value: [2]u8 = undefined;
                try bus.transfer(address, &.{0x7c}, &value);
                if (value[0] != 2 or value[1] != 0x0e) return self.reject(.configuration);
                self.initialized = true;
                self.timeout_us = 1_000_000;
                self.state = .status;
            },
            .status => {
                var value: [2]u8 = undefined;
                try bus.transfer(address, &.{2}, &value);
                self.error_register = value[0];
                self.ready_status = value[1];
                if (value[0] != 0) return self.reject(.sensor);
                if (value[1] & 0xc0 == 0xc0) self.state = .data else if (now >= self.deadline) return self.reject(.timeout);
            },
            .data => {
                var bytes: [12]u8 = undefined;
                try bus.transfer(address, &.{0x0c}, &bytes);
                self.sample = decode(bytes);
                self.samples +|= 1;
                self.valid = true;
                self.timeout_us = 1_000_000;
                self.wait_us = 10_000;
                self.state = .status;
            },
            .failed => unreachable,
        }
    }
};

pub fn decode(bytes: [12]u8) Sample {
    var result: Sample = .{};
    for (0..3) |axis| {
        result.acceleration[axis] = std.mem.readInt(i16, bytes[axis * 2 ..][0..2], .little);
        result.gyroscope[axis] = std.mem.readInt(i16, bytes[6 + axis * 2 ..][0..2], .little);
    }
    return result;
}

test {
    _ = @import("bmi270_test.zig");
}

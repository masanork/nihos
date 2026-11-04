//! Coordinates P4 RNG noise-source setup and cleanup; no entropy is sampled.
//! The caller must actually own the ADC, analog bus, clocks and power.
const std = @import("std");
const analog_mod = @import("rng_analog.zig");
const adc_mod = @import("rng_adc.zig");

pub const Noise = struct {
    const Phase = enum { idle, analog, digital, ready, cleanup, finished, quarantined };
    pub const Status = enum { pending, ready, stopped, failed, unavailable };
    phase: Phase = .idle,
    analog: analog_mod.Analog = .{},
    adc: adc_mod.Session = .{},
    deadline: u64 = 0,
    last: u64 = 0,
    failed: bool = false,

    fn ADCIO(comptime T: type) type {
        return struct {
            inner: T,
            noise: *Noise,
            pub fn ownershipValid(self: *@This()) bool {
                return self.inner.owned() and self.inner.clockReady();
            }
            pub fn analogReady(self: *@This()) bool {
                return self.noise.analog.phase == .ready and self.ownershipValid();
            }
            pub fn read(self: *@This(), addr: usize) u32 {
                return self.inner.read(addr);
            }
            pub fn write(self: *@This(), addr: usize, value: u32) void {
                self.inner.write(addr, value);
            }
        };
    }
    fn adapter(self: *Noise, io: anytype) ADCIO(@TypeOf(io)) {
        return .{ .inner = io, .noise = self };
    }

    /// Ownership and required power/clocks must already be held. The caller
    /// retains them until poll returns stopped or failed after cleanup.
    pub fn begin(self: *Noise, io: anytype, now: u64, timeout: u64, tx_timeout: u64) !void {
        if (self.phase != .idle) return error.Busy;
        if (timeout == 0 or tx_timeout == 0 or now > std.math.maxInt(u64) - timeout) return error.InvalidDeadline;
        var a = self.adapter(io);
        try self.adc.prepare(&a);
        self.analog.begin(io, now, timeout, tx_timeout) catch |err| {
            if (!self.adc.stop(&a)) self.phase = .quarantined;
            return err;
        };
        self.deadline = now + timeout;
        self.last = now;
        self.phase = .analog;
    }

    /// Stop the digital controller before restoring SAR analog registers.
    pub fn stop(self: *Noise, io: anytype) void {
        if (self.phase == .idle or self.phase == .finished or self.phase == .quarantined or self.phase == .cleanup) return;
        var a = self.adapter(io);
        if (!self.adc.stop(&a)) {
            self.phase = .quarantined;
            return;
        }
        self.analog.restore();
        self.phase = .cleanup;
    }

    pub fn poll(self: *Noise, io: anytype, now: u64) Status {
        if (self.phase == .idle) return .unavailable;
        if (self.phase == .quarantined) return .unavailable;
        if (self.phase == .finished) return if (self.failed) .failed else .stopped;
        if (!io.owned() or !io.clockReady()) {
            self.phase = .quarantined;
            return .unavailable;
        }
        if (self.phase != .cleanup and self.phase != .ready and (now < self.last or now >= self.deadline)) {
            self.failed = true;
            self.stop(io);
        }
        self.last = now;
        switch (self.phase) {
            .analog => switch (self.analog.poll(io, now)) {
                .ready => {
                    var a = self.adapter(io);
                    self.adc.activate(&a) catch {
                        self.failed = true;
                        self.stop(io);
                        return .pending;
                    };
                    self.phase = .digital;
                },
                .failed, .restored => {
                    self.failed = true;
                    self.stop(io);
                },
                .unavailable => {
                    self.phase = .quarantined;
                    return .unavailable;
                },
                .pending => {},
            },
            .digital, .ready => {
                var a = self.adapter(io);
                switch (self.adc.poll(&a)) {
                    .ready => {
                        self.phase = .ready;
                        return .ready;
                    },
                    .pending => {},
                    .unavailable => {
                        self.phase = .quarantined;
                        return .unavailable;
                    },
                }
            },
            .cleanup => switch (self.analog.poll(io, now)) {
                .restored => {
                    self.phase = .finished;
                    return if (self.failed) .failed else .stopped;
                },
                .failed => {
                    self.failed = true;
                    self.phase = .finished;
                    return .failed;
                },
                .unavailable => {
                    self.phase = .quarantined;
                    return .unavailable;
                },
                else => {},
            },
            .finished => return if (self.failed) .failed else .stopped,
            .quarantined, .idle => return .unavailable,
        }
        return .pending;
    }
};

const Fake = struct {
    control: u32 = 0,
    conf1: u32 = 0x2345,
    conf2: u32 = 0x5678,
    sar: [10]u8 = .{ 0xa1, 0xf2, 0, 0, 0, 0, 0, 0, 0, 0xac },
    adc: [9]u32 = .{ 0x40000000, 0x42, 0xab123456, 0, 0, 0, 0x1234, 0x12345678, 4 },
    held: bool = true,
    clock: bool = true,
    stuck: bool = false,
    pub fn owned(self: *@This()) bool {
        return self.held;
    }
    pub fn clockReady(self: *@This()) bool {
        return self.clock;
    }
    fn idx(addr: usize) usize {
        return switch (addr) {
            0x500de000 => 0,
            0x500de004 => 1,
            0x500de018 => 2,
            0x500de050 => 3,
            0x500de054 => 4,
            0x500de05c => 5,
            0x500de060 => 6,
            0x50127010 => 7,
            0x500e60a4 => 8,
            else => unreachable,
        };
    }
    pub fn read(self: *@This(), addr: usize) u32 {
        return switch (addr) {
            0x50124000 => self.control | (if (self.stuck) @as(u32, 1 << 25) else 0),
            0x50124004 => 0,
            0x5012401c => self.conf1,
            0x50124020 => self.conf2,
            else => self.adc[idx(addr)],
        };
    }
    pub fn write(self: *@This(), addr: usize, value: u32) void {
        switch (addr) {
            0x50124000 => {
                const reg: usize = (value >> 8) & 255;
                if (value & (1 << 24) != 0) self.sar[reg] = @truncate(value >> 16);
                self.control = @as(u32, self.sar[reg]) << 16;
            },
            0x5012401c => self.conf1 = value,
            0x50124020 => self.conf2 = value,
            0x500de05c => self.adc[idx(0x500de054)] &= ~value,
            else => self.adc[idx(addr)] = value,
        }
    }
};

test "analog then ADC readiness then ordered stop restore both register sets" {
    var io: Fake = .{};
    const initial_sar = io.sar;
    const initial_adc = io.adc;
    var noise: Noise = .{};
    var now: u64 = 0;
    try noise.begin(&io, now, 100, 10);
    for (0..100) |_| {
        if (noise.phase == .digital) io.adc[Fake.idx(0x500de054)] = 1 << 31;
        if (noise.poll(&io, now) == .ready) break;
        now += 1;
    }
    try std.testing.expectEqual(Noise.Phase.ready, noise.phase);
    try std.testing.expectEqual(@as(u8, 0xb0), io.sar[9]);
    noise.stop(&io);
    try std.testing.expectEqual(@as(u32, 0), io.adc[Fake.idx(0x500de004)] & (1 << 24));
    for (0..100) |_| {
        if (noise.poll(&io, now) == .stopped) break;
        now += 1;
    }
    try std.testing.expectEqual(Noise.Phase.finished, noise.phase);
    try std.testing.expectEqualSlices(u8, &initial_sar, &io.sar);
    try std.testing.expectEqualSlices(u32, &initial_adc, &io.adc);
}

test "deadline stops digital side and restores analog without claiming readiness" {
    var io: Fake = .{};
    const original = io.sar;
    var noise: Noise = .{};
    var now: u64 = 0;
    try noise.begin(&io, now, 50, 5);
    for (0..150) |_| {
        if (noise.poll(&io, now) == .failed) break;
        now += 1;
    }
    try std.testing.expectEqual(Noise.Phase.finished, noise.phase);
    try std.testing.expectEqualSlices(u8, &original, &io.sar);
}

test "late I2C completion keeps ownership until ADC and analog are restored" {
    var io: Fake = .{};
    const original = io.sar;
    const original_adc = io.adc;
    var noise: Noise = .{};
    var now: u64 = 0;
    try noise.begin(&io, now, 40, 5);
    for (0..80) |_| {
        if (noise.analog.dirty and noise.analog.inflight) break;
        _ = noise.poll(&io, now);
        now += 1;
    }
    try std.testing.expect(noise.analog.dirty and noise.analog.inflight);
    io.stuck = true;
    while (now < 55) : (now += 1) try std.testing.expectEqual(Noise.Status.pending, noise.poll(&io, now));
    try std.testing.expectEqual(Noise.Phase.cleanup, noise.phase);
    io.stuck = false;
    for (0..100) |_| {
        if (noise.poll(&io, now) == .failed) break;
        now += 1;
    }
    try std.testing.expectEqual(Noise.Phase.finished, noise.phase);
    try std.testing.expectEqualSlices(u8, &original, &io.sar);
    try std.testing.expectEqualSlices(u32, &original_adc, &io.adc);
}

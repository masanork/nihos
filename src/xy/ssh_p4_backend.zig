//! Connect P4 ADC setup, RNG sampling and SSH's bounded seed collector.
//! A platform must actually implement and qualify the exclusive ownership,
//! clock/power, MMIO and LP timer guarantees. This module does not enable SSH.
const noise_mod = @import("rng_noise");
const sampler_mod = @import("ssh_p4_sampler.zig");

/// Platform acquisition covers RNG, both SAR units, analog bus/selectors,
/// clock/power and the LP timer snapshot. It must retain ownership through
/// release and provide bounded callbacks. The collector remains unavailable
/// until noise setup and all sampler readiness checks have succeeded.
pub fn Backend(comptime Platform: type) type {
    return struct {
        const Self = @This();
        const Phase = enum { idle, acquired, starting, initializing, sampling, cleaning, quarantined };
        platform: *Platform,
        noise: noise_mod.Noise = .{},
        sampler: sampler_mod.Sampler = .{},
        phase: Phase = .idle,
        setup_timeout_us: u64,
        transaction_timeout_us: u64,
        default_cpu_mhz: u32,

        pub fn init(platform: *Platform, setup_timeout_us: u64, transaction_timeout_us: u64, default_cpu_mhz: u32) Self {
            return .{ .platform = platform, .setup_timeout_us = setup_timeout_us, .transaction_timeout_us = transaction_timeout_us, .default_cpu_mhz = default_cpu_mhz };
        }
        /// A failed acquire must have taken no ownership or changed hardware.
        pub fn begin(self: *Self) !void {
            if (self.phase != .idle) return error.Busy;
            if (!self.platform.acquire()) return error.Unavailable;
            self.phase = .acquired;
        }
        fn resourcesHeld(self: *Self) bool {
            return self.phase != .idle and self.phase != .quarantined and self.platform.owned() and self.platform.clockReady();
        }
        pub fn owned(self: *Self) bool {
            if (!self.resourcesHeld()) return false;
            if (self.phase != .sampling) return true;
            const now = self.platform.nowMicros();
            return self.platform.cpuHz() == self.sampler.cpu_hz and self.platform.apbHz() == self.sampler.apb_hz and
                now >= self.sampler.observed_us and self.noise.poll(self.platform, now) == .ready;
        }
        fn SamplingIO(comptime T: type) type {
            return struct {
                owner: *Self,
                p: T,
                pub fn ready(self: *@This()) bool {
                    return (self.owner.phase == .initializing or self.owner.phase == .sampling) and self.owner.owned();
                }
                pub fn cpuHz(self: *@This()) u32 {
                    return self.p.cpuHz();
                }
                pub fn apbHz(self: *@This()) u32 {
                    return self.p.apbHz();
                }
                pub fn cycles(self: *@This()) u32 {
                    return self.p.cycles();
                }
                pub fn nowMicros(self: *@This()) u64 {
                    return self.p.nowMicros();
                }
                pub fn readRng(self: *@This()) u32 {
                    return self.p.readRng();
                }
                pub fn lowTimerByte(self: *@This()) u8 {
                    return self.p.lowTimerByte();
                }
            };
        }
        fn samplingIO(self: *Self) SamplingIO(*Platform) {
            return .{ .owner = self, .p = self.platform };
        }

        /// At most one hardware state-machine step or sampler poll per call.
        pub fn sample(self: *Self) !?u8 {
            if (!self.owned()) return error.Unavailable;
            const now = self.platform.nowMicros();
            if (self.phase == .acquired) {
                self.noise.begin(self.platform, now, self.setup_timeout_us, self.transaction_timeout_us) catch |err| {
                    if (self.noise.phase != .idle) self.phase = .starting;
                    return err;
                };
                self.phase = .starting;
                return null;
            }
            if (self.phase == .starting) {
                switch (self.noise.poll(self.platform, now)) {
                    .ready => {
                        self.phase = .initializing;
                        var io = self.samplingIO();
                        try self.sampler.begin(&io, self.default_cpu_mhz);
                        self.phase = .sampling;
                    },
                    .pending => return null,
                    else => return error.Unavailable,
                }
                return null;
            }
            if (self.phase != .sampling) return error.Unavailable;
            if (self.noise.poll(self.platform, now) != .ready) return error.Unavailable;
            var io = self.samplingIO();
            return self.sampler.sample(&io);
        }
        /// On incomplete cleanup, retain every reservation and retry later.
        pub fn release(self: *Self) bool {
            self.sampler.clear();
            if (self.phase == .idle) return true;
            if (self.phase == .acquired and self.platform.owned()) {
                if (!self.platform.release()) return false;
                self.phase = .idle;
                return true;
            }
            if (self.phase == .quarantined or !self.resourcesHeld()) {
                self.phase = .quarantined;
                return false;
            }
            if (self.phase != .cleaning) {
                self.noise.stop(self.platform);
                self.phase = .cleaning;
            }
            switch (self.noise.poll(self.platform, self.platform.nowMicros())) {
                .stopped, .failed => {
                    if (!self.platform.release()) return false;
                    self.noise = .{};
                    self.phase = .idle;
                    return true;
                },
                .unavailable => self.phase = .quarantined,
                else => {},
            }
            return false;
        }
    };
}

const std = @import("std");
const collector_mod = @import("ssh_seed_collector.zig");
const entropy_mod = @import("ssh_entropy.zig");
const Fake = struct {
    acquired: bool = false,
    clock: bool = true,
    stuck: bool = false,
    now: u64 = 0,
    cycle: u32 = 0,
    random: u32 = 0,
    cpu: u32 = 160_000_000,
    timer: u8 = 0,
    control: u32 = 0,
    conf1: u32 = 0x2345,
    conf2: u32 = 0x5678,
    sar: [10]u8 = .{ 0xa1, 0xf2, 0, 0, 0, 0, 0, 0, 0, 0xac },
    adc: [9]u32 = .{ 0x40000000, 0x42, 0xab123456, 0, 0, 0, 0x1234, 0x12345678, 4 },
    pub fn acquire(self: *@This()) bool {
        if (self.acquired) return false;
        self.acquired = true;
        return true;
    }
    pub fn release(self: *@This()) bool {
        self.acquired = false;
        return true;
    }
    pub fn owned(self: *@This()) bool {
        return self.acquired;
    }
    pub fn clockReady(self: *@This()) bool {
        return self.clock;
    }
    pub fn cpuHz(self: *@This()) u32 {
        return self.cpu;
    }
    pub fn apbHz(_: *@This()) u32 {
        return 80_000_000;
    }
    pub fn cycles(self: *@This()) u32 {
        return self.cycle;
    }
    pub fn nowMicros(self: *@This()) u64 {
        return self.now;
    }
    pub fn readRng(self: *@This()) u32 {
        self.random +%= 1;
        return self.random;
    }
    pub fn lowTimerByte(self: *@This()) u8 {
        self.timer +%= 11;
        return self.timer;
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
            0x500de054 => self.adc[idx(addr)] | (if (self.adc[idx(0x500de004)] & (1 << 24) != 0) @as(u32, 1 << 31) else 0),
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
    fn tick(self: *@This()) void {
        self.now += 28;
        self.cycle +%= 4480;
    }
};

test "ADC through seed collector to CSPRNG and complete cleanup with simulated hardware" {
    var io: Fake = .{};
    const original_sar = io.sar;
    const original_adc = io.adc;
    var backend = Backend(Fake).init(&io, 20_000, 1_000, 160);
    var generations: collector_mod.Generations = .{};
    var collector = collector_mod.Collector(Backend(Fake)).init(&backend, &generations);
    var entropy: entropy_mod.Entropy = .{};
    defer entropy.clear();
    try collector.begin(0, 100_000);
    for (0..400) |_| {
        io.tick();
        collector.poll(io.now);
        if (collector.lease() != null) break;
    }
    try entropy.seedFrom(&collector);
    var output: [32]u8 = undefined;
    try entropy.fill(&output);
    try std.testing.expect(!std.mem.allEqual(u8, &output, 0));
    collector.cancel();
    for (0..200) |_| {
        io.tick();
        collector.poll(io.now);
        if (!io.acquired) break;
    }
    try std.testing.expect(!io.acquired);
    try std.testing.expectEqualSlices(u8, &original_sar, &io.sar);
    try std.testing.expectEqualSlices(u32, &original_adc, &io.adc);
}

test "busy analog bus retains reservation until cleanup is safe" {
    var io: Fake = .{};
    const original_sar = io.sar;
    var backend = Backend(Fake).init(&io, 10_000, 100, 160);
    var generations: collector_mod.Generations = .{};
    var collector = collector_mod.Collector(Backend(Fake)).init(&backend, &generations);
    try collector.begin(0, 30_000);
    for (0..100) |_| {
        io.tick();
        collector.poll(io.now);
        if (backend.noise.analog.dirty and backend.noise.analog.inflight) break;
    }
    try std.testing.expect(backend.noise.analog.dirty);
    io.stuck = true;
    collector.cancel();
    for (0..20) |_| {
        io.tick();
        collector.poll(io.now);
    }
    try std.testing.expect(io.acquired);
    io.stuck = false;
    for (0..100) |_| {
        io.tick();
        collector.poll(io.now);
        if (!io.acquired) break;
    }
    try std.testing.expect(!io.acquired);
    try std.testing.expectEqualSlices(u8, &original_sar, &io.sar);
}

test "clock change after collection revokes seed before admission and permits cleanup" {
    var io: Fake = .{};
    var backend = Backend(Fake).init(&io, 20_000, 1_000, 160);
    var generations: collector_mod.Generations = .{};
    var collector = collector_mod.Collector(Backend(Fake)).init(&backend, &generations);
    var entropy: entropy_mod.Entropy = .{};
    defer entropy.clear();
    try collector.begin(0, 100_000);
    for (0..400) |_| {
        io.tick();
        collector.poll(io.now);
        if (collector.lease() != null) break;
    }
    try std.testing.expect(collector.lease() != null);
    io.cpu = 80_000_000;
    try std.testing.expectError(error.EntropyUnavailable, entropy.seedFrom(&collector));
    collector.cancel();
    for (0..200) |_| {
        io.tick();
        collector.poll(io.now);
        if (!io.acquired) break;
    }
    try std.testing.expect(!io.acquired);
}

test "unexpected ADC event after collection revokes seed without clearing the event" {
    var io: Fake = .{};
    var backend = Backend(Fake).init(&io, 20_000, 1_000, 160);
    var generations: collector_mod.Generations = .{};
    var collector = collector_mod.Collector(Backend(Fake)).init(&backend, &generations);
    var entropy: entropy_mod.Entropy = .{};
    defer entropy.clear();
    try collector.begin(0, 100_000);
    for (0..400) |_| {
        io.tick();
        collector.poll(io.now);
        if (collector.lease() != null) break;
    }
    try std.testing.expect(collector.lease() != null);
    io.adc[Fake.idx(0x500de054)] |= 1 << 30;
    try std.testing.expectError(error.EntropyUnavailable, entropy.seedFrom(&collector));
    collector.cancel();
    collector.poll(io.now);
    try std.testing.expect(io.acquired);
    try std.testing.expect(io.adc[Fake.idx(0x500de054)] & (1 << 30) != 0);
}

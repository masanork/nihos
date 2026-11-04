//! Poll-driven ESP32-P4 RNG sampling, based on ESP-IDF v5.4.4 hw_random.c.
//! The IO must own a qualified, active SAR noise source and the RNG, LP timer
//! snapshot, and stable CPU/APB clocks. This module does not provide those
//! resources or qualify a device. Do not use its output without those proofs.
const std = @import("std");

pub const Sampler = struct {
    const Self = @This();
    cpu_hz: u32 = 0,
    apb_hz: u32 = 0,
    wait_cycles: u32 = 0,
    wait_us: u64 = 0,
    last_cycles: u32 = 0,
    last_us: u64 = 0,
    observed_us: u64 = 0,
    mixed: u32 = 0,
    stage: u8 = 0,
    bytes: [4]u8 = @splat(0),
    available: u8 = 0,
    offset: u8 = 0,
    active: bool = false,

    /// CPU/APB clocks and the specified IDF default CPU MHz must remain fixed.
    /// IO methods are bounded and the same source owner is held throughout.
    pub fn begin(self: *Self, io: anytype, default_cpu_mhz: u32) !void {
        self.clear();
        if (!io.ready()) return error.Unavailable;
        const cpu = io.cpuHz();
        const apb = io.apbHz();
        if (default_cpu_mhz == 0 or default_cpu_mhz > std.math.maxInt(u32) / 1_000_000 or
            cpu != default_cpu_mhz * 1_000_000 or apb == 0 or apb > cpu) return error.InvalidClock;
        const ratio = cpu / apb;
        const cycles = @as(u64, ratio) * default_cpu_mhz * 14;
        if (cycles == 0 or cycles > std.math.maxInt(u32)) return error.InvalidClock;
        self.cpu_hz = cpu;
        self.apb_hz = apb;
        self.wait_cycles = @intCast(cycles);
        self.wait_us = @as(u64, ratio) * 14;
        self.last_cycles = io.cycles();
        self.last_us = io.nowMicros();
        self.observed_us = self.last_us;
        self.active = true;
    }

    /// Returns at most one byte; no loop or wait occurs. The elapsed-cycle
    /// test and the four RNG/timer mixing steps match IDF's `esp_random`.
    pub fn sample(self: *Self, io: anytype) !?u8 {
        if (!self.active or !io.ready() or io.cpuHz() != self.cpu_hz or io.apbHz() != self.apb_hz) {
            self.clear();
            return error.Unavailable;
        }
        const now = io.nowMicros();
        if (now < self.observed_us) {
            self.clear();
            return error.Unavailable;
        }
        self.observed_us = now;
        if (self.available != 0) {
            const byte = self.bytes[self.offset];
            self.bytes[self.offset] = 0;
            self.offset += 1;
            self.available -= 1;
            return byte;
        }
        const cycles = io.cycles();
        self.mixed ^= io.readRng();
        // The extra monotonic bound prevents a reset or wrap of the hardware
        // cycle counter from admitting a word too soon.
        if (cycles -% self.last_cycles < self.wait_cycles or now - self.last_us < self.wait_us) return null;
        const shift: u5 = @intCast(@as(u32, self.stage) * 8);
        self.mixed ^= @as(u32, io.lowTimerByte()) << shift;
        self.stage += 1;
        if (self.stage != 4) return null;
        self.last_cycles = cycles;
        self.last_us = now;
        self.mixed ^= io.readRng();
        std.mem.writeInt(u32, &self.bytes, self.mixed, .little);
        self.mixed = 0;
        self.stage = 0;
        self.offset = 1;
        self.available = 3;
        const byte = self.bytes[0];
        self.bytes[0] = 0;
        return byte;
    }

    pub fn clear(self: *Self) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

const Fake = struct {
    ready_: bool = true,
    cpu: u32 = 160_000_000,
    apb: u32 = 80_000_000,
    cycles_: u32 = 0,
    now: u64 = 0,
    rng: u32 = 0,
    timer: u8 = 0x11,
    pub fn ready(self: *@This()) bool {
        return self.ready_;
    }
    pub fn cpuHz(self: *@This()) u32 {
        return self.cpu;
    }
    pub fn apbHz(self: *@This()) u32 {
        return self.apb;
    }
    pub fn cycles(self: *@This()) u32 {
        return self.cycles_;
    }
    pub fn nowMicros(self: *@This()) u64 {
        return self.now;
    }
    pub fn readRng(self: *@This()) u32 {
        self.rng += 1;
        return self.rng;
    }
    pub fn lowTimerByte(self: *@This()) u8 {
        const value = self.timer;
        self.timer +%= 0x11;
        return value;
    }
};

test "P4 IDF mixing yields a little-endian word only after the required delay" {
    var io: Fake = .{};
    var sampler: Sampler = .{};
    try sampler.begin(&io, 160);
    io.now = 13;
    io.cycles_ = 2080;
    try std.testing.expectEqual(@as(?u8, null), try sampler.sample(&io));
    io.now = 28;
    io.cycles_ = 4480;
    for (0..3) |_| try std.testing.expectEqual(@as(?u8, null), try sampler.sample(&io));
    try std.testing.expectEqual(@as(?u8, 0x16), try sampler.sample(&io));
    try std.testing.expectEqual(@as(?u8, 0x22), try sampler.sample(&io));
    try std.testing.expectEqual(@as(?u8, 0x33), try sampler.sample(&io));
    try std.testing.expectEqual(@as(?u8, 0x44), try sampler.sample(&io));
    try std.testing.expectEqual(@as(?u8, null), try sampler.sample(&io));
    sampler.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&sampler), 0));
}

test "loss of readiness, clock changes and time rollback erase buffered bytes" {
    var io: Fake = .{};
    var sampler: Sampler = .{};
    try sampler.begin(&io, 160);
    io.now = 28;
    io.cycles_ = 4480;
    for (0..4) |_| _ = try sampler.sample(&io);
    try std.testing.expect(sampler.available != 0);
    io.ready_ = false;
    try std.testing.expectError(error.Unavailable, sampler.sample(&io));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&sampler), 0));
    io.ready_ = true;
    try sampler.begin(&io, 160);
    io.apb = 40_000_000;
    try std.testing.expectError(error.Unavailable, sampler.sample(&io));
    io.apb = 80_000_000;
    try sampler.begin(&io, 160);
    io.now -= 1;
    try std.testing.expectError(error.Unavailable, sampler.sample(&io));
}

test "sampler drives the actual collector and CSPRNG with fake input" {
    const entropy = @import("ssh_entropy.zig");
    const collection = @import("ssh_seed_collector.zig");
    const Backend = struct {
        sampler: Sampler = .{},
        io: *Fake,
        pub fn begin(self: *@This()) !void {
            try self.sampler.begin(self.io, 160);
        }
        pub fn owned(self: *@This()) bool {
            return self.io.ready_;
        }
        pub fn sample(self: *@This()) !?u8 {
            return self.sampler.sample(self.io);
        }
        pub fn release(self: *@This()) bool {
            self.sampler.clear();
            return true;
        }
    };
    var io: Fake = .{};
    var backend: Backend = .{ .io = &io };
    var generations: collection.Generations = .{};
    var collector = collection.Collector(Backend).init(&backend, &generations);
    var generator: entropy.Entropy = .{};
    defer generator.clear();
    try collector.begin(0, 100_000);
    for (0..256) |_| {
        io.now += 28;
        io.cycles_ +%= 4480;
        collector.poll(io.now);
        if (collector.lease() != null) break;
    }
    try generator.seedFrom(&collector);
    var out: [32]u8 = undefined;
    try generator.fill(&out);
    try std.testing.expect(!std.mem.allEqual(u8, &out, 0));
    collector.cancel();
    collector.poll(io.now);
}

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
        pub fn initInPlace(self: *Self, platform: *Platform, setup_timeout_us: u64, transaction_timeout_us: u64, default_cpu_mhz: u32) void {
            self.platform = platform;
            self.noise = .{};
            self.sampler.clear();
            self.phase = .idle;
            self.setup_timeout_us = setup_timeout_us;
            self.transaction_timeout_us = transaction_timeout_us;
            self.default_cpu_mhz = default_cpu_mhz;
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

/// A foreground tick supplies one already-read monotonic timestamp. This avoids
/// taking extra snapshots of the shared hardware timer inside the entropy
/// pipeline. The outer owner remains responsible for a live, qualified timer;
/// a frozen or repeatedly supplied value cannot establish elapsed time.
/// Only the foreground owner may update it. Keep it stable and do not reset
/// it while a session is live.
pub const TickTimer = struct {
    last: u64 = 0,
    valid: bool = false,
    failed: bool = false,

    pub fn observe(self: *TickTimer, now: u64) bool {
        if (self.failed) return false;
        if (self.valid and now < self.last) {
            self.failed = true;
            return false;
        }
        self.last = now;
        self.valid = true;
        return true;
    }
    pub fn counter(self: *TickTimer) ?u64 {
        return if (self.valid and !self.failed) self.last else null;
    }
};

/// Compose the P4 entropy pipeline in stable caller-owned storage. The caller
/// must retain the gate, hardware reservation, MMIO, timer and boot-epoch
/// generation counter, and must not move or reinitialize this object while a
/// session or its cleanup is live. This does not provide or qualify a native
/// resource owner, timer, entropy source, or product-image placement.
pub fn Prepared(comptime Gate: type, comptime Resources: type, comptime Access: type, comptime Timer: type) type {
    const lease_mod = @import("p4_entropy_lease");
    const hw_mod = @import("p4_entropy_hardware");
    const clock_mod = @import("p4_entropy_clock");
    const session_mod = @import("ssh_entropy_session.zig");
    const Reservation = lease_mod.Lease(Gate, Resources);
    const ClockIO = struct {
        reservation: *Reservation,
        access: *Access,
        timer: *Timer,
        pub fn owned(self: *@This()) bool {
            return self.reservation.owned();
        }
        pub fn read(self: *@This(), address: usize) u32 {
            return self.access.read(address);
        }
        pub fn counter(self: *@This()) ?u64 {
            return self.timer.counter();
        }
    };
    const Clock = clock_mod.Guard(ClockIO);
    const Hardware = hw_mod.Hardware(Access, Clock);
    const Platform = lease_mod.Platform(Reservation, Hardware);
    const P4Backend = Backend(Platform);
    const Session = session_mod.Session(P4Backend);
    return struct {
        const Self = @This();
        reservation: Reservation,
        clock_io: ClockIO,
        clock: Clock,
        hardware: Hardware,
        platform: Platform,
        backend: P4Backend,
        session: Session,

        /// Reject a missing receipt before acquiring anything or modifying self.
        /// A fresh instance may be initialized only after any previous cleanup.
        pub fn initInPlace(self: *Self, gate: *Gate, resources: *Resources, access: *Access, timer: *Timer, generations: *session_mod.Generations, receipt: ?clock_mod.Receipt) error{MissingClockReceipt}!void {
            const verified = receipt orelse return error.MissingClockReceipt;
            self.reservation = Reservation.init(gate, resources);
            self.clock_io = .{ .reservation = &self.reservation, .access = access, .timer = timer };
            self.clock = Clock.init(&self.clock_io, verified);
            self.hardware = .{ .access = access, .clock = &self.clock };
            self.platform = .{ .reservation = &self.reservation, .hardware = &self.hardware };
            self.backend.initInPlace(&self.platform, 20_000, 1_000, 360);
            self.session.initInPlace(&self.backend, generations);
        }
    };
}

const std = @import("std");
const collector_mod = @import("ssh_seed_collector.zig");
pub const Generations = collector_mod.Generations;
const entropy_mod = @import("ssh_entropy.zig");
const Fake = struct {
    gate: ?*@import("p4_rng_gate").Gate = null,
    token: u32 = 0,
    acquired: bool = false,
    clock: bool = true,
    stuck: bool = false,
    now: u64 = 0,
    cycle: u32 = 0,
    random: u32 = 0,
    cpu: u32 = 160_000_000,
    apb: u32 = 80_000_000,
    timer: u8 = 0,
    clock_source: u32 = 1,
    timer_snapshots: u32 = 0,
    control: u32 = 0,
    conf1: u32 = 0x2345,
    conf2: u32 = 0x5678,
    sar: [10]u8 = .{ 0xa1, 0xf2, 0, 0, 0, 0, 0, 0, 0, 0xac },
    adc: [9]u32 = .{ 0x40000000, 0x42, 0xab123456, 0, 0, 0, 0x1234, 0x12345678, 4 },
    pub fn acquire(self: *@This()) bool {
        if (self.acquired) return false;
        if (self.gate) |gate| {
            self.token = gate.tryEntropy();
            if (self.token == 0) return false;
        }
        self.acquired = true;
        return true;
    }
    pub fn release(self: *@This()) bool {
        if (self.gate) |gate| {
            if (!gate.releaseEntropy(self.token)) return false;
            self.token = 0;
        }
        self.acquired = false;
        return true;
    }
    pub fn owned(self: *@This()) bool {
        return self.acquired and (if (self.gate) |gate| gate.ownsEntropy(self.token) else true);
    }
    pub fn clockReady(self: *@This()) bool {
        return self.clock;
    }
    pub fn cpuHz(self: *@This()) u32 {
        return self.cpu;
    }
    pub fn apbHz(self: *@This()) u32 {
        return self.apb;
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
            0x500e6004 => 0,
            0x500e6008 => 1,
            0x500e600c => 1 << 16,
            0x50111040 => self.clock_source,
            0x501101a4 => self.readRng(),
            0x50112010 => 0,
            0x50112014 => self.lowTimerByte(),
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
            0x50112010 => {},
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
    pub fn counter(self: *@This()) ?u64 {
        self.timer_snapshots += 1;
        return self.now;
    }
    fn tick(self: *@This()) void {
        self.now += 28;
        self.cycle +%= self.cpu / 1_000_000 * 28;
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
    var gate: @import("p4_rng_gate").Gate = .{};
    var io: Fake = .{ .gate = &gate };
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
    try std.testing.expect(!gate.trySqlite());
    io.stuck = false;
    for (0..100) |_| {
        io.tick();
        collector.poll(io.now);
        if (!io.acquired) break;
    }
    try std.testing.expect(!io.acquired);
    try std.testing.expectEqualSlices(u8, &original_sar, &io.sar);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
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

test "native RNG gate remains held through simulated entropy cleanup" {
    var gate: @import("p4_rng_gate").Gate = .{};
    var io: Fake = .{ .gate = &gate };
    var backend = Backend(Fake).init(&io, 20_000, 1_000, 160);
    var generations: collector_mod.Generations = .{};
    var collector = collector_mod.Collector(Backend(Fake)).init(&backend, &generations);

    try std.testing.expect(gate.trySqlite());
    try std.testing.expectError(error.Unavailable, collector.begin(0, 100_000));
    try std.testing.expect(!io.acquired and io.token == 0);
    try std.testing.expect(gate.releaseSqlite());
    try collector.begin(0, 100_000);
    const first = io.token;
    for (0..400) |_| {
        io.tick();
        collector.poll(io.now);
        try std.testing.expect(!gate.trySqlite());
        if (collector.lease() != null) break;
    }
    try std.testing.expect(collector.lease() != null);
    collector.cancel();
    try std.testing.expect(!gate.trySqlite());
    var cleaned = false;
    for (0..400) |_| {
        io.tick();
        collector.poll(io.now);
        if (!io.acquired) {
            cleaned = true;
            break;
        }
        try std.testing.expect(!gate.trySqlite());
    }
    try std.testing.expect(cleaned);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
    try collector.begin(io.now, 100_000);
    try std.testing.expect(io.token != first);
    try std.testing.expect(!gate.releaseEntropy(first));
    try std.testing.expect(!gate.trySqlite());
    collector.cancel();
    collector.poll(io.now);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
}

test "entropy session waits for the real backend and gate cleanup" {
    const sessions = @import("ssh_entropy_session.zig");
    var gate: @import("p4_rng_gate").Gate = .{};
    var io: Fake = .{ .gate = &gate };
    var backend = Backend(Fake).init(&io, 20_000, 1_000, 160);
    var generations: collector_mod.Generations = .{};
    var session = sessions.Session(Backend(Fake)).init(&backend, &generations);
    try session.begin(0, 100_000);
    var saw_restoring = false;
    for (0..800) |_| {
        io.tick();
        session.poll(io.now);
        if (session.state == .restoring) {
            saw_restoring = true;
            try std.testing.expect(!session.available());
            try std.testing.expect(!gate.trySqlite());
        }
        if (session.available()) break;
    }
    try std.testing.expect(saw_restoring and session.available());
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
    var output: [32]u8 = undefined;
    try session.fill(&output);
    try std.testing.expect(!std.mem.allEqual(u8, &output, 0));
    session.cancel();
    session.poll(io.now);
    try std.testing.expectEqual(.idle, session.state);
}

test "stuck analog restoration never admits or retains cancelled entropy" {
    const sessions = @import("ssh_entropy_session.zig");
    var gate: @import("p4_rng_gate").Gate = .{};
    var io: Fake = .{ .gate = &gate };
    var backend = Backend(Fake).init(&io, 20_000, 100, 160);
    var generations: collector_mod.Generations = .{};
    var session = sessions.Session(Backend(Fake)).init(&backend, &generations);
    try session.begin(0, 100_000);
    for (0..400) |_| {
        io.tick();
        session.poll(io.now);
        if (session.state == .restoring) break;
    }
    try std.testing.expectEqual(.restoring, session.state);
    io.stuck = true;
    for (0..20) |_| {
        io.tick();
        session.poll(io.now);
        try std.testing.expect(!session.available());
        try std.testing.expect(!gate.trySqlite());
    }
    session.cancel();
    try std.testing.expect(!session.entropy.available());
    io.stuck = false;
    for (0..200) |_| {
        io.tick();
        session.poll(io.now);
        if (session.state == .idle) break;
    }
    try std.testing.expectEqual(.idle, session.state);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
}

const TestForegroundModel = struct {
    pub const PrivateInputKey = union(enum) { text: u8, backspace, left, up, right, down, enter, escape, cancel, eof };
    pub const PrivateInputPortType = struct {
        pub const View = struct { field: u8, secret_length: u8, invalid: u8, text: [*]const u8, text_length: usize };
        context: *anyopaque,
        key: *const fn (*anyopaque, PrivateInputKey) bool,
        close: *const fn (*anyopaque) void,
        snapshot: *const fn (*anyopaque, *View) bool,
    };
    private_input: ?PrivateInputPortType = null,
    pub fn attachPrivateInput(self: *@This(), port: PrivateInputPortType) bool {
        if (self.private_input != null) return false;
        self.private_input = port;
        return true;
    }
    pub fn detachPrivateInput(self: *@This()) void {
        const port = self.private_input orelse return;
        self.private_input = null;
        port.close(port.context);
    }
};
const TestForegroundController = struct {
    state: @import("ssh_lifecycle.zig").State = .idle,
    pub fn beginProfile(_: *@This(), _: *const @import("ssh_lifecycle.zig").Profile, _: u64, _: u64, _: u64, _: u16, _: u32) !void {}
    pub fn pollProfile(_: *@This(), _: *const @import("ssh_lifecycle.zig").Profile, _: u64, _: ?*const @import("ssh_lifecycle.zig").ExchangeEntropy, _: *const [32]u8) !@import("ssh_lifecycle.zig").State {
        return .opening;
    }
    pub fn cancel(_: *@This()) void {}
    pub fn retryCleanup(_: *@This()) bool {
        return true;
    }
};

test "SSH foreground waits for SQLite RNG gate then opens setup after cleanup" {
    const sessions = @import("ssh_entropy_session.zig");
    const lifecycle = @import("ssh_lifecycle.zig");
    var gate: @import("p4_rng_gate").Gate = .{};
    var io: Fake = .{ .gate = &gate };
    var backend = Backend(Fake).init(&io, 20_000, 1_000, 160);
    var generations: collector_mod.Generations = .{};
    var session = sessions.Session(Backend(Fake)).init(&backend, &generations);
    var model: TestForegroundModel = .{};
    var controller: TestForegroundController = .{};
    var foreground = try lifecycle.PreparedForeground(TestForegroundModel, TestForegroundController, @TypeOf(session)).init(&model, &controller, &session, 100_000, 20_000, 5_000);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expectEqual(.acquiring, foreground.poll(true, 0));
    io.tick();
    try std.testing.expectEqual(.acquiring, foreground.poll(true, io.now));
    try std.testing.expect(!io.acquired and model.private_input == null);
    try std.testing.expect(gate.releaseSqlite());
    io.tick();
    try std.testing.expectEqual(.preparing, foreground.poll(true, io.now));
    try std.testing.expectEqual(@as(u64, 100_000), session.collector.deadline);
    var saw_restore = false;
    for (0..800) |_| {
        io.tick();
        const state = foreground.poll(true, io.now);
        if (session.state == .restoring) {
            saw_restore = true;
            try std.testing.expect(!gate.trySqlite());
        }
        try std.testing.expect(model.private_input == null);
        if (state == .active) break;
    }
    try std.testing.expect(saw_restore and foreground.state == .active);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
    io.tick();
    try std.testing.expectEqual(.active, foreground.poll(true, io.now));
    try std.testing.expect(model.private_input != null);
    io.tick();
    _ = foreground.poll(false, io.now);
    try std.testing.expect(model.private_input == null and !session.available());
}

test "composed reservation and P4 backend restore before seed becomes available" {
    const clock_mod = @import("p4_entropy_clock");
    const Gate = @import("p4_rng_gate").Gate;
    const Resources = struct {
        io: *Fake,
        original_sar: [10]u8,
        original_adc: [9]u32,
        reserved: bool = false,
        release_allowed: bool = false,
        saw_restored: bool = false,
        pub fn tryReserve(self: *@This()) bool {
            if (self.reserved) return false;
            self.reserved = true;
            return true;
        }
        pub fn owned(self: *@This()) bool {
            return self.reserved;
        }
        pub fn releaseUnused(self: *@This()) void {
            self.reserved = false;
        }
        pub fn releaseRestored(self: *@This()) bool {
            self.saw_restored = std.mem.eql(u8, &self.io.sar, &self.original_sar) and
                std.mem.eql(u32, &self.io.adc, &self.original_adc);
            if (!self.release_allowed or !self.saw_restored) return false;
            self.reserved = false;
            return true;
        }
    };
    var gate: Gate = .{};
    var io: Fake = .{};
    var resources = Resources{ .io = &io, .original_sar = io.sar, .original_adc = io.adc };
    io.cpu = 360_000_000;
    io.apb = 90_000_000;
    var generations: collector_mod.Generations = .{};
    var timer: TickTimer = .{};
    try std.testing.expect(timer.observe(io.now));
    const prepared = try std.testing.allocator.create(Prepared(Gate, Resources, Fake, TickTimer));
    defer std.testing.allocator.destroy(prepared);
    @memset(std.mem.asBytes(prepared), 0xa5);
    try std.testing.expectError(error.MissingClockReceipt, prepared.initInPlace(&gate, &resources, &io, &timer, &generations, null));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(prepared), 0xa5));
    try std.testing.expect(!resources.reserved and gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
    const report = .{ .status = @as(u32, 1), .error_code = @as(u32, 0), .source = @as(u32, 1), .cpll_mhz = @as(u32, 360), .after_mhz = @as(u32, 360), .mem_mhz = @as(u32, 180), .apb_mhz = @as(u32, 90), .rom_mhz = @as(u32, 360), .ctrl0 = @as(u32, 0), .ctrl1 = @as(u32, 1), .ctrl2 = @as(u32, 1 << 16) };
    const receipt = clock_mod.receiptFromBoot(report, &io) orelse return error.MissingClockReceipt;
    try prepared.initInPlace(&gate, &resources, &io, &timer, &generations, receipt);
    const session = &prepared.session;

    try std.testing.expect(gate.trySqlite());
    try std.testing.expectError(error.Unavailable, session.begin(0, 100_000));
    try std.testing.expect(!resources.reserved);
    try std.testing.expect(gate.releaseSqlite());
    try session.begin(0, 100_000);
    for (0..800) |_| {
        io.tick();
        try std.testing.expect(timer.observe(io.now));
        session.poll(io.now);
        if (resources.saw_restored) break;
    }
    try std.testing.expect(resources.saw_restored and resources.reserved);
    try std.testing.expectEqual(.restoring, session.state);
    try std.testing.expect(!session.available() and !gate.trySqlite());
    resources.release_allowed = true;
    io.tick();
    try std.testing.expect(timer.observe(io.now));
    session.poll(io.now);
    try std.testing.expect(session.available() and !resources.reserved);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expect(gate.releaseSqlite());
    session.cancel();
    session.poll(io.now);
    try std.testing.expectEqual(.idle, session.state);

    // The same in-place graph can safely start a new generation after cleanup.
    try session.begin(io.now, 100_000);
    try std.testing.expectEqual(@as(u64, 2), generations.last);
    for (0..100) |_| {
        io.tick();
        try std.testing.expect(timer.observe(io.now));
        session.poll(io.now);
        if (prepared.backend.noise.analog.dirty) break;
    }
    try std.testing.expect(prepared.backend.noise.analog.dirty);
    io.clock_source = 0;
    io.tick();
    try std.testing.expect(timer.observe(io.now));
    session.poll(io.now);
    io.tick();
    try std.testing.expect(timer.observe(io.now));
    session.poll(io.now);
    try std.testing.expect(!session.available() and resources.reserved);
    try std.testing.expect(!gate.trySqlite());
    try std.testing.expectEqual(.failed_cleanup, session.state);
    // All timing came from foreground ticks, not another shared timer capture.
    try std.testing.expectEqual(@as(u32, 0), io.timer_snapshots);
}

test "foreground tick time is unavailable until observed and latches rollback" {
    var timer: TickTimer = .{};
    try std.testing.expect(timer.counter() == null);
    try std.testing.expect(timer.observe(100));
    try std.testing.expectEqual(@as(?u64, 100), timer.counter());
    try std.testing.expect(timer.observe(100));
    try std.testing.expect(timer.observe(101));
    try std.testing.expect(!timer.observe(100));
    try std.testing.expect(timer.counter() == null);
    try std.testing.expect(!timer.observe(102));
}

test "tick-driven foreground prepares entropy before credentials and closes on rollback" {
    const clock_mod = @import("p4_entropy_clock");
    const lifecycle = @import("ssh_lifecycle.zig");
    const Gate = @import("p4_rng_gate").Gate;
    const Resources = struct {
        reserved: bool = false,
        pub fn tryReserve(self: *@This()) bool {
            if (self.reserved) return false;
            self.reserved = true;
            return true;
        }
        pub fn owned(self: *@This()) bool {
            return self.reserved;
        }
        pub fn releaseUnused(self: *@This()) void {
            self.reserved = false;
        }
        pub fn releaseRestored(self: *@This()) bool {
            self.reserved = false;
            return true;
        }
    };
    var gate: Gate = .{};
    var resources: Resources = .{};
    var io: Fake = .{ .cpu = 360_000_000, .apb = 90_000_000 };
    var generations: Generations = .{};
    var timer: TickTimer = .{};
    const prepared = try std.testing.allocator.create(Prepared(Gate, Resources, Fake, TickTimer));
    defer std.testing.allocator.destroy(prepared);
    const report = .{ .status = @as(u32, 1), .error_code = @as(u32, 0), .source = @as(u32, 1), .cpll_mhz = @as(u32, 360), .after_mhz = @as(u32, 360), .mem_mhz = @as(u32, 180), .apb_mhz = @as(u32, 90), .rom_mhz = @as(u32, 360), .ctrl0 = @as(u32, 0), .ctrl1 = @as(u32, 1), .ctrl2 = @as(u32, 1 << 16) };
    const receipt = clock_mod.receiptFromBoot(report, &io) orelse return error.MissingClockReceipt;
    try prepared.initInPlace(&gate, &resources, &io, &timer, &generations, receipt);
    var model: TestForegroundModel = .{};
    var controller: TestForegroundController = .{};
    const Timed = lifecycle.TimedPreparedForeground(TestForegroundModel, TestForegroundController, @TypeOf(prepared.session), TickTimer);
    const timed = try std.testing.allocator.create(Timed);
    defer std.testing.allocator.destroy(timed);
    try timed.initInPlace(&model, &controller, &prepared.session, &timer, 100_000, 20_000, 5_000);
    try std.testing.expect(gate.trySqlite());
    try std.testing.expectEqual(.acquiring, timed.poll(true, 0));
    io.tick();
    try std.testing.expectEqual(.acquiring, timed.poll(true, io.now));
    try std.testing.expect(model.private_input == null and !resources.reserved);
    try std.testing.expect(gate.releaseSqlite());
    var saw_restoring = false;
    for (0..800) |_| {
        io.tick();
        const state = timed.poll(true, io.now);
        if (prepared.session.state == .restoring) {
            saw_restoring = true;
            try std.testing.expect(!gate.trySqlite());
        }
        try std.testing.expect(model.private_input == null);
        if (state == .active) break;
    }
    try std.testing.expect(saw_restoring and prepared.session.available());
    io.tick();
    try std.testing.expectEqual(.active, timed.poll(true, io.now));
    try std.testing.expect(model.private_input != null);
    try std.testing.expectEqual(.failed, timed.poll(true, io.now - 1));
    try std.testing.expect(model.private_input == null and !prepared.session.available());
    try std.testing.expectEqual(.idle, timed.poll(false, io.now));
    try std.testing.expectEqual(@as(u32, 0), io.timer_snapshots);
}

test "tick rollback holds foreground until pending cleanup finishes" {
    const lifecycle = @import("ssh_lifecycle.zig");
    const Entropy = struct {
        state: enum { idle, collecting, cleaning, failed } = .idle,
        held: bool = false,
        release_allowed: bool = false,
        pub fn begin(self: *@This(), _: u64, _: u64) !void {
            self.held = true;
            self.state = .collecting;
        }
        pub fn poll(self: *@This(), _: u64) void {
            if (self.state == .cleaning and self.release_allowed) {
                self.held = false;
                self.state = .idle;
            }
        }
        pub fn cancel(self: *@This()) void {
            if (self.state != .idle) self.state = .cleaning;
        }
        pub fn available(_: *@This()) bool {
            return false;
        }
        pub fn fill(_: *@This(), _: []u8) error{EntropyUnavailable}!void {
            return error.EntropyUnavailable;
        }
    };
    var timer: TickTimer = .{};
    var entropy: Entropy = .{};
    var model: TestForegroundModel = .{};
    var controller: TestForegroundController = .{};
    const Timed = lifecycle.TimedPreparedForeground(TestForegroundModel, TestForegroundController, Entropy, TickTimer);
    const timed = try std.testing.allocator.create(Timed);
    defer std.testing.allocator.destroy(timed);
    try timed.initInPlace(&model, &controller, &entropy, &timer, 100, 100, 100);
    try std.testing.expectEqual(.preparing, timed.poll(true, 10));
    try std.testing.expectEqual(.stopping, timed.poll(true, 9));
    try std.testing.expect(entropy.held and model.private_input == null);
    try std.testing.expectEqual(.stopping, timed.poll(false, 11));
    entropy.release_allowed = true;
    try std.testing.expectEqual(.idle, timed.poll(false, 12));
    try std.testing.expect(!entropy.held);
    try std.testing.expectEqual(.failed, timed.poll(true, 13));
}

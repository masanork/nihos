//! Nonblocking, single-use seed collection for SSH.
//! This is not an entropy source: a backend must independently qualify its
//! samples, serialize access to hardware, and restore it before releasing it.
const std = @import("std");
const entropy = @import("ssh_entropy.zig");

/// Keep this counter alive for the entire boot epoch; do not copy or reset it.
/// All collectors sharing a source must use the same counter.
pub const Generations = struct { last: u64 = 0 };

/// Backend methods must be bounded and called by a single owner:
/// begin() acquires exclusive hardware ownership; sample() returns a fresh,
/// uniformly random byte or null while waiting; release() returns false while
/// cleanup is incomplete. An error from begin means no ownership was taken.
/// A sample error means cleanup is still required. Samples must collectively
/// provide 256 bits of secret entropy; pacing is the backend's responsibility.
/// No backend may be claimed qualified merely by passing these tests.
pub fn Collector(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const State = enum { idle, collecting, ready, consumed, cleaning };
        backend: *Backend,
        generations: *Generations,
        state: State = .idle,
        seed: [entropy.seed_bytes]u8 = @splat(0),
        count: usize = 0,
        deadline: u64 = 0,
        last_poll: u64 = 0,
        generation: u64 = 0,

        pub fn init(backend: *Backend, generations: *Generations) Self {
            return .{ .backend = backend, .generations = generations };
        }

        /// Initialize stable storage; the caller must not reset a live collector.
        pub fn initInPlace(self: *Self, backend: *Backend, generations: *Generations) void {
            self.backend = backend;
            self.generations = generations;
            self.state = .idle;
            std.crypto.secureZero(u8, &self.seed);
            self.count = 0;
            self.deadline = 0;
            self.last_poll = 0;
            self.generation = 0;
        }

        pub fn begin(self: *Self, now: u64, timeout: u64) !void {
            if (self.state != .idle) return error.Busy;
            if (timeout == 0 or now > std.math.maxInt(u64) - timeout) return error.InvalidDeadline;
            if (self.generations.last == std.math.maxInt(u64)) return error.GenerationExhausted;
            try self.backend.begin();
            self.generations.last += 1;
            self.generation = self.generations.last;
            self.deadline = now + timeout;
            self.last_poll = now;
            self.state = .collecting;
        }

        /// At most one backend sample or cleanup attempt per call. Call with
        /// the current monotonic time immediately before trying seedFrom.
        pub fn poll(self: *Self, now: u64) void {
            if (self.state == .cleaning) {
                if (self.backend.release()) self.state = .idle;
                return;
            }
            if (self.state != .collecting and self.state != .ready) return;
            if (now < self.last_poll or now >= self.deadline or !self.backend.owned()) {
                self.cancel();
                return;
            }
            self.last_poll = now;
            if (self.state == .ready) return;
            const byte = self.backend.sample() catch {
                self.cancel();
                return;
            };
            if (byte) |value| {
                self.seed[self.count] = value;
                self.count += 1;
                if (self.count == self.seed.len) self.state = .ready;
            }
        }

        pub fn lease(self: *Self) ?u64 {
            return if ((self.state == .ready or self.state == .consumed) and self.backend.owned()) self.generation else null;
        }

        pub fn fillSeed(self: *Self, generation: u64, out: *[entropy.seed_bytes]u8) !void {
            if (self.state != .ready or self.lease() != generation) return error.EntropyUnavailable;
            out.* = self.seed;
            std.crypto.secureZero(u8, &self.seed);
            self.count = 0;
            self.state = .consumed;
        }

        /// Wipes immediately; subsequent poll calls retry incomplete cleanup.
        pub fn cancel(self: *Self) void {
            std.crypto.secureZero(u8, &self.seed);
            self.count = 0;
            if (self.state != .idle) self.state = .cleaning;
        }
    };
}

const Fake = struct {
    acquired: bool = false,
    waiting: bool = false,
    fail: bool = false,
    release_ready: bool = true,
    next: u8 = 0,
    fn begin(self: *@This()) !void {
        if (self.acquired) return error.Busy;
        self.acquired = true;
    }
    fn owned(self: *@This()) bool {
        return self.acquired;
    }
    fn sample(self: *@This()) !?u8 {
        if (self.fail) return error.Failure;
        if (self.waiting) return null;
        const result = self.next;
        self.next +%= 1;
        return result;
    }
    fn release(self: *@This()) bool {
        if (!self.release_ready) return false;
        self.acquired = false;
        return true;
    }
};

test "complete seed is admitted once and cleanup permits a fresh generation" {
    var backend: Fake = .{};
    var generations: Generations = .{};
    var collector = Collector(Fake).init(&backend, &generations);
    var generator: entropy.Entropy = .{};
    defer generator.clear();
    try collector.begin(1, 100);
    for (0..entropy.seed_bytes - 1) |_| collector.poll(2);
    try std.testing.expectError(error.EntropyUnavailable, generator.seedFrom(&collector));
    collector.poll(2);
    try generator.seedFrom(&collector);
    try std.testing.expect(generator.available());
    try std.testing.expect(std.mem.allEqual(u8, &collector.seed, 0));
    try std.testing.expectError(error.EntropyUnavailable, generator.seedFrom(&collector));
    collector.cancel();
    collector.poll(2);
    try collector.begin(3, 100);
    try std.testing.expectEqual(@as(u64, 2), collector.generation);
}

test "timeout and failed cleanup wipe partial seed and prevent reacquisition" {
    var backend: Fake = .{};
    var generations: Generations = .{};
    var collector = Collector(Fake).init(&backend, &generations);
    try collector.begin(10, 5);
    collector.poll(11);
    collector.poll(12);
    backend.release_ready = false;
    collector.poll(15);
    try std.testing.expect(std.mem.allEqual(u8, &collector.seed, 0));
    try std.testing.expectEqual(@as(?u64, null), collector.lease());
    collector.poll(16);
    try std.testing.expectError(error.Busy, collector.begin(16, 5));
    backend.release_ready = true;
    collector.poll(17);
    try collector.begin(18, 5);
    backend.fail = true;
    collector.poll(19);
    try std.testing.expect(std.mem.allEqual(u8, &collector.seed, 0));
    try std.testing.expectEqual(@as(?u64, null), collector.lease());
}

test "revocation, invalid deadlines, and generation exhaustion fail closed" {
    var backend: Fake = .{};
    var generations: Generations = .{};
    var collector = Collector(Fake).init(&backend, &generations);
    try std.testing.expectError(error.InvalidDeadline, collector.begin(0, 0));
    try std.testing.expectError(error.InvalidDeadline, collector.begin(std.math.maxInt(u64), 1));
    try collector.begin(0, 100);
    for (0..entropy.seed_bytes) |_| collector.poll(1);
    backend.acquired = false;
    try std.testing.expectEqual(@as(?u64, null), collector.lease());
    collector.poll(2);
    try std.testing.expect(std.mem.allEqual(u8, &collector.seed, 0));
    collector.poll(3);
    generations.last = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, collector.begin(4, 1));
}

test "ready seed expires and clock rollback discards partial bytes" {
    var backend: Fake = .{};
    var generations: Generations = .{};
    var collector = Collector(Fake).init(&backend, &generations);
    try collector.begin(10, 10);
    for (0..entropy.seed_bytes) |_| collector.poll(11);
    collector.poll(20);
    try std.testing.expectEqual(@as(?u64, null), collector.lease());
    try std.testing.expect(std.mem.allEqual(u8, &collector.seed, 0));
    collector.poll(21);
    try collector.begin(30, 10);
    collector.poll(31);
    collector.poll(30);
    try std.testing.expect(std.mem.allEqual(u8, &collector.seed, 0));
    try std.testing.expectEqual(@as(?u64, null), collector.lease());
}
